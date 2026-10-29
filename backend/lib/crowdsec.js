import { readFileSync } from "node:fs";
import { Agent, request } from "undici";
import { registerSecret } from "../logger.js";
import pjson from "../package.json" with { type: "json" };

const TRAILING_SLASHES = /\/+$/u;
// decisions of the community blocklist and console lists are not shown, they are tens of thousands
const LOCAL_ORIGINS = "crowdsec,cscli,cscli-import,appsec,console";
const TIMEOUT = 10000;

/**
 * Minimal client for the crowdsec local api
 *
 * The bouncer key only allows reading decisions, managing decisions and reading alerts needs a machine login
 * (cscli machines add).
 *
 * @param {Object}  config
 * @param {String}  config.url              e.g. http://127.0.0.1:8080
 * @param {String}  [config.api_key]        bouncer key
 * @param {String}  [config.tls_cert]       bouncer client certificate (instead of the key)
 * @param {String}  [config.tls_key]
 * @param {Boolean} [config.verify_tls]
 * @param {String}  [config.machine_id]
 * @param {String}  [config.password]
 */
const createClient = (config) => {
	const base = config.url.replace(TRAILING_SLASHES, "");
	const tlsAuth = Boolean(config.tls_cert && config.tls_key);
	const connect = { rejectUnauthorized: config.verify_tls !== false };
	const dispatcher = new Agent({ connect });
	const bouncerDispatcher = tlsAuth
		? new Agent({
				connect: { ...connect, cert: readFileSync(config.tls_cert), key: readFileSync(config.tls_key) },
			})
		: dispatcher;
	let jwt = null;

	const call = async (method, path, { auth, body } = {}) => {
		// the lapi rejects a machine login with 401 unless the user agent has the form name/version
		const headers = { Accept: "application/json", "User-Agent": `npmplus-gui/${pjson.version}` };
		if (body) headers["Content-Type"] = "application/json";
		if (auth === "bouncer" && !tlsAuth) headers["X-Api-Key"] = config.api_key ?? "";
		if (auth === "machine") headers.Authorization = `Bearer ${jwt.token}`;

		const res = await request(`${base}${path}`, {
			method,
			headers,
			body: body ? JSON.stringify(body) : undefined,
			dispatcher: auth === "bouncer" ? bouncerDispatcher : dispatcher,
			headersTimeout: TIMEOUT,
			bodyTimeout: TIMEOUT,
		});
		const text = await res.body.text();
		if (res.statusCode >= 400) {
			let msg = text;
			try {
				msg = JSON.parse(text).message ?? text;
			} catch {}
			const err = new Error(`CrowdSec LAPI ${method} ${path.split("?")[0]}: ${res.statusCode} ${msg}`.trim());
			err.statusCode = res.statusCode;
			throw err;
		}
		return text ? JSON.parse(text) : null;
	};

	const login = async () => {
		if (!config.machine_id || !config.password) throw new Error("CrowdSec: no machine login configured");
		const res = await call("POST", "/v1/watchers/login", {
			body: { machine_id: config.machine_id, password: config.password, scenarios: [] },
		});
		// renew a minute before the token expires
		registerSecret(res.token);
		jwt = { token: res.token, expires: new Date(res.expire).getTime() - 60000 };
	};

	const machine = async (method, path, body) => {
		if (!jwt || Date.now() > jwt.expires) await login();
		try {
			return await call(method, path, { auth: "machine", body });
		} catch (err) {
			if (err.statusCode !== 401) throw err;
			await login();
			return call(method, path, { auth: "machine", body });
		}
	};

	return {
		hasMachine: Boolean(config.machine_id && config.password),

		/** @returns {Promise<Boolean>} */
		health: async () => (await call("GET", "/health"))?.status === "up",

		/** checks the bouncer key, throws if it is not accepted */
		checkBouncer: () => call("GET", "/v1/decisions?ip=192.0.2.1", { auth: "bouncer" }),

		/** checks the machine login, throws if it is not accepted */
		checkMachine: login,

		/** @returns {Promise<Array>} active decisions which were not pulled from the community blocklist */
		decisions: async () =>
			(await call("GET", `/v1/decisions?origins=${encodeURIComponent(LOCAL_ORIGINS)}`, { auth: "bouncer" })) ??
			[],

		/**
		 * @param   {Object} [filter]
		 * @param   {String} [filter.ip]
		 * @param   {String} [filter.scenario]
		 * @param   {Number} [filter.limit]
		 * @returns {Promise<Array>}
		 */
		alerts: async (filter = {}) => {
			const query = new URLSearchParams({ limit: String(filter.limit ?? 100), include_capi: "false" });
			if (filter.ip) query.set("ip", filter.ip);
			if (filter.scenario) query.set("scenario", filter.scenario);
			return (await machine("GET", `/v1/alerts?${query}`)) ?? [];
		},

		/** @returns {Promise<Number>} number of deleted decisions */
		deleteDecision: async (id) => Number((await machine("DELETE", `/v1/decisions/${id}`))?.nbDeleted ?? 0),

		/** @returns {Promise<Number>} number of deleted decisions */
		deleteDecisionsByIp: async (ip) => {
			const param = ip.includes("/") ? "range" : "ip";
			return Number(
				(await machine("DELETE", `/v1/decisions?${param}=${encodeURIComponent(ip)}`))?.nbDeleted ?? 0,
			);
		},

		/**
		 * Adds a decision the same way "cscli decisions add" does
		 *
		 * @param {Object} data
		 * @param {String} data.value     ip or range
		 * @param {String} data.scope     Ip or Range
		 * @param {String} data.type      ban or captcha
		 * @param {String} data.duration  e.g. 4h
		 * @param {String} data.reason
		 */
		addDecision: async (data) => {
			const now = new Date().toISOString();
			const scenario = data.reason || `manual '${data.type}' from NPMplus`;
			await machine("POST", "/v1/alerts", [
				{
					capacity: 0,
					decisions: [
						{
							duration: data.duration,
							origin: "cscli",
							scenario,
							scope: data.scope,
							type: data.type,
							value: data.value,
						},
					],
					events: [],
					events_count: 1,
					leakspeed: "0",
					message: `${config.machine_id} manual '${data.type}' from NPMplus on ${data.scope} ${data.value}`,
					scenario,
					scenario_hash: "",
					scenario_version: "",
					simulated: false,
					source: {
						scope: data.scope,
						value: data.value,
						...(data.scope === "Ip" ? { ip: data.value } : { range: data.value }),
					},
					start_at: now,
					stop_at: now,
				},
			]);
		},
	};
};

export { createClient };
