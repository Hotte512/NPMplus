import db from "../db.js";
import { createClient, policyFor, policyValue } from "../lib/unifi.js";
import { global as logger } from "../logger.js";

const TABLE = "npmplus_unifi_dns_record";
// wildcards and regex server names can not be local dns records
const PLAIN_DOMAIN = /^[a-z0-9.-]+$/iu;

// syncs are serialised so two saves of the same host can not create duplicate policies
let queue = Promise.resolve();
const serial = (fn) => {
	const run = queue.then(fn, fn);
	queue = run.catch(() => {});
	return run;
};

const getConfig = async () => {
	const row = await db()("setting").where({ id: "unifi-dns" }).first();
	if (!row) return null;
	const meta = typeof row.meta === "string" ? JSON.parse(row.meta) : (row.meta ?? {});
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

const syncOne = async (client, hostId, desired, foreign) => {
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
		const want = policyFor(domain, target);
		try {
			if (rec && rec.type === want.type && rec.value === target) continue;
			if (rec) {
				try {
					await client.update(rec.policy_id, domain, target);
				} catch (err) {
					if (err.statusCode !== 404) throw err;
					// deleted on the controller in the meantime, create it again
					rec.policy_id = await client.create(domain, target);
				}
				await db()(TABLE)
					.where({ proxy_host_id: hostId, domain })
					.update({ policy_id: rec.policy_id, type: want.type, value: target });
			} else {
				const other = (await foreign()).find((p) => p.domain?.toLowerCase() === domain);
				if (other) {
					errors.push(
						`${domain}: a DNS policy not created by NPMplus exists (${policyValue(other)}), left untouched`,
					);
					continue;
				}
				const id = await client.create(domain, target);
				await db()(TABLE).insert({
					proxy_host_id: hostId,
					domain,
					policy_id: id,
					type: want.type,
					value: target,
				});
			}
			logger.info(`UniFi DNS: ${domain} -> ${target}`);
		} catch (err) {
			errors.push(`${domain}: ${err.message}`);
		}
	}
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
				if (desired.size === 0 && !hasRecords) return [];
				if (!config?.url || !config?.api_key) return ["UniFi DNS is not configured"];
				const client = createClient(config);
				const errors = await syncOne(client, host.id, desired, foreignPolicies(client));
				for (const e of errors) logger.error(`UniFi DNS: ${e}`);
				return errors;
			} catch (err) {
				logger.error(`UniFi DNS: ${err.message}`);
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
				const foreign = foreignPolicies(client);
				await foreign();
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
					errors.push(...(await syncOne(client, host.id, desiredRecords(host, config), foreign)));
				}
				// records of hosts that no longer exist
				const ids = new Set(hosts.map((h) => h.id));
				for (const { proxy_host_id: id } of await db()(TABLE).distinct("proxy_host_id")) {
					if (!ids.has(id)) errors.push(...(await syncOne(client, id, new Map(), foreign)));
				}
				for (const e of errors) logger.error(`UniFi DNS: ${e}`);
				return errors;
			} catch (err) {
				logger.error(`UniFi DNS: ${err.message}`);
				return [err.message];
			}
		}),
};

export { desiredRecords };
export default internalUnifiDns;
