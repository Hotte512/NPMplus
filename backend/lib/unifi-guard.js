import { request } from "undici";
import { global as logger } from "../logger.js";
import { dispatcherFor } from "./unifi.js";

const TRAILING_SLASHES = /\/+$/u;
const HTTP_URL = /^https?:\/\//iu;
const CACHE_MS = 60000;
const TIMEOUT_MS = 3000;
const MAX_BODY = 4096;

// url + tls mode => { at, value }
const cache = new Map();

const text = (v, max) => (typeof v === "string" && v.length <= max ? v : "");

/**
 * Reads the info of a "UniFi API Guard" (permission proxy in front of the UniFi API) from its
 * unauthenticated endpoint. A real gateway answers 404 there. Never sends the api key.
 *
 * @param   {Object}  config
 * @param   {String}  config.url
 * @param   {Boolean} [config.verify_tls]
 * @param   {String}  [config.tls_fingerprint]
 * @returns {Promise<{version: String, admin_port: Number, admin_scheme: String, admin_url: String}|null>}
 */
const getGuardInfo = async (config) => {
	if (!config?.url) return null;
	const key = `${config.url}|${Boolean(config.verify_tls)}|${config.tls_fingerprint ?? ""}`;
	const hit = cache.get(key);
	if (hit && Date.now() - hit.at < CACHE_MS) return hit.value;

	let value = null;
	try {
		const res = await request(`${config.url.replace(TRAILING_SLASHES, "")}/guard/v1/info`, {
			method: "GET",
			headers: { Accept: "application/json" },
			dispatcher: dispatcherFor(config),
			headersTimeout: TIMEOUT_MS,
			bodyTimeout: TIMEOUT_MS,
			maxRedirections: 0,
		});
		const body = await res.body.text();
		if (res.statusCode === 200 && body.length <= MAX_BODY) {
			const info = JSON.parse(body);
			const port = Number(info?.admin_port);
			if (info?.product === "unifi-api-guard" && Number.isInteger(port) && port > 0 && port < 65536) {
				const scheme = info.admin_scheme === "https" ? "https" : "http";
				const adminUrl = text(info.admin_url, 512);
				value = {
					version: text(info.version, 64),
					admin_port: port,
					admin_scheme: scheme,
					// only http(s) links are handed to the browser
					admin_url: HTTP_URL.test(adminUrl) ? adminUrl : "",
				};
			}
		}
	} catch (err) {
		logger.debug(`UniFi API Guard info not available: ${err.message}`);
	}
	cache.set(key, { at: Date.now(), value });
	return value;
};

export { getGuardInfo };
