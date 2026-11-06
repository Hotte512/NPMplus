import * as api from "./base";

export async function getCrowdsecStatus() {
	return await api.get({ url: "/crowdsec/status" });
}

export async function getCrowdsecConfig() {
	return await api.get({ url: "/crowdsec/config" });
}

export async function updateCrowdsecConfig(data) {
	return await api.put({ url: "/crowdsec/config", data });
}

export async function getCrowdsecDecisions() {
	return await api.get({ url: "/crowdsec/decisions" });
}

export async function createCrowdsecDecision(data) {
	return await api.post({ url: "/crowdsec/decisions", data });
}

export async function deleteCrowdsecDecision(id) {
	return await api.del({ url: `/crowdsec/decisions/${id}` });
}

export async function deleteCrowdsecDecisionsByIp(ip) {
	return await api.del({ url: "/crowdsec/decisions", params: { ip } });
}

export async function getCrowdsecAlerts(params) {
	return await api.get({ url: "/crowdsec/alerts", params });
}

export async function getCrowdsecExceptions() {
	return await api.get({ url: "/crowdsec/exceptions" });
}

export async function createCrowdsecException(data) {
	return await api.post({ url: "/crowdsec/exceptions", data });
}

export async function updateCrowdsecException(id, data) {
	return await api.put({ url: `/crowdsec/exceptions/${id}`, data });
}

export async function deleteCrowdsecException(id) {
	return await api.del({ url: `/crowdsec/exceptions/${id}` });
}

export async function getCrowdsecClientIp() {
	return await api.get({ url: "/crowdsec/client-ip" });
}

export async function getCrowdsecAllowlists() {
	return await api.get({ url: "/crowdsec/allowlists" });
}

export async function checkCrowdsecAllowlist(value) {
	return await api.get({ url: "/crowdsec/allowlists/check", params: { value } });
}

export async function getCrowdsecHelper() {
	return await api.get({ url: "/crowdsec/helper" });
}

export async function getCrowdsecNpmplusAllowlist() {
	return await api.get({ url: "/crowdsec/npmplus-allowlist" });
}

export async function createCrowdsecNpmplusAllowlistItem(data) {
	return await api.post({ url: "/crowdsec/npmplus-allowlist", data });
}

export async function deleteCrowdsecNpmplusAllowlistItem(id) {
	return await api.del({ url: `/crowdsec/npmplus-allowlist/${id}` });
}
