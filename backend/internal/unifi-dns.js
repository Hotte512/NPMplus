import db from "../db.js";
import { createClient, policyFor, policyValue } from "../lib/unifi.js";
import { global as logger, registerSecret } from "../logger.js";

const TABLE = "npmplus_unifi_dns_record";
// wildcards and regex server names can not be local dns records
const PLAIN_DOMAIN = /^[a-z0-9.-]+$/iu;

// syncs are serialised so two saves of the same host can not create duplicate policies
let queue = Promise.resolve();
// error of the last full sync that failed before any host was handled (e.g. wrong api key)
let lastError = null;
const serial = (fn) => {
	const run = queue.then(fn, fn);
	queue = run.catch(() => {});
	return run;
};

const ttlOf = (config) => Number.parseInt(config?.ttl, 10) || 0;

const getConfig = async () => {
	const row = await db()("setting").where({ id: "unifi-dns" }).first();
	if (!row) return null;
	const meta = typeof row.meta === "string" ? JSON.parse(row.meta) : (row.meta ?? {});
	registerSecret(meta.api_key);
	return { enabled: row.value === "enabled" && Boolean(meta.url) && Boolean(meta.api_key), ...meta };
};

/**
 * The records a proxy host should have, domain => target
 *
 * @param   {Object} host
 * @param   {Object} config
 * @returns {Map<String, String>}
 */
const desiredRecords = (host, config) => {
	const records = new Map();
	if (!config?.enabled || !host?.enabled) return records;
	const mode = host.npmplus_unifi_dns ?? "off";
	let target = "";
	if (mode === "npmplus") target = config.default_target;
	else if (mode === "forward") target = host.forward_host;
	else if (mode === "custom") target = host.npmplus_unifi_dns_target;
	target = (target ?? "").trim();
	if (mode === "off" || !target) return records;
	for (const domain of host.domain_names ?? []) {
		if (PLAIN_DOMAIN.test(domain) && domain.includes(".")) records.set(domain.toLowerCase(), target);
	}
	return records;
};

// last sync result per proxy host id, rebuilt by the sync on startup
const status = new Map();
const setStatus = (hostId, errors) => status.set(hostId, { errors, synced_on: new Date().toISOString() });

/**
 * @param {Object} ctx  { client, foreign, ttl } of the running sync
 */
const syncOne = async ({ client, foreign, ttl }, hostId, desired) => {
	const errors = [];
	const existing = await db()(TABLE).where({ proxy_host_id: hostId });

	for (const rec of existing) {
		if (desired.has(rec.domain)) continue;
		try {
			await client.remove(rec.policy_id);
			await db()(TABLE).where({ proxy_host_id: hostId, domain: rec.domain }).delete();
			logger.info(`UniFi DNS: removed ${rec.domain}`);
		} catch (err) {
			errors.push(`${rec.domain}: ${err.message}`);
		}
	}

	for (const [domain, target] of desired) {
		const rec = existing.find((r) => r.domain === domain);
		const want = policyFor(domain, target, ttl);
		const row = { type: want.type, value: target, ttl };
		try {
			if (rec && rec.type === want.type && rec.value === target && rec.ttl === ttl) continue;
			if (rec) {
				try {
					await client.update(rec.policy_id, domain, target, ttl);
				} catch (err) {
					if (err.statusCode !== 404) throw err;
					// deleted on the controller in the meantime, create it again
					rec.policy_id = await client.create(domain, target, ttl);
				}
				await db()(TABLE)
					.where({ proxy_host_id: hostId, domain })
					.update({ policy_id: rec.policy_id, ...row });
			} else {
				const other = (await foreign()).find((p) => p.domain?.toLowerCase() === domain);
				let id;
				if (other && other.type === want.type && policyValue(other) === target) {
					// an identical record made by hand is taken over instead of reported as conflict
					id = other.id;
					if ((other.ttlSeconds ?? 0) !== ttl) await client.update(id, domain, target, ttl);
					logger.info(`UniFi DNS: took over existing record ${domain}`);
				} else if (other) {
					errors.push(
						`${domain}: a DNS policy not created by NPMplus exists (${policyValue(other)}), left untouched`,
					);
					continue;
				} else {
					id = await client.create(domain, target, ttl);
				}
				await db()(TABLE).insert({ proxy_host_id: hostId, domain, policy_id: id, ...row });
			}
			logger.info(`UniFi DNS: ${domain} -> ${target}`);
		} catch (err) {
			errors.push(`${domain}: ${err.message}`);
		}
	}
	setStatus(hostId, errors);
	return errors;
};

