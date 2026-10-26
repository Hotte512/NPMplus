// Common second level suffixes where the registrable domain has three labels (example.co.uk)
const twoPartSuffixes = new Set([
	"co.uk",
	"org.uk",
	"me.uk",
	"ltd.uk",
	"plc.uk",
	"ac.uk",
	"gov.uk",
	"net.uk",
	"com.au",
	"net.au",
	"org.au",
	"edu.au",
	"gov.au",
	"co.nz",
	"net.nz",
	"org.nz",
	"co.jp",
	"or.jp",
	"ne.jp",
	"ac.jp",
	"co.kr",
	"or.kr",
	"co.in",
	"net.in",
	"org.in",
	"co.za",
	"org.za",
	"com.br",
	"net.br",
	"org.br",
	"com.mx",
	"com.ar",
	"com.tr",
	"com.cn",
	"net.cn",
	"org.cn",
	"com.hk",
	"com.sg",
	"com.tw",
	"com.pl",
	"com.ua",
	"co.il",
	"co.at",
	"or.at",
	"gv.at",
	"ac.at",
]);

const ipv4 = /^\d{1,3}(?:\.\d{1,3}){3}$/u;
const leadingWildcard = /^\*\./u;
const trailingDot = /\.$/u;

const isIp = (host) => ipv4.test(host) || host.includes(":");

const clean = (d) => (d ?? "").trim().toLowerCase().replace(leadingWildcard, "").replace(trailingDot, "");

// "a.example.de" -> "de.example.a" so hosts of the same domain sort together
const reverseDomain = (d) => {
	const host = clean(d);
	if (!host) return "";
	if (isIp(host)) return host;
	return host.split(".").reverse().join(".");
};

// "a.b.example.de" -> "example.de", "x.example.co.uk" -> "example.co.uk"
const baseDomain = (d) => {
	const host = clean(d);
	if (!host || isIp(host)) return host;
	const labels = host.split(".");
	if (labels.length <= 2) return host;
	const take = twoPartSuffixes.has(labels.slice(-2).join(".")) ? 3 : 2;
	return labels.slice(-take).join(".");
};

export { baseDomain, reverseDomain };
