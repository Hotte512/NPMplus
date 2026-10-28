import { useQuery } from "@tanstack/react-query";
import { getCrowdsecAlerts, getCrowdsecConfig, getCrowdsecDecisions, getCrowdsecStatus } from "src/api/backend";

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

export { useCrowdsecAlerts, useCrowdsecConfig, useCrowdsecDecisions, useCrowdsecStatus };
