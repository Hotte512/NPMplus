import { IconAlertTriangle, IconRefresh } from "@tabler/icons-react";
import { Alert } from "react-bootstrap";
import { Button } from "src/components";
import { useSyncUnifiDns, useUnifiDnsStatus } from "src/hooks";
import { intl, T } from "src/locale";

const ttlLabel = (ttl) => (ttl ? `${ttl}s` : intl.formatMessage({ id: "settings.unifi-dns.ttl.auto" }));

export default function UnifiDnsStatus() {
	const { data, isPending, error } = useUnifiDnsStatus();
	const { mutate: sync, isPending: isSyncing, data: syncResult } = useSyncUnifiDns();

	if (isPending) return null;
	if (error) {
		return (
			<Alert variant="danger" show>
				{error.message}
			</Alert>
		);
	}

	const hostErrors = Object.entries(data.hosts ?? {}).flatMap(([id, s]) =>
		(s.errors ?? []).map((e) => ({ id, error: e })),
	);

	return (
		<div className="mt-4">
			<div className="d-flex align-items-center mb-2">
				<h3 className="mb-0">
					<T id="settings.unifi-dns.records" />
				</h3>
				<Button
					type="button"
					size="sm"
					className="ms-auto"
					isLoading={isSyncing}
					disabled={isSyncing || !data.enabled}
					onClick={() => sync()}
				>
					<IconRefresh size={16} className="me-1" />
					<T id="settings.unifi-dns.sync" />
				</Button>
			</div>
			{data.lastError ? (
				<Alert variant="danger" show>
					{data.lastError.error}
				</Alert>
			) : null}
			{syncResult && syncResult.errors.length === 0 ? (
				<div className="text-success small mb-2">
					<T id="settings.unifi-dns.sync.ok" />
				</div>
			) : null}
			{hostErrors.length > 0 ? (
				<Alert variant="warning" show>
					{hostErrors.map(({ id, error: e }) => (
						<div key={`${id}-${e}`}>
							<IconAlertTriangle size={14} className="me-1" />#{id}: {e}
						</div>
					))}
				</Alert>
			) : null}
			{data.records.length === 0 ? (
				<div className="text-secondary">
					<T id="settings.unifi-dns.records.empty" />
				</div>
			) : (
				<div className="table-responsive">
					<table className="table table-sm table-vcenter card-table">
						<thead>
							<tr>
								<th>
									<T id="column.source" />
								</th>
								<th>
									<T id="column.destination" />
								</th>
								<th>TTL</th>
								<th>
									<T id="proxy-host" />
								</th>
							</tr>
						</thead>
						<tbody>
							{data.records.map((r) => (
								<tr key={r.domain}>
									<td>
										<code>{r.domain}</code>
									</td>
									<td>
										{r.value}{" "}
										<span className="text-secondary small">{r.type.replace("_RECORD", "")}</span>
									</td>
									<td>{ttlLabel(r.ttl)}</td>
									<td>#{r.proxyHostId}</td>
								</tr>
							))}
						</tbody>
					</table>
				</div>
			)}
		</div>
	);
}
