// biome-ignore-all lint/suspicious/noBitwiseOperators: address arithmetic on BigInt values
/**
 * Strict parsing and normalisation of ip addresses and cidr ranges
 *
 * The result only ever contains [0-9a-f.:/], so it is safe to write into generated nginx config.
 */

const V4_OCTET = "(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])";
const V4 = new RegExp(`^${V4_OCTET}(?:\\.${V4_OCTET}){3}$`, "u");
const V6_CHARS = /^[0-9a-fA-F:.]+$/u;
const V6_GROUP = /^[0-9a-fA-F]{1,4}$/u;
const PREFIX = /^(?:0|[1-9][0-9]{0,2})$/u;
const V4_MAPPED = 0xffff00000000n;

const parseV4 = (text) => {
	if (!V4.test(text)) return null;
	return text.split(".").reduce((acc, octet) => (acc << 8n) | BigInt(octet), 0n);
};

const parseGroups = (part) => {
	if (part === "") return [];
	const groups = part.split(":");
	return groups.every((g) => V6_GROUP.test(g)) ? groups.map((g) => Number.parseInt(g, 16)) : null;
};

const parseV6 = (text) => {
	if (!V6_CHARS.test(text) || text.length > 45) return null;
	let rest = text;
	let tail = [];
	// embedded ipv4 in the last 32 bits, e.g. ::ffff:192.0.2.1
	if (rest.includes(".")) {
		const idx = rest.lastIndexOf(":");
		const v4 = parseV4(rest.slice(idx + 1));
		if (idx < 0 || v4 === null) return null;
		tail = [Number(v4 >> 16n), Number(v4 & 0xffffn)];
		rest = rest.slice(0, idx + 1);
		// "::1.2.3.4" keeps "::", "1:2:3:4:5:6:1.2.3.4" needs the trailing ":" removed
		if (!rest.endsWith("::")) rest = rest.slice(0, -1);
	}

	const parts = rest.split("::");
	if (parts.length > 2) return null;
	const head = parseGroups(parts[0]);
	const back = parts.length === 2 ? parseGroups(parts[1]) : [];
	if (head === null || back === null) return null;

	let groups;
	if (parts.length === 2) {
		const missing = 8 - head.length - back.length - tail.length;
		// "::" stands for at least one group of zeros
		if (missing < 1) return null;
		groups = [...head, ...new Array(missing).fill(0), ...back, ...tail];
	} else {
		groups = [...head, ...tail];
	}
	if (groups.length !== 8) return null;
	return groups.reduce((acc, g) => (acc << 16n) | BigInt(g), 0n);
};

const formatV4 = (value) => [24n, 16n, 8n, 0n].map((shift) => String((value >> shift) & 0xffn)).join(".");

/**
 * RFC 5952: lower case, no leading zeros, the longest run of two or more zero groups is shortened to "::"
 */
const formatV6 = (value) => {
	const groups = [];
	for (let shift = 112n; shift >= 0n; shift -= 16n) groups.push(Number((value >> shift) & 0xffffn));

	let bestStart = -1;
	let bestLen = 0;
	for (let i = 0; i < 8; ) {
		if (groups[i] !== 0) {
			i++;
			continue;
		}
		let j = i;
		while (j < 8 && groups[j] === 0) j++;
		if (j - i > bestLen) {
			bestStart = i;
			bestLen = j - i;
		}
		i = j;
	}

	const hex = groups.map((g) => g.toString(16));
	if (bestLen < 2) return hex.join(":");
	return `${hex.slice(0, bestStart).join(":")}::${hex.slice(bestStart + bestLen).join(":")}`;
};

const mask = (bits, prefix) => {
	const all = (1n << BigInt(bits)) - 1n;
	return all ^ ((1n << BigInt(bits - prefix)) - 1n);
};

/**
 * @param   {String} input
 * @returns {{family: Number, address: BigInt, prefix: Number}|null}  the network, host bits are cleared
 */
const parseCidr = (input) => {
	if (typeof input !== "string" || input.length === 0 || input.length > 64) return null;
	const parts = input.split("/");
	if (parts.length > 2) return null;
	const [addr, prefixText] = parts;
	if (prefixText !== undefined && !PREFIX.test(prefixText)) return null;

	let family = 4;
	let address = parseV4(addr);
	if (address === null) {
		family = 6;
		address = parseV6(addr);
	}
	if (address === null) return null;

	const bits = family === 4 ? 32 : 128;
	let prefix = prefixText === undefined ? bits : Number(prefixText);
	if (prefix > bits) return null;

	// ipv4 mapped ipv6 addresses are the same clients as plain ipv4, nginx sees them as ipv4
	if (family === 6 && prefix >= 96 && address >> 32n === V4_MAPPED >> 32n) {
		family = 4;
		address &= 0xffffffffn;
		prefix -= 96;
	}

	const width = family === 4 ? 32 : 128;
	return { family, address: address & mask(width, prefix), prefix };
};

/**
 * @param   {{family: Number, address: BigInt, prefix: Number}} net
 * @returns {String}  e.g. "192.0.2.1", "192.0.2.0/24", "2001:db8::/32"
 */
const formatCidr = (net) => {
	const text = net.family === 4 ? formatV4(net.address) : formatV6(net.address);
	const bits = net.family === 4 ? 32 : 128;
	return net.prefix === bits ? text : `${text}/${net.prefix}`;
};

/**
 * Validates and normalises an ip address or cidr range
 * host bits of a range are cleared (192.0.2.7/24 => 192.0.2.0/24), a full length prefix is dropped
 *
 * @param   {String} input
 * @param   {Object} [options]
 * @param   {Number} [options.minPrefix4]  shortest allowed ipv4 prefix length, i.e. the largest allowed range (16 = /16)
 * @param   {Number} [options.minPrefix6]  shortest allowed ipv6 prefix length, i.e. the largest allowed range
 * @returns {String|null}  null if the input is not a valid address/range or the range is larger than allowed
 */
const normalizeCidr = (input, { minPrefix4 = 0, minPrefix6 = 0 } = {}) => {
	const net = parseCidr(input);
	if (!net) return null;
	if (net.prefix < (net.family === 4 ? minPrefix4 : minPrefix6)) return null;
	return formatCidr(net);
};

/**
 * @param   {String} range  a normalised address or range
 * @param   {String} ip     a normalised address
 * @returns {Boolean}
 */
const cidrContains = (range, ip) => {
	const net = parseCidr(range);
	const addr = parseCidr(ip);
	if (!net || !addr || net.family !== addr.family) return false;
	const width = net.family === 4 ? 32 : 128;
	return (addr.address & mask(width, net.prefix)) === net.address;
};

export { cidrContains, normalizeCidr };
