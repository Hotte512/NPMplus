import { chmod, copyFile, readFile, rm, stat, writeFile } from "node:fs/promises";
import { isIP } from "node:net";
import path from "node:path";
import { createClient } from "../lib/crowdsec.js";
import errs from "../lib/error.js";
import { registerSecret } from "../logger.js";
import internalAuditLog from "./audit-log.js";
import internalNginx from "./nginx.js";

// both are only meant for testing, start.sh always uses these paths
const confFile = process.env.NPMPLUS_CROWDSEC_CONF || "/data/crowdsec/crowdsec.conf";
const credFile = path.join(path.dirname(confFile), "lapi-credentials.yaml");
const nginxConfDir = process.env.NPMPLUS_NGINX_CONF_DIR || "/usr/local/nginx/conf/conf.d";
const nginxConf = path.join(nginxConfDir, "crowdsec.conf");
const nginxConfDisabled = path.join(nginxConfDir, "crowdsec.conf.disabled");

const YAML_LINE = /^(?<key>[a-z_]+):(?<value>.*)$/u;
const LINE = /^(?<key>[A-Z_]+)=(?<value>.*)$/u;

/**
 * Keys of crowdsec.conf editable through the api, everything else in the file is kept as is
 * secrets are write only, they are never returned and an empty value on save keeps the stored one
 */
const fields = {
	enabled: { type: "boolean" },
	api_url: { type: "string" },
	api_key: { type: "string", secret: true },
	mode: { type: "string" },
	update_frequency: { type: "string" },
	bouncing_on_type: { type: "string" },
	fallback_remediation: { type: "string" },
	ret_code: { type: "string" },
	redirect_location: { type: "string" },
	exclude_location: { type: "string" },
	captcha_provider: { type: "string" },
	site_key: { type: "string" },
	secret_key: { type: "string", secret: true },
	captcha_expiration: { type: "string" },
	appsec_url: { type: "string" },
	appsec_failure_action: { type: "string" },
	always_send_to_appsec: { type: "boolean" },
	ssl_verify: { type: "boolean" },
};

const readConfFile = async () => {
	try {
		return await readFile(confFile, "utf8");
	} catch (err) {
		if (err.code === "ENOENT") return "";
		throw err;
	}
};

const parseConf = (text) => {
	const values = {};
	for (const line of text.split("\n")) {
		const m = LINE.exec(line.trim());
		if (m) values[m.groups.key] = m.groups.value.trim();
	}
	registerSecret(values.API_KEY);
	registerSecret(values.SECRET_KEY);
	return values;
};

const toBool = (value) => String(value ?? "").toLowerCase() === "true";

/**
 * Replaces the values of existing keys in place and appends missing ones
 *
 * @param   {String} text
 * @param   {Object} values  KEY => value
 * @returns {String}
 */
const updateConf = (text, values) => {
	const pending = new Map(Object.entries(values));
	const lines = text.split("\n").map((line) => {
		const m = LINE.exec(line.trim());
		if (!m || !pending.has(m.groups.key)) return line;
		const value = pending.get(m.groups.key);
		pending.delete(m.groups.key);
		return `${m.groups.key}=${value}`;
	});
	if (lines.length > 0 && lines.at(-1) === "") lines.pop();
	for (const [key, value] of pending) lines.push(`${key}=${value}`);
	return `${lines.join("\n")}\n`;
};

const exists = async (file) => {
	try {
		await stat(file);
		return true;
	} catch {
		return false;
	}
};

/**
 * Machine login for managing decisions and reading alerts, in the format "cscli machines add -f" writes,
 * so it can also be created by "cscli machines add npmplus-gui --auto -f /data/crowdsec/lapi-credentials.yaml"
 *
 * @returns {Promise<{machine_id: String, password: String}>}
 */
const getMachine = async () => {
	let text = "";
	try {
		text = await readFile(credFile, "utf8");
	} catch (err) {
		if (err.code !== "ENOENT") throw err;
	}
	const values = {};
	for (const line of text.split("\n")) {
		const m = YAML_LINE.exec(line.trim());
		if (!m) continue;
		let value = m.groups.value.trim();
		if (value.startsWith('"')) {
			try {
				value = JSON.parse(value);
			} catch {}
		} else if (value.startsWith("'") && value.endsWith("'")) {
			value = value.slice(1, -1).replaceAll("''", "'");
		}
		values[m.groups.key] = value;
	}
	registerSecret(values.password);
	return { machine_id: values.login ?? "", password: values.password ?? "" };
};

const setMachine = async (machine) => {
	if (!machine.machine_id) {
		await rm(credFile, { force: true });
		return;
	}
	registerSecret(machine.password);
	// json strings are valid yaml double quoted scalars
	const text = `login: ${JSON.stringify(machine.machine_id)}\npassword: ${JSON.stringify(machine.password)}\n`;
	await writeFile(credFile, text, { encoding: "utf8", mode: 0o600 });
	await chmod(credFile, 0o600);
};

let cachedClient = null;
let cachedKey = "";

/**
 * A client for the lapi configured in crowdsec.conf, cached so the machine jwt is reused
 *
 * @returns {Promise<Object>}
 */
