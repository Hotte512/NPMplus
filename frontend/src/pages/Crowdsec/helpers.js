const FRACTION = /\.\d+s$/u;
const UNITS = /(?<value>\d+)(?<unit>[hms])/gu;

/**
 * "3h59m12.345s" => "3h 59m", the lapi returns the remaining duration of a decision
 *
 * @param   {String} duration
 * @returns {String}
 */
const formatDuration = (duration) => {
	const parts = [...(duration ?? "").replace(FRACTION, "s").matchAll(UNITS)].map(
		(m) => `${m.groups.value}${m.groups.unit}`,
	);
	if (parts.length === 0) return duration ?? "";
	// seconds only matter for short decisions
	return (parts.length > 2 ? parts.slice(0, 2) : parts).join(" ");
};

export { formatDuration };
