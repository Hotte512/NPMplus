import { format } from "node:util";

/**
 * In-memory ring buffer of the most recent log entries, used by the log viewer (source "app").
 * Every entry gets a monotonic sequence number which is used as cursor for incremental polling.
 */
const APP_LOG_MAX_ENTRIES = 2000;
const APP_LOG_MAX_LINE_LENGTH = 16384;
const appLogEntries = [];
let appLogSeq = 0;

const record = (scope, type, args) => {
	try {
		appLogSeq++;
		appLogEntries.push({
			seq: appLogSeq,
			// same formatting as the console output
			line: `${new Date().toISOString()} ${format(`[${scope}] › ${type.padEnd(9)}`, ...args)}`.slice(
				0,
				APP_LOG_MAX_LINE_LENGTH,
			),
		});
		if (appLogEntries.length > APP_LOG_MAX_ENTRIES) appLogEntries.shift();
	} catch {
		// never let the log buffer break logging
	}
};

const appLog = {
	/**
	 * @returns {Number} sequence number of the newest entry
	 */
	cursor: () => appLogSeq,

	/**
	 * @param   {Number} [after]  only return entries with a sequence number greater than this
	 * @returns {Array<{seq: Number, line: String}>}
	 */
	entries: (after = 0) => (after > 0 ? appLogEntries.filter((entry) => entry.seq > after) : [...appLogEntries]),
};

const createLogger = (scope) =>
	Object.fromEntries(
		["info", "warn", "error", "success", "start", "complete", "fatal", "debug"].map((type) => [
			type,
			(...args) => {
				console.log(`[${scope}] › ${type.padEnd(9)}`, ...args);
				record(scope, type, args);
			},
		]),
	);

const global = createLogger("Global        ");
const migrate = createLogger("Migrate       ");
const express = createLogger("Express       ");
const access = createLogger("Access        ");
const nginx = createLogger("Nginx         ");
const ssl = createLogger("TLS           ");
const certbot = createLogger("Certbot       ");
const setup = createLogger("Setup         ");
const ipRanges = createLogger("IP Ranges     ");
const remoteVersion = createLogger("Remote Version");
const gravatar = createLogger("Gravatar      ");
const oidc = createLogger("OIDC          ");

export {
	access,
	appLog,
	certbot,
	express,
	global,
	gravatar,
	ipRanges,
	migrate,
	nginx,
	oidc,
	remoteVersion,
	setup,
	ssl,
};
