import errs from "../lib/error.js";
import settingModel from "../models/setting.js";
import internalUnifiDns from "./unifi-dns.js";

// hooks for internal/setting.js, kept here so the upstream file only needs a few one-line calls

/**
 * The api key is write only: hide it from every settings response and the audit log
 *
 * @param   {Object} row  setting row
 * @returns {Object}
 */
const redactSetting = (row) =>
	row?.id === "unifi-dns"
		? { ...row, meta: { ...row.meta, api_key: "", api_key_set: Boolean(row.meta?.api_key) } }
		: row;

/**
 * Before saving: an empty api key keeps the stored one
 *
 * @param {Object} data  update payload, changed in place
 */
const prepareSettingUpdate = async (data) => {
	if (data.id !== "unifi-dns" || !data.meta) return;
	const stored = (await settingModel.query().where({ id: data.id }).first())?.meta ?? {};
	const { api_key_set, ...meta } = data.meta;
	data.meta = { ...stored, ...meta, api_key: meta.api_key || stored.api_key || "" };
};

/**
 * After saving: sync all proxy hosts, errors are reported to the user (the setting is saved anyway)
 *
 * @param {Object} row  saved setting row
 */
const afterSettingUpdate = async (row) => {
	if (row.id !== "unifi-dns") return;
	const errors = await internalUnifiDns.syncAll();
	if (errors.length > 0) {
		throw new errs.ValidationError(`Saved, but the UniFi DNS sync failed: ${errors.join("; ")}`);
	}
};

export { afterSettingUpdate, prepareSettingUpdate, redactSetting };
