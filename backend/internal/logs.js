import fs from "node:fs/promises";
import path from "node:path";
import errs from "../lib/error.js";
import { appLog } from "../logger.js";
import internalProxyHost from "./proxy-host.js";

// NPMPLUS_LOG_DIR is only meant for testing, nginx always logs to /data/nginx/logs
const nginxLogDir = process.env.NPMPLUS_LOG_DIR || "/data/nginx/logs";

/**
 * Fixed whitelist of log sources, paths are never taken from the client
 */
const sources = {
	access: { file: path.join(nginxLogDir, "access.log"), hostFilter: "access", requiresLogrotate: true },
	error: { file: path.join(nginxLogDir, "error.log"), hostFilter: "error", requiresLogrotate: true },
	stream: { file: path.join(nginxLogDir, "stream.log"), requiresLogrotate: true },
	certbot: { file: "/tmp/certbot-log/letsencrypt.log" },
	app: { memory: true },
};

const MAX_LINES = 5000;
const CHUNK_SIZE = 64 * 1024;
const MAX_TAIL_SCAN_BYTES = 16 * 1024 * 1024;
const MAX_POLL_BYTES = 1024 * 1024;
const MAX_LINE_LENGTH = 16 * 1024;
const NEWLINE = 0x0a;
const PORT_SUFFIX = /:\d+$/u;
const ERROR_LOG_HOST = /, host: "(?<host>[^"]+)"/u;
const ERROR_LOG_SERVER = /, server: (?<server>[^,\s]+)/u;

const getSource = (name) => {
	if (!Object.hasOwn(sources, name)) throw new errs.ValidationError(`Unknown log source: ${name}`);
	return sources[name];
};

const decodeLine = (buf) => {
	let line = buf.toString("utf8");
	if (line.endsWith("\r")) line = line.slice(0, -1);
	if (line.length > MAX_LINE_LENGTH) line = `${line.slice(0, MAX_LINE_LENGTH)}…`;
	return line;
};

/**
 * @param   {String} domain   a domain name of a proxy host, may start with "*."
 * @param   {String} host     the host found in a log line, may contain a port
 * @returns {Boolean}
 */
const domainMatches = (domain, host) => {
	const h = host.toLowerCase().replace(PORT_SUFFIX, "");
	const d = domain.toLowerCase();
	if (d.startsWith("*.")) return h.endsWith(d.slice(1));
	return h === d;
};

/**
 * access log format "alog": [$time_local] $host$is_request_port$request_port $remote_addr ...
 */
const accessLineHost = (line) => {
	const start = line.indexOf("] ");
	if (start === -1) return null;
	const end = line.indexOf(" ", start + 2);
	return line.slice(start + 2, end === -1 ? undefined : end);
};

/**
 * error log lines contain `server: example.com` and/or `host: "example.com"`
 */
const errorLineHosts = (line) => {
	const hosts = [];
	const host = ERROR_LOG_HOST.exec(line);
	if (host) hosts.push(host.groups.host);
	const server = ERROR_LOG_SERVER.exec(line);
	if (server) hosts.push(server.groups.server);
	return hosts;
};

/**
 * @param   {Object}         source
 * @param   {Object}         opts
 * @param   {Array<String>}  [opts.domains]
 * @param   {String}         [opts.filter]
 * @returns {Function|null}  returns true when the line should be shown
 */
const buildMatcher = (source, { domains, filter }) => {
	const needle = filter ? filter.toLowerCase() : null;
	const matchesDomain = (host) => domains.some((domain) => domainMatches(domain, host));

	let hostMatcher = null;
	if (domains) {
		if (source.hostFilter === "access") {
			hostMatcher = (line) => {
				const host = accessLineHost(line);
				return host !== null && matchesDomain(host);
			};
		} else if (source.hostFilter === "error") {
			hostMatcher = (line) => errorLineHosts(line).some(matchesDomain);
		}
	}

	if (!(needle || hostMatcher)) return null;
	return (line) => (!needle || line.toLowerCase().includes(needle)) && (!hostMatcher || hostMatcher(line));
};