const getClient = async () => {
	const conf = parseConf(await readConfFile());
	const machine = await getMachine();
	if (!conf.API_URL) throw new errs.ValidationError("CrowdSec: API_URL is not set");
	const config = {
		url: conf.API_URL,
		api_key: conf.API_KEY ?? "",
		tls_cert: toBool(conf.USE_TLS_AUTH) ? conf.TLS_CLIENT_CERT : "",
		tls_key: toBool(conf.USE_TLS_AUTH) ? conf.TLS_CLIENT_KEY : "",
		verify_tls: conf.SSL_VERIFY === undefined ? true : toBool(conf.SSL_VERIFY),
		...machine,
	};
	const key = JSON.stringify(config);
	if (!cachedClient || cachedKey !== key) {
		cachedClient = createClient(config);
		cachedKey = key;
	}
	return cachedClient;
};

/**
 * @param   {String} value  an ip or a cidr range
 * @returns {String}  the scope crowdsec uses for it
 */
const scopeOf = (value) => {
	const [addr, prefix, rest] = value.split("/");
	const family = isIP(addr);
	const max = family === 4 ? 32 : 128;
	if (!family || rest !== undefined || (prefix !== undefined && !(Number(prefix) >= 0 && Number(prefix) <= max))) {
		throw new errs.ValidationError(`Not an ip or range: ${value}`);
	}
	return prefix === undefined ? "Ip" : "Range";
};

const requireMachine = (client) => {
	if (!client.hasMachine) {
		throw new errs.ValidationError("CrowdSec: managing decisions and reading alerts needs a machine login");
	}
};

// lapi errors (unreachable, wrong key, ...) are shown to the user, they are no server errors
const lapi = async (fn) => {
	try {
		return await fn();
	} catch (err) {
		if (err instanceof errs.ValidationError) throw err;
		throw new errs.ValidationError(err.message);
	}
};

const metaValues = (meta, key) => {
	const found = (meta ?? []).find((m) => m.key === key)?.value;
	if (!found) return [];
	try {
		const parsed = JSON.parse(found);
		return Array.isArray(parsed) ? parsed.map(String) : [String(parsed)];
	} catch {
		return [found];
	}
};

/**
 * Hosts and paths of an alert, from the alert context and the events
 *
 * @param   {Object} alert
 * @returns {{hosts: String[], paths: String[]}}
 */
const alertTargets = (alert) => {
	const hosts = new Set(metaValues(alert.meta, "target_fqdn"));
	const paths = new Set(metaValues(alert.meta, "target_uri"));
	for (const event of alert.events ?? []) {
		for (const m of event.meta ?? []) {
			if (m.key === "target_fqdn" && m.value) hosts.add(m.value);
			if (m.key === "http_path" && m.value) paths.add(m.value);
		}
	}
	return { hosts: [...hosts].slice(0, 20), paths: [...paths].slice(0, 20) };
};

const formatDecision = (d) => ({
	id: d.id,
	origin: d.origin ?? "",
	type: d.type ?? "",
	scope: d.scope ?? "",
	value: d.value ?? "",
	duration: d.duration ?? "",
	until: d.until ?? null,
	scenario: d.scenario ?? "",
});

const formatAlert = (a) => ({
	id: a.id,
	created_at: a.created_at ?? a.start_at ?? null,
	scenario: a.scenario ?? "",
	message: a.message ?? "",
	events_count: a.events_count ?? 0,
	source: {
		scope: a.source?.scope ?? "",
		value: a.source?.value ?? a.source?.ip ?? "",
		country: a.source?.cn ?? "",
		as_name: a.source?.as_name ?? "",
	},
	decisions: (a.decisions ?? []).map(formatDecision),
	...alertTargets(a),
});

