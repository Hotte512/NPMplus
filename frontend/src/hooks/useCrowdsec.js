import { useQuery } from "@tanstack/react-query";
import {
	getCrowdsecAlerts,
	getCrowdsecAllowlists,
	getCrowdsecAppsecBody,
	getCrowdsecClientIp,
	getCrowdsecConfig,
	getCrowdsecDecisions,
	getCrowdsecExceptions,
	getCrowdsecHelper,
	getCrowdsecNpmplusAllowlist,
	getCrowdsecStatus,
} from "src/api/backend";

const useCrowdsecStatus = () =>
	useQuery({
		queryKey: ["crowdsec", "status"],
		queryFn: () => getCrowdsecStatus(),
		staleTime: 30 * 1000,
	});

const useCrowdsecConfig = () =>
	useQuery({
		queryKey: ["crowdsec", "config"],
		queryFn: () => getCrowdsecConfig(),
		staleTime: 60 * 1000,
	});

const useCrowdsecDecisions = (options = {}) =>
	useQuery({
		queryKey: ["crowdsec", "decisions"],
		queryFn: () => getCrowdsecDecisions(),
		staleTime: 10 * 1000,
		retry: false,
		...options,
	});

const useCrowdsecAlerts = (params, options = {}) =>
	useQuery({
		queryKey: ["crowdsec", "alerts", params],
		queryFn: () => getCrowdsecAlerts(params),
		staleTime: 10 * 1000,
		retry: false,
		...options,
	});

const useCrowdsecExceptions = () =>
	useQuery({
		queryKey: ["crowdsec", "exceptions"],
		queryFn: () => getCrowdsecExceptions(),
		staleTime: 60 * 1000,
	});

const useCrowdsecClientIp = () =>
	useQuery({
		queryKey: ["crowdsec", "client-ip"],
		queryFn: () => getCrowdsecClientIp(),
		staleTime: 60 * 1000,
	});

const useCrowdsecAllowlists = (options = {}) =>
	useQuery({
		queryKey: ["crowdsec", "allowlists"],
		queryFn: () => getCrowdsecAllowlists(),
		staleTime: 30 * 1000,
		retry: false,
		...options,
	});

// the helper polls every 5 s, so its state is refreshed while the page is open
const useCrowdsecHelper = () =>
	useQuery({
		queryKey: ["crowdsec", "helper"],
		queryFn: () => getCrowdsecHelper(),
		staleTime: 10 * 1000,
		refetchInterval: 30 * 1000,
	});

const useCrowdsecNpmplusAllowlist = () =>
	useQuery({
		queryKey: ["crowdsec", "npmplus-allowlist"],
		queryFn: () => getCrowdsecNpmplusAllowlist(),
		staleTime: 5 * 1000,
		// entries wait for the helper, look again until it reports them
		refetchInterval: (query) =>
			query.state.data?.items?.some((i) => i.sync === "pending") && query.state.data?.helper?.state === "active"
				? 5 * 1000
				: 30 * 1000,
	});

const useCrowdsecAppsecBody = () =>
	useQuery({
		queryKey: ["crowdsec", "appsec-body"],
		queryFn: () => getCrowdsecAppsecBody(),
		staleTime: 5 * 1000,
		refetchInterval: (query) =>
			query.state.data?.sync === "pending" && query.state.data?.helper?.state === "active" ? 5 * 1000 : 30 * 1000,
	});

export {
	useCrowdsecAlerts,
	useCrowdsecAllowlists,
	useCrowdsecAppsecBody,
	useCrowdsecClientIp,
	useCrowdsecConfig,
	useCrowdsecDecisions,
	useCrowdsecExceptions,
	useCrowdsecHelper,
	useCrowdsecNpmplusAllowlist,
	useCrowdsecStatus,
};
