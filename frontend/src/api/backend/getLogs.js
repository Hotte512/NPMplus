import * as api from "./base";

export async function getLog(source, params, abortController) {
	return await api.get({ url: `/logs/${source}`, params }, abortController);
}

export async function getLogSince(source, params, abortController) {
	return await api.get({ url: `/logs/${source}/since`, params }, abortController);
}
