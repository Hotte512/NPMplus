import { IconSearch, IconTrash } from "@tabler/icons-react";
import { useEffect, useState } from "react";
import Alert from "react-bootstrap/Alert";
import { deleteCrowdsecDecisionsByIp } from "src/api/backend";
import { Loading } from "src/components";
import { useCrowdsecAlerts } from "src/hooks";
import { formatDateTime, intl, T } from "src/locale";
import { showError, showObjectSuccess } from "src/notifications";
import SetupHint from "./SetupHint";

const LIMITS = [50, 100, 500, 1000];
const IP_OR_RANGE = /^[0-9a-fA-F:.]+(?:\/\d{1,3})?$/u;
const FILTER_DEBOUNCE = 400;

export default function Alerts({ status, onShowConfig }) {
	const canRead = Boolean(status?.machine?.ok);
	const [filterInput, setFilterInput] = useState("");
	const [filter, setFilter] = useState("");
	const [limit, setLimit] = useState(100);
	const [deleting, setDeleting] = useState(null);

	useEffect(() => {
		const timer = setTimeout(() => setFilter(filterInput.trim()), FILTER_DEBOUNCE);
		return () => clearTimeout(timer);
	}, [filterInput]);

	// an ip filters on the lapi side, anything else is a scenario
	const params = { limit, ...(IP_OR_RANGE.test(filter) ? { ip: filter } : filter ? { scenario: filter } : {}) };
	const { data, isPending, error } = useCrowdsecAlerts(params, { enabled: canRead });

	if (status && !status.bouncer?.ok) return <SetupHint status={status} onShowConfig={onShowConfig} />;
	if (status && !canRead) {
		return (
			<div className="card-body">
				<Alert variant="info">
					<T id="crowdsec.machine-required" />
					{status.machine?.error && <div className="small mt-1 text-break">{status.machine.error}</div>}
				</Alert>
			</div>
		);
	}

	const onUnban = async (ip) => {
		setDeleting(ip);
		try {
			await deleteCrowdsecDecisionsByIp(ip);
			showObjectSuccess("crowdsec.decision", "deleted");
		} catch (err) {
			showError(err.message);
		} finally {
			setDeleting(null);
		}
	};

	return (
		<div className="card-body">
			<div className="d-flex flex-wrap gap-2 align-items-center mb-2">
				<div className="input-group input-group-flat w-auto">
					<span className="input-group-text input-group-text-sm">
						<IconSearch size={16} />
					</span>
					<input
						type="text"
						className="form-control form-control-sm"
						autoComplete="off"
						maxLength={255}
						placeholder={intl.formatMessage({ id: "crowdsec.alert.search-placeholder" })}
						value={filterInput}
						onChange={(e) => setFilterInput(e.target.value)}
					/>
				</div>
				<select
					className="form-select form-select-sm w-auto"
					value={limit}
					onChange={(e) => setLimit(Number(e.target.value))}
				>
					{LIMITS.map((l) => (
						<option key={l} value={l}>
							{l}
						</option>
					))}
				</select>
			</div>
			{error && <Alert variant="danger">{error.message}</Alert>}
			{isPending ? (
				<Loading noLogo />
			) : (
				<div className="table-responsive">
					<table className="table table-vcenter card-table">
						<thead>
							<tr>
								<th>
									<T id="crowdsec.alert.time" />
								</th>
								<th>
									<T id="crowdsec.alert.source" />
								</th>
								<th>
									<T id="crowdsec.decision.scenario" />
								</th>
								<th>
									<T id="crowdsec.alert.targets" />
								</th>
								<th>
									<T id="crowdsec.alert.events" />
								</th>
								<th className="w-1" />
							</tr>
						</thead>
						<tbody>
							{(data ?? []).length === 0 && (
								<tr>
									<td colSpan={6} className="text-secondary">
										<T id="crowdsec.alert.empty" />
									</td>
								</tr>
							)}
							{(data ?? []).map((a) => {
								// expired decisions of an alert have a negative remaining duration
								const active = a.decisions.find((d) => d.duration && !d.duration.startsWith("-"));
								return (
									<tr key={a.id}>
										<td className="text-nowrap">
											{a.createdAt ? formatDateTime(a.createdAt) : ""}
										</td>
										<td>
											<code>{a.source.value}</code>
											<div className="text-secondary small">
												{[a.source.country, a.source.asName].filter(Boolean).join(" · ")}
											</div>
										</td>
										<td className="text-break">
											{a.scenario}
											{active && <span className="badge bg-red-lt ms-1">{active.type}</span>}
										</td>
										<td className="small text-break" style={{ maxWidth: "24rem" }}>
											{a.hosts.length > 0 && <div>{a.hosts.join(", ")}</div>}
											{a.paths.length > 0 && (
												<div className="text-secondary" title={a.paths.join("\n")}>
													{a.paths.slice(0, 5).join(", ")}
													{a.paths.length > 5 && " …"}
												</div>
											)}
										</td>
										<td>{a.eventsCount}</td>
										<td>
											{active && (
												<button
													type="button"
													className="btn btn-sm btn-ghost-danger"
													title={intl.formatMessage({ id: "crowdsec.decision.delete" })}
													disabled={deleting === a.source.value}
													onClick={() => onUnban(a.source.value)}
												>
													<IconTrash size={16} />
												</button>
											)}
										</td>
									</tr>
								);
							})}
						</tbody>
					</table>
				</div>
			)}
		</div>
	);
}
