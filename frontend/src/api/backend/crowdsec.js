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