/**
 * Resolves the domain names of a proxy host, respecting the permissions of the user
 *
 * @param   {Access}  access
 * @param   {Object}  source
 * @param   {Number}  [hostId]
 * @returns {Promise<Array<String>|null>}
 */
const getDomains = async (access, source, hostId) => {
	if (!hostId) return null;
	if (!source.hostFilter) throw new errs.ValidationError("This log source can not be filtered by host");
	const host = await internalProxyHost.get(access, { id: hostId });
	return host.domain_names ?? [];
};

const unavailable = (name, source, err) => {
	if (err.code === "ENOENT") {
		return {
			source: name,
			available: false,
			reason: source.requiresLogrotate ? "logging-disabled" : "not-found",
			lines: [],
			cursor: null,
		};
	}
	if (err.code === "EACCES" || err.code === "EPERM") {
		return { source: name, available: false, reason: "permission-denied", lines: [], cursor: null };
	}
	throw err;
};

const parseCursor = (cursor) => {
	const [ino, pos] = String(cursor).split(":");
	return { ino, pos: Number(pos) };
};

const readFully = async (fh, length, position) => {
	const buf = Buffer.alloc(length);
	let read = 0;
	while (read < length) {
		const { bytesRead } = await fh.read(buf, read, length - read, position + read);
		if (bytesRead === 0) break;
		read += bytesRead;
	}
	return buf.subarray(0, read);
};

/**
 * Reads complete lines backwards from `end`, without reading the whole file
 *
 * @returns {Promise<Array<String>>} lines in chronological order
 */
const readLinesBackward = async (fh, end, wanted, matcher) => {
	const reversed = [];
	let pos = end;
	let remainder = Buffer.alloc(0);
	let scanned = 0;

	const push = (buf) => {
		if (buf.length === 0) return;
		const line = decodeLine(buf);
		if (!matcher || matcher(line)) reversed.push(line);
	};

	while (pos > 0 && reversed.length < wanted && scanned < MAX_TAIL_SCAN_BYTES) {
		const size = Math.min(CHUNK_SIZE, pos);
		pos -= size;
		scanned += size;
		const data = Buffer.concat([await readFully(fh, size, pos), remainder]);

		let lineEnd = data.length;
		let nl = data.lastIndexOf(NEWLINE, lineEnd - 1);
		while (nl !== -1 && reversed.length < wanted) {
			push(data.subarray(nl + 1, lineEnd));
			lineEnd = nl;
			nl = lineEnd > 0 ? data.lastIndexOf(NEWLINE, lineEnd - 1) : -1;
		}
		remainder = data.subarray(0, lineEnd);
	}
	if (pos === 0 && reversed.length < wanted) push(remainder);

	return reversed.reverse();
};

/**
 * Returns the offset directly after the last newline, so that an incomplete last line
 * is not returned now and returned again by the next poll
 */
const findLastLineEnd = async (fh, size) => {
	if (size === 0) return 0;
	const length = Math.min(CHUNK_SIZE, size);
	const data = await readFully(fh, length, size - length);
	if (data.at(-1) === NEWLINE) return size;
	const nl = data.lastIndexOf(NEWLINE);
	if (nl === -1) return length === size ? 0 : size;
	return size - length + nl + 1;
};

const tailApp = (name, wanted, matcher) => {
	let lines = appLog.entries().map((entry) => entry.line);
	if (matcher) lines = lines.filter(matcher);
	return { source: name, available: true, lines: lines.slice(-wanted), cursor: String(appLog.cursor()) };
};

const sinceApp = (name, cursor, matcher) => {
	const after = Number(cursor) || 0;
	const reset = after > appLog.cursor();
	let lines = appLog.entries(reset ? 0 : after).map((entry) => entry.line);
	if (matcher) lines = lines.filter(matcher);
	return {
		source: name,
		available: true,
		reset,
		lines: lines.slice(-MAX_LINES),
		cursor: String(appLog.cursor()),
	};
};

