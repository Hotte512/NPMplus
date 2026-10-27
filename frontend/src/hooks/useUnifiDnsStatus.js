import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { getUnifiDnsStatus, syncUnifiDns } from "src/api/backend";

const useUnifiDnsStatus = (options = {}) =>
	useQuery({
		queryKey: ["unifi-dns-status"],
		queryFn: getUnifiDnsStatus,
		staleTime: 30 * 1000,
		retry: false,
		...options,
	});

const useSyncUnifiDns = () => {
	const queryClient = useQueryClient();
	return useMutation({
		mutationFn: syncUnifiDns,
		onSettled: () => queryClient.invalidateQueries({ queryKey: ["unifi-dns-status"] }),
	});
};

// the sync after saving a proxy host runs in the background, refresh the status once it should be done
const refreshUnifiDnsStatusSoon = (queryClient) =>
	setTimeout(() => queryClient.invalidateQueries({ queryKey: ["unifi-dns-status"] }), 3000);

export { refreshUnifiDnsStatusSoon, useSyncUnifiDns, useUnifiDnsStatus };
