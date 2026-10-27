import { IconAlertTriangle, IconCheck } from "@tabler/icons-react";
import OverlayTrigger from "react-bootstrap/OverlayTrigger";
import Popover from "react-bootstrap/Popover";
import { useUnifiDnsStatus } from "src/hooks";
import { T } from "src/locale";

const hostStatus = (data, hostId) => ({
	records: (data?.records ?? []).filter((r) => r.proxyHostId === Number(hostId)),
	errors: data?.hosts?.[hostId]?.errors ?? [],
});

const StatusLines = ({ records, errors }) => (
	<>
		{records.map((r) => (
			<div key={r.domain} className="text-success">
				<IconCheck size={14} className="me-1" />
				{r.domain} → {r.value}
			</div>
		))}
		{errors.map((e) => (
			<div key={e} className="text-danger">
				<IconAlertTriangle size={14} className="me-1" />
				{e}
			</div>
		))}
	</>
);

/**
 * Local dns records of a proxy host on the UniFi gateway, shown in the proxy host modal
 */
export function UnifiDnsHostStatus({ hostId }) {
	const { data } = useUnifiDnsStatus();
	const status = hostStatus(data, hostId);
	if (!data?.enabled || (status.records.length === 0 && status.errors.length === 0)) return null;
	return (
		<div className="small pb-2">
			<StatusLines {...status} />
		</div>
	);
}

/**
 * Small badge for the proxy host table, green when all records exist, red on errors
 */
export function UnifiDnsBadge({ host }) {
	const { data } = useUnifiDnsStatus({ refetchInterval: 60 * 1000 });
	if (!data?.enabled || !host.npmplusUnifiDns || host.npmplusUnifiDns === "off") return null;
	const status = hostStatus(data, host.id);
	if (status.records.length === 0 && status.errors.length === 0) return null;
	const failed = status.errors.length > 0;
	return (
		<OverlayTrigger
			trigger={["hover", "click", "focus"]}
			placement="bottom"
			overlay={
				<Popover id={`unifi-dns-${host.id}`}>
					<Popover.Body className="small">
						<div className="fw-bold mb-1">
							<T id="host.unifi-dns" />
						</div>
						<StatusLines {...status} />
					</Popover.Body>
				</Popover>
			}
		>
			<span className={`badge ${failed ? "bg-red-lt" : "bg-green-lt"} ms-1 cursor-pointer`}>DNS</span>
		</OverlayTrigger>
	);
}
