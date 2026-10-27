import { isIP } from "node:net";
import { Agent, request } from "undici";

const TRAILING_SLASHES = /\/+$/u;
const insecureAgent = new Agent({ connect: { rejectUnauthorized: false } });

/**
 * Builds the dns policy body for a target, an IP becomes an A/AAAA record, anything else a CNAME
 *
 * @param   {String} domain
 * @param   {String} target
 * @param   {Number} [ttl]  seconds, 0 = auto
 * @returns {Object}
 */
const policyFor = (domain, target, ttl = 0) => {
	switch (isIP(target)) {
		case 4:
			return { type: "A_RECORD", enabled: true, domain, ttlSeconds: ttl, ipv4Address: target };
		case 6:
			return { type: "AAAA_RECORD", enabled: true, domain, ttlSeconds: ttl, ipv6Address: target };
		default:
			return { type: "CNAME_RECORD", enabled: true, domain, ttlSeconds: ttl, targetDomain: target };
	}
};

const policyValue = (policy) => policy.ipv4Address ?? policy.ipv6Address ?? policy.targetDomain ?? "";

/**
 * Minimal client for the dns policies of the UniFi Network integration API
 *
 * @param {Object}  config
 * @param {String}  config.url         e.g. https://192.168.1.1
 * @param {String}  config.api_key
 * @param {String}  [config.site_id]   uuid of the site, empty = the default site
 * @param {Boolean} [config.verify_tls]
 */
const createClient = (config) => {
	const base = `${config.url.replace(TRAILING_SLASHES, "")}/proxy/network/integration/v1`;
	let siteId = config.site_id || null;

	const call = async (method, path, body) => {
		const res = await request(`${base}${path}`, {
			method,
			headers: {
				"X-API-KEY": config.api_key,
				Accept: "application/json",
				...(body ? { "Content-Type": "application/json" } : {}),
			},
			body: body ? JSON.stringify(body) : undefined,
			dispatcher: config.verify_tls ? undefined : insecureAgent,
			headersTimeout: 15000,
			bodyTimeout: 15000,
		});
		const text = await res.body.text();
		if (res.statusCode === 404 && method === "DELETE") return null;
		if (res.statusCode >= 400) {
			let msg = text;
			try {
				msg = JSON.parse(text).message ?? text;
			} catch {}
			const err = new Error(`UniFi API ${method} ${path}: ${res.statusCode} ${msg}`.trim());
			err.statusCode = res.statusCode;
			throw err;
		}
		return text ? JSON.parse(text) : null;
	};

	const site = async () => {
		if (!siteId) {
			const sites = (await call("GET", "/sites?limit=200"))?.data ?? [];
			const found = sites.find((s) => s.internalReference === "default") ?? sites[0];
			if (!found) throw new Error("UniFi API: no site found");
			siteId = found.id;
		}
		return siteId;
	};

	return {
		/** @returns {Promise<Array>} all dns policies of the site */
		list: async () => {
			const s = await site();
			const all = [];
			for (let offset = 0; ; offset += 200) {
				const page = await call("GET", `/sites/${s}/dns/policies?offset=${offset}&limit=200`);
				all.push(...(page?.data ?? []));
				if (!page?.data?.length || all.length >= (page.totalCount ?? 0)) return all;
			}
		},
		create: async (domain, target, ttl) =>
			(await call("POST", `/sites/${await site()}/dns/policies`, policyFor(domain, target, ttl))).id,
		update: async (id, domain, target, ttl) =>
			call("PUT", `/sites/${await site()}/dns/policies/${id}`, policyFor(domain, target, ttl)),
		remove: async (id) => call("DELETE", `/sites/${await site()}/dns/policies/${id}`),
	};
};

export { createClient, policyFor, policyValue };
