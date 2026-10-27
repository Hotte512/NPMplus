import * as api from "./base";

export async function getUnifiDnsStatus() {
	return await api.get({ url: "/unifi-dns/status" });
}

export async function syncUnifiDns() {
	return await api.post({ url: "/unifi-dns/sync" });
}