// policies on the controller that NPMplus did not create, fetched lazily once per sync
const foreignPolicies = (client) => {
	let cached;
	return async () => {
		if (!cached) {
			const own = new Set((await db()(TABLE).select("policy_id")).map((r) => r.policy_id));
			cached = (await client.list()).filter((p) => !own.has(p.id));
		}
		return cached;
	};
};

const internalUnifiDns = {
	/**
	 * Brings the dns policies of one proxy host in line with its settings. Never throws, errors are logged and returned.
	 *
	 * @param   {Object}  host  proxy host row, or {id} of a deleted host
	 * @returns {Promise<String[]>} errors
	 */
	syncHost: (host) =>
		serial(async () => {
			try {
				const config = await getConfig();
				const desired = desiredRecords(host, config);
				const hasRecords = (await db()(TABLE).where({ proxy_host_id: host.id }).first()) !== undefined;
				if (desired.size === 0 && !hasRecords) {
					status.delete(host.id);
					return [];
				}
				if (!config?.url || !config?.api_key) {
					setStatus(host.id, ["UniFi DNS is not configured"]);
					return ["UniFi DNS is not configured"];
				}
				const client = createClient(config);
				const errors = await syncOne(
					{ client, foreign: foreignPolicies(client), ttl: ttlOf(config) },
					host.id,
					desired,
				);
				for (const e of errors) logger.error(`UniFi DNS: ${e}`);
				return errors;
			} catch (err) {
				logger.error(`UniFi DNS: ${err.message}`);
				setStatus(host.id, [err.message]);
				return [err.message];
			}
		}),

	/**
	 * Syncs every proxy host, used after the settings changed (disabling removes all own records)
	 *
	 * @returns {Promise<String[]>} errors
	 */
	syncAll: () =>
		serial(async () => {
			try {
				const config = await getConfig();
				if (!config?.url || !config?.api_key) return config?.enabled ? ["UniFi DNS is not configured"] : [];
				const client = createClient(config);
				// fails early on a wrong url or api key
				const ctx = { client, foreign: foreignPolicies(client), ttl: ttlOf(config) };
				await ctx.foreign();
				const hosts = await db()("proxy_host").select(
					"id",
					"enabled",
					"domain_names",
					"forward_host",
					"npmplus_unifi_dns",
					"npmplus_unifi_dns_target",
				);
				const errors = [];
				for (const host of hosts) {
					host.domain_names =
						typeof host.domain_names === "string" ? JSON.parse(host.domain_names) : host.domain_names;
					errors.push(...(await syncOne(ctx, host.id, desiredRecords(host, config))));
				}
				// records of hosts that no longer exist
				const ids = new Set(hosts.map((h) => h.id));
				for (const { proxy_host_id: id } of await db()(TABLE).distinct("proxy_host_id")) {
					if (!ids.has(id)) {
						errors.push(...(await syncOne(ctx, id, new Map())));
						status.delete(id);
					}
				}
				for (const e of errors) logger.error(`UniFi DNS: ${e}`);
				lastError = null;
				return errors;
			} catch (err) {
				logger.error(`UniFi DNS: ${err.message}`);
				lastError = { error: err.message, at: new Date().toISOString() };
				return [err.message];
			}
		}),

	/**
	 * Own records and the last sync result of the proxy hosts the user can see
	 *
	 * @param   {Access}  access
	 * @returns {Promise<Object>}
	 */
	getStatus: async (access) => {
		access.can("proxy_hosts:view");
		const config = await getConfig();
		const query = db()("proxy_host").select("id");
		if (access.visibility !== "all") query.where("owner_user_id", access.token.getUserId(1));
		const visible = (await query).map((h) => h.id);
		const records = await db()(TABLE)
			.whereIn("proxy_host_id", visible)
			.select("proxy_host_id", "domain", "type", "value", "ttl")
			.orderBy("domain");
		const hosts = {};
		for (const id of visible) if (status.has(id)) hosts[id] = status.get(id);
		return { enabled: Boolean(config?.enabled), ttl: ttlOf(config), last_error: lastError, records, hosts };
	},
};

export { desiredRecords };
export default internalUnifiDns;