const internalCrowdsec = {
	/**
	 * @param   {Access}  access
	 * @returns {Promise<Object>}  the editable values of crowdsec.conf and the machine login, without secrets
	 */
	getConfig: async (access) => {
		access.canAdmin();
		const conf = parseConf(await readConfFile());
		const machine = await getMachine();
		const result = {};
		for (const [key, field] of Object.entries(fields)) {
			const value = conf[key.toUpperCase()] ?? "";
			if (field.secret) {
				result[key] = "";
				result[`${key}_set`] = Boolean(value);
			} else {
				result[key] = field.type === "boolean" ? toBool(value) : value;
			}
		}
		result.use_tls_auth = toBool(conf.USE_TLS_AUTH);
		result.machine_id = machine.machine_id;
		result.password = "";
		result.password_set = Boolean(machine.password);
		return result;
	},

	/**
	 * Writes crowdsec.conf, enables/disables the bouncer in nginx and reloads nginx
	 * if nginx does not accept the new config the old one is restored
	 *
	 * @param   {Access}  access
	 * @param   {Object}  data
	 * @returns {Promise<Object>}
	 */
	setConfig: async (access, data) => {
		access.canAdmin();

		const oldText = await readConfFile();
		const old = parseConf(oldText);
		const values = {};
		for (const [key, field] of Object.entries(fields)) {
			if (!(key in data)) continue;
			if (field.secret && !data[key]) continue;
			values[key.toUpperCase()] =
				field.type === "boolean" ? String(Boolean(data[key])) : String(data[key]).trim();
		}
		const newText = updateConf(oldText, values);
		const enabled = toBool(values.ENABLED ?? old.ENABLED);
		const wasActive = await exists(nginxConf);

		await writeFile(confFile, newText, { encoding: "utf8" });
		try {
			if (enabled) await copyFile(nginxConfDisabled, nginxConf);
			else await rm(nginxConf, { force: true });
			await internalNginx.test();
			await internalNginx.reload();
		} catch (err) {
			await writeFile(confFile, oldText, { encoding: "utf8" });
			if (wasActive) await copyFile(nginxConfDisabled, nginxConf);
			else await rm(nginxConf, { force: true });
			try {
				await internalNginx.reload();
			} catch {}
			throw new errs.ValidationError(`Could not apply the CrowdSec config: ${err.message}`);
		}

		if ("machine_id" in data || data.password) {
			const machine = await getMachine();
			const meta = {
				machine_id: "machine_id" in data ? String(data.machine_id).trim() : machine.machine_id,
				password: data.password || machine.password,
			};
			// clearing the machine id also forgets the password
			if (!meta.machine_id) meta.password = "";
			await setMachine(meta);
		}

		const result = await internalCrowdsec.getConfig(access);
		await internalAuditLog.add(access, {
			action: "updated",
			object_type: "crowdsec",
			meta: { id: "config", enabled: result.enabled, api_url: result.api_url, machine_id: result.machine_id },
		});
		return result;
	},

	/**
	 * @param   {Access}  access
	 * @returns {Promise<Object>}
	 */
	getStatus: async (access) => {
		access.canAdmin();
		const conf = parseConf(await readConfFile());
		const status = {
			enabled: toBool(conf.ENABLED),
			active: await exists(nginxConf),
			api_url: conf.API_URL ?? "",
			lapi: { ok: false, error: "" },
			bouncer: { ok: false, error: "" },
			machine: { configured: false, ok: false, error: "" },
		};
		if (!conf.API_URL) {
			status.lapi.error = "API_URL is not set";
			return status;
		}

		let client;
		try {
			client = await getClient();
		} catch (err) {
			status.lapi.error = err.message;
			return status;
		}
		status.machine.configured = client.hasMachine;

		const check = async (target, fn) => {
			try {
				await fn();
				target.ok = true;
			} catch (err) {
				target.error = err.message;
			}
		};
		await check(status.lapi, client.health);
		if (!status.lapi.ok) return status;
		await check(status.bouncer, client.checkBouncer);
		if (client.hasMachine) await check(status.machine, client.checkMachine);
		return status;
	},

	/**
	 * @param   {Access}  access
	 * @returns {Promise<Array>}  active decisions, newest first
	 */
	getDecisions: async (access) => {
		access.canAdmin();
		const client = await lapi(getClient);
		const decisions = await lapi(client.decisions);
		return decisions.map(formatDecision).sort((a, b) => b.id - a.id);
	},

	/**
	 * @param   {Access}  access
	 * @param   {Object}  data
	 * @param   {String}  data.value
	 * @param   {String}  data.type
	 * @param   {String}  data.duration
	 * @param   {String}  [data.reason]
	 * @returns {Promise}
	 */
	addDecision: async (access, data) => {
		access.canAdmin();
		const client = await lapi(getClient);
		requireMachine(client);
		const scope = scopeOf(data.value);
		await lapi(() => client.addDecision({ ...data, scope }));
		await internalAuditLog.add(access, {
			action: "created",
			object_type: "crowdsec",
			meta: { id: "decision", value: data.value, type: data.type, duration: data.duration, reason: data.reason },
		});
		return true;
	},

	/**
	 * @param   {Access}  access
	 * @param   {Object}  data
	 * @param   {Number}  [data.id]  a single decision
	 * @param   {String}  [data.ip]  all decisions of an ip
	 * @returns {Promise<Number>}  number of deleted decisions
	 */
	deleteDecisions: async (access, data) => {
		access.canAdmin();
		if (data.ip) scopeOf(data.ip);
		const client = await lapi(getClient);
		requireMachine(client);
		const deleted = await lapi(() =>
			data.id ? client.deleteDecision(data.id) : client.deleteDecisionsByIp(data.ip),
		);
		await internalAuditLog.add(access, {
			action: "deleted",
			object_type: "crowdsec",
			meta: { id: "decision", value: data.ip ?? `#${data.id}`, deleted },
		});
		return deleted;
	},

	/**
	 * @param   {Access}  access
	 * @param   {Object}  [filter]
	 * @returns {Promise<Array>}  alerts, newest first
	 */
	getAlerts: async (access, filter = {}) => {
		access.canAdmin();
		const client = await lapi(getClient);
		requireMachine(client);
		const alerts = await lapi(() => client.alerts(filter));
		return alerts.map(formatAlert).sort((a, b) => b.id - a.id);
	},
};

export default internalCrowdsec;