const internalLogs = {
	MAX_LINES,

	sources: () => Object.keys(sources),

	/**
	 * Last lines of a log
	 *
	 * @param   {Access}  access
	 * @param   {String}  name           log source
	 * @param   {Object}  [opts]
	 * @param   {Number}  [opts.lines]
	 * @param   {Number}  [opts.host_id]
	 * @param   {String}  [opts.filter]
	 * @returns {Promise}
	 */
	tail: async (access, name, opts = {}) => {
		access.canAdmin();
		const source = getSource(name);
		const wanted = Math.min(Math.max(Number(opts.lines) || 500, 1), MAX_LINES);
		const domains = await getDomains(access, source, opts.host_id);
		const matcher = buildMatcher(source, { domains, filter: opts.filter });

		if (source.memory) return tailApp(name, wanted, matcher);

		let fh;
		try {
			fh = await fs.open(source.file, "r");
		} catch (err) {
			return unavailable(name, source, err);
		}
		try {
			const stat = await fh.stat({ bigint: true });
			const end = await findLastLineEnd(fh, Number(stat.size));
			const lines = await readLinesBackward(fh, end, wanted, matcher);
			return { source: name, available: true, lines, cursor: `${stat.ino}:${end}` };
		} finally {
			await fh.close();
		}
	},

	/**
	 * Lines appended to a log after the given cursor
	 *
	 * @param   {Access}  access
	 * @param   {String}  name           log source
	 * @param   {String}  cursor         as returned by tail() or since()
	 * @param   {Object}  [opts]
	 * @param   {Number}  [opts.host_id]
	 * @param   {String}  [opts.filter]
	 * @returns {Promise}
	 */
	since: async (access, name, cursor, opts = {}) => {
		access.canAdmin();
		const source = getSource(name);
		const domains = await getDomains(access, source, opts.host_id);
		const matcher = buildMatcher(source, { domains, filter: opts.filter });

		if (source.memory) return sinceApp(name, cursor, matcher);

		let fh;
		try {
			fh = await fs.open(source.file, "r");
		} catch (err) {
			return unavailable(name, source, err);
		}
		try {
			const stat = await fh.stat({ bigint: true });
			const ino = String(stat.ino);
			const size = Number(stat.size);
			const prev = parseCursor(cursor);

			// rotated (new inode) or truncated (copytruncate): start from the beginning
			const reset = prev.ino !== ino || !Number.isFinite(prev.pos) || prev.pos > size;
			const start = reset ? 0 : prev.pos;

			const length = Math.min(size - start, MAX_POLL_BYTES);
			const data = length > 0 ? await readFully(fh, length, start) : Buffer.alloc(0);

			// only consume complete lines, unless a single line exceeds the poll limit
			let consumed = data.lastIndexOf(NEWLINE) + 1;
			if (consumed === 0 && data.length === MAX_POLL_BYTES) consumed = data.length;

			// stop at MAX_LINES, the rest is returned by the next poll
			const lines = [];
			let lineStart = 0;
			while (lineStart < consumed && lines.length < MAX_LINES) {
				let nl = data.indexOf(NEWLINE, lineStart);
				if (nl === -1 || nl >= consumed) nl = consumed;
				if (nl > lineStart) {
					const line = decodeLine(data.subarray(lineStart, nl));
					if (!matcher || matcher(line)) lines.push(line);
				}
				lineStart = Math.min(nl + 1, consumed);
			}

			const pos = start + lineStart;
			return {
				source: name,
				available: true,
				reset,
				more: pos < size,
				lines,
				cursor: `${ino}:${pos}`,
			};
		} finally {
			await fh.close();
		}
	},
};

export { buildMatcher, domainMatches };
export default internalLogs;
