import { createHash, randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { mkdir, open, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import db from "../db.js";
import errs from "../lib/error.js";
import { cidrContains, normalizeCidr } from "../lib/ip-cidr.js";
import { global as logger } from "../logger.js";
import internalAuditLog from "./audit-log.js";

/**
 * Desired state for the crowdsec-helper container
 *
 * NPMplus has no write access to CrowdSec (no docker socket, the LAPI can't change allowlists). The helper runs
 * cscli next to crowdsec. install.sh mounts two directories: in/ (/opt/crowdsec/helper/in, written by NPMplus,
 * read-only for the helper) and out/ (/opt/crowdsec/helper/out, written by the helper, read-only here), so neither
 * side ever writes into a directory the other one controls. The database is the source of truth: on every change and
 * at startup the desired state files are written to in/ again (atomically, tmp + rename). The helper validates them
 * again and reports the result in out/status.json.
 *
 * File format: line based, the first line names format and kind, "end" closes the file, fields are separated by tabs
 *   npmplus-crowdsec-desired 1 allowlist
 *   revision <16 hex>
 *   item <value> <expiration as unix time, 0 = never> <description>
 *   end
 */

// only meant for testing, compose always uses this path
const helperDir = process.env.NPMPLUS_CROWDSEC_HELPER_DIR || "/data/crowdsec/helper";
const inDir = path.join(helperDir, "in");
const statusFile = path.join(helperDir, "out", "status.json");
const ITEM_TABLE = "npmplus_crowdsec_allowlist_item";
const LIST_NAME = "npmplus";
// a heartbeat older than this means the helper is not running
const STALE_MS = 90 * 1000;
const MAX_STATUS_BYTES = 1024 * 1024;
const MAX_ITEMS = 500;
// larger ranges would exempt whole providers from decisions and AppSec, the helper enforces the same limits
const MIN_PREFIX = { minPrefix4: 16, minPrefix6: 32 };
const RANGE_TOO_LARGE = "IPv4 ranges need a prefix of at least /16, IPv6 ranges of at least /32";
const MAX_EXPIRATION = Date.UTC(2100, 0, 1);
const CONTROL_CHARS = /\p{Cc}/u;
const REVISION = /^[0-9a-f]{16}$/u;
const SAFE_TEXT = /[^\w .,:;/()=+@#-]/gu;

// all writes (and the regeneration at startup) run one after another
let queue = Promise.resolve();
const serialize = (fn) => {
	const run = queue.then(fn, fn);
	queue = run.catch(() => {});
	return run;
};

const toEpoch = (iso) => (iso ? Math.floor(Date.parse(iso) / 1000) : 0);

// rows edited by hand must not break the line format
const cleanDescription = (text) =>
	String(text ?? "")
		.replace(/\p{Cc}/gu, " ")
		.slice(0, 255);

/**
 * @param   {String}   kind
 * @param   {String[]} lines
 * @returns {{text: String, revision: String}}
 */
const renderDesired = (kind, lines) => {
	const revision = createHash("sha256").update(lines.join("\n")).digest("hex").slice(0, 16);
	const text = [`npmplus-crowdsec-desired 1 ${kind}`, `revision ${revision}`, ...lines, "end", ""].join("\n");
	return { text, revision };
};

/**
 * @param   {Object[]} items
 * @returns {{text: String, revision: String}}
 */
const renderAllowlist = (items) => {
	const lines = [];
	for (const item of items) {
		// stored values are validated on write, this protects the file from rows edited by hand
		const value = normalizeCidr(item.value, MIN_PREFIX);
		if (!value) continue;
		const expires = toEpoch(item.expires_at);
		if (Number.isNaN(expires) || expires < 0) continue;
		lines.push(`item\t${value}\t${expires}\t${cleanDescription(item.description)}`);
	}
	return renderDesired("allowlist", lines);
};

const writeAtomic = async (name, text) => {
	await mkdir(inDir, { recursive: true });
	const file = path.join(inDir, name);
	const tmp = path.join(inDir, `.${name}.${randomBytes(6).toString("hex")}.tmp`);
	try {
		await writeFile(tmp, text, { encoding: "utf8", mode: 0o644, flag: "wx" });
		await rename(tmp, file);
	} catch (err) {
		await rm(tmp, { force: true });
		throw err;
	}
};

const loadItems = async () =>
	(await db()(ITEM_TABLE).select("id", "value", "description", "expires_at", "created_on").orderBy("id")).map(
		(r) => ({
			id: r.id,
			value: r.value,
			description: r.description ?? "",
			expires_at: r.expires_at || null,
			created_on: r.created_on || null,
		}),
	);

/**
 * Writes all desired state files from the database
 *
 * @returns {Promise<{allowlist: String}>}  the revisions
 */
const writeSpool = async () => {
	const allowlist = renderAllowlist(await loadItems());
	await writeAtomic("allowlist.desired", allowlist.text);
	return { allowlist: allowlist.revision };
};

const str = (value, max = 200) => (typeof value === "string" ? value.replace(SAFE_TEXT, "").slice(0, max) : "");
// unix times and sizes from the status file, anything outside 0..2^40 is treated as missing (no RangeError later)
const int = (value) => (Number.isSafeInteger(value) && value >= 0 && value <= 2 ** 40 ? value : 0);
const time = (seconds) => (seconds > 0 && seconds <= 2 ** 40 ? new Date(seconds * 1000).toISOString() : null);

/**
 * Reads the status file without following symlinks and without blocking on a fifo, size checked on the open handle
 *
 * @returns {Promise<String|null>}  null if it does not exist
 */
const readStatusFile = async () => {
	let fh;
	try {
		// biome-ignore lint/suspicious/noBitwiseOperators: open flags
		fh = await open(statusFile, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
	} catch (err) {
		if (err.code === "ENOENT") return null;
		throw err;
	}
	try {
		const st = await fh.stat();
		if (!st.isFile() || st.size > MAX_STATUS_BYTES) throw new Error("not a regular file or too large");
		const buf = Buffer.alloc(MAX_STATUS_BYTES + 1);
		const { bytesRead } = await fh.read(buf, 0, buf.length, 0);
		if (bytesRead > MAX_STATUS_BYTES) throw new Error("too large");
		return buf.subarray(0, bytesRead).toString("utf8");
	} finally {
		await fh.close();
	}
};

/**
 * status.json of the helper, every field is checked (the file comes from another container)
 *
 * @returns {Promise<Object|null>}  null if there is no (readable) status
 */
const readStatus = async () => {
	let raw;
	try {
		const text = await readStatusFile();
		if (text === null) return null;
		raw = JSON.parse(text);
	} catch {
		return { invalid: true };
	}
	if (!raw || typeof raw !== "object" || raw.format !== 1) return { invalid: true };
	const al = raw.allowlist && typeof raw.allowlist === "object" ? raw.allowlist : {};
	const items = Array.isArray(al.items) ? al.items.slice(0, MAX_ITEMS * 2) : [];
	return {
		version: str(raw.helper_version, 16),
		heartbeat: int(raw.heartbeat),
		started_at: int(raw.started_at),
		allowlist: {
			state: str(al.state, 16),
			message: str(al.message),
			revision: REVISION.test(al.revision ?? "") ? al.revision : "",
			last_run: int(al.last_run),
			items: items
				.filter((i) => i && typeof i === "object")
				.map((i) => ({
					value: normalizeCidr(String(i.value ?? "")) ?? "",
					line: int(i.line),
					state: str(i.state, 16),
					message: str(i.message),
				})),
		},
		raw,
	};
};

/**
 * @param   {Object|null} status
 * @returns {Object}  what the ui shows about the helper
 */
const helperSummary = (status) => {
	if (!status) return { state: "missing", version: "", heartbeat: null, started_at: null };
	if (status.invalid) return { state: "invalid", version: "", heartbeat: null, started_at: null };
	const active = Date.now() - status.heartbeat * 1000 < STALE_MS;
	return {
		state: active ? "active" : "stale",
		version: status.version,
		heartbeat: time(status.heartbeat),
		started_at: time(status.started_at),
	};
};

/**
 * Sync state of one entry: pending until the helper reports the current revision
 */
const itemSync = (item, helper, status, revision) => {
	// rows stored before the limits were raised are not written to the desired state
	if (!normalizeCidr(item.value, MIN_PREFIX))
		return { sync: "error", message: `range too large: ${RANGE_TOO_LARGE}` };
	if (item.expires_at && Date.parse(item.expires_at) <= Date.now()) return { sync: "expired", message: "" };
	if (helper.state !== "active" || status.allowlist.revision !== revision) return { sync: "pending", message: "" };
	const found = status.allowlist.items.find((i) => i.value === item.value);
	if (!found) return { sync: "error", message: "rejected by the helper" };
	if (found.state === "ok") return { sync: "ok", message: "" };
	if (found.state === "expired") return { sync: "expired", message: "" };
	return { sync: "error", message: found.message };
};

/**
 * @param   {Object} data
 * @param   {Object[]} items  existing entries
 * @returns {{value: String, description: String, expires_at: String}}
 */
const validateItem = (data, items) => {
	const value = normalizeCidr(String(data.value ?? "").trim(), MIN_PREFIX);
	if (!value) {
		throw new errs.ValidationError(`Not a valid IP address or CIDR range (${RANGE_TOO_LARGE})`);
	}
	if (items.some((i) => i.value === value)) {
		throw new errs.ValidationError(`${value} is already on the allowlist`);
	}
	const description = String(data.description ?? "").trim();
	if (description.length > 255 || CONTROL_CHARS.test(description)) {
		throw new errs.ValidationError("The description must be a single line of at most 255 characters");
	}
	let expires_at = "";
	if (data.expires_at) {
		const ms = Date.parse(data.expires_at);
		if (Number.isNaN(ms) || ms <= Date.now() + 60 * 1000 || ms >= MAX_EXPIRATION) {
			throw new errs.ValidationError("The expiration must be a date in the future (at least one minute)");
		}
		expires_at = new Date(Math.floor(ms / 1000) * 1000).toISOString();
	}
	return { value, description, expires_at };
};

/**
 * Stores the change and writes the desired state again, the database is restored if the spool can't be written
 */
const applyChange = async (persist, undo) => {
	await persist();
	try {
		await writeSpool();
	} catch (err) {
		await undo().catch(() => {});
		throw new errs.ValidationError(`Could not write the desired state for the CrowdSec helper: ${err.message}`);
	}
};

const internalCrowdsecHelper = {
	/**
	 * @param   {Access}  access
	 * @returns {Promise<Object>}  helper state, per area state and messages
	 */
	getHelper: async (access) => {
		access.canAdmin();
		const status = await readStatus();
		const helper = helperSummary(status);
		if (!status || status.invalid) return { ...helper, spool_dir: helperDir, allowlist: null };
		return {
			...helper,
			spool_dir: helperDir,
			allowlist: {
				state: status.allowlist.state,
				message: status.allowlist.message,
				last_run: time(status.allowlist.last_run),
			},
		};
	},

	/**
	 * Entries of the npmplus allowlist with their sync state, and the client address of this request
	 *
	 * @param   {Access}  access
	 * @param   {String}  clientIp
	 * @returns {Promise<Object>}
	 */
	getAllowlist: async (access, clientIp) => {
		access.canAdmin();
		const items = await loadItems();
		const { revision } = renderAllowlist(items);
		const status = await readStatus();
		const helper = helperSummary(status);
		const usable = status && !status.invalid;
		const ip = normalizeCidr(String(clientIp ?? "")) ?? "";
		return {
			name: LIST_NAME,
			helper,
			state: usable ? status.allowlist.state : "",
			message: usable ? status.allowlist.message : "",
			revision,
			applied_revision: usable ? status.allowlist.revision : "",
			items: items.map((item) => ({
				...item,
				...(usable ? itemSync(item, helper, status, revision) : { sync: "pending", message: "" }),
			})),
			client_ip: ip.includes("/") ? "" : ip,
			client_ip_listed: Boolean(ip) && items.some((i) => cidrContains(i.value, ip)),
		};
	},

	/**
	 * @param   {Access}  access
	 * @param   {Object}  data
	 * @returns {Promise<Object>}
	 */
	createItem: async (access, data) =>
		serialize(async () => {
			access.canAdmin();
			const items = await loadItems();
			if (items.length >= MAX_ITEMS) {
				throw new errs.ValidationError(`At most ${MAX_ITEMS} entries are possible`);
			}
			const row = { ...validateItem(data, items), created_on: new Date().toISOString() };
			let id;
			await applyChange(
				async () => {
					const inserted = await db()(ITEM_TABLE).insert(row, ["id"]);
					id = typeof inserted[0] === "object" ? inserted[0].id : inserted[0];
				},
				() => db()(ITEM_TABLE).where({ id }).delete(),
			);
			const result = { id, ...row, expires_at: row.expires_at || null };
			await internalAuditLog.add(access, {
				action: "created",
				object_type: "crowdsec",
				meta: { ...result, id: "allowlist-item", item_id: id, allowlist: LIST_NAME },
			});
			return result;
		}),

	/**
	 * @param   {Access}  access
	 * @param   {Number}  id
	 * @returns {Promise<Boolean>}
	 */
	deleteItem: async (access, id) =>
		serialize(async () => {
			access.canAdmin();
			const old = (await loadItems()).find((i) => i.id === id);
			if (!old) throw new errs.ItemNotFoundError(id);
			await applyChange(
				() => db()(ITEM_TABLE).where({ id }).delete(),
				() =>
					db()(ITEM_TABLE).insert({
						id,
						value: old.value,
						description: old.description,
						expires_at: old.expires_at ?? "",
						created_on: old.created_on ?? "",
					}),
			);
			await internalAuditLog.add(access, {
				action: "deleted",
				object_type: "crowdsec",
				meta: { ...old, id: "allowlist-item", item_id: id, allowlist: LIST_NAME },
			});
			return true;
		}),

	/**
	 * Writes the desired state at startup, errors are only logged
	 *
	 * @returns {Promise}
	 */
	startup: () =>
		serialize(async () => {
			try {
				await writeSpool();
			} catch (err) {
				logger.error(`CrowdSec helper: could not write the desired state to ${helperDir}: ${err.message}`);
			}
		}),

	renderAllowlist,
};

export default internalCrowdsecHelper;
