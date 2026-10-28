import { IconBan, IconSearch, IconTrash } from "@tabler/icons-react";
import { useState } from "react";
import Alert from "react-bootstrap/Alert";
import { createCrowdsecDecision, deleteCrowdsecDecision } from "src/api/backend";
import { Button, Loading } from "src/components";
import { useCrowdsecDecisions } from "src/hooks";
import { intl, T } from "src/locale";
import { showError, showObjectSuccess } from "src/notifications";
import { formatDuration } from "./helpers";
import SetupHint from "./SetupHint";

const DURATIONS = ["1h", "4h", "24h", "168h", "720h", "8760h"];
const PAGE_SIZE = 50;

const matches = (decision, filter) =>
	!filter ||
	[decision.value, decision.scenario, decision.origin].some((v) => v?.toLowerCase().includes(filter.toLowerCase()));

function BanForm() {
	const [value, setValue] = useState("");
	const [duration, setDuration] = useState("4h");
	const [type, setType] = useState("ban");
	const [reason, setReason] = useState("");
	const [busy, setBusy] = useState(false);

	const onSubmit = async (e) => {
		e.preventDefault();
		if (busy) return;
		setBusy(true);
		try {
			await createCrowdsecDecision({ value: value.trim(), duration, type, reason: reason.trim() || undefined });
			showObjectSuccess("crowdsec.decision", "saved");
			setValue("");
			setReason("");
		} catch (err) {
			showError(err.message);
		} finally {
			setBusy(false);
		}
	};

	return (
		<form className="row g-2 align-items-end mb-3" onSubmit={onSubmit}>
			<div className="col-12 col-md-3">
				<label className="form-label" htmlFor="crowdsecBanValue">
					<T id="crowdsec.decision.value" />
				</label>
				<input
					id="crowdsecBanValue"
					className="form-control"
					required
					maxLength={64}
					pattern="[0-9a-fA-F:.]+(/[0-9]{1,3})?"
					placeholder="203.0.113.7 / 203.0.113.0/24"
					value={value}
					onChange={(e) => setValue(e.target.value)}
				/>
			</div>
			<div className="col-6 col-md-2">
				<label className="form-label" htmlFor="crowdsecBanDuration">
					<T id="crowdsec.decision.duration" />
				</label>
				<select
					id="crowdsecBanDuration"
					className="form-select"
					value={duration}
					onChange={(e) => setDuration(e.target.value)}
				>
					{DURATIONS.map((d) => (
						<option key={d} value={d}>
							{intl.formatMessage({ id: `crowdsec.duration.${d}` })}
						</option>
					))}
				</select>
			</div>
			<div className="col-6 col-md-2">
				<label className="form-label" htmlFor="crowdsecBanType">
					<T id="crowdsec.decision.type" />
				</label>
				<select
					id="crowdsecBanType"
					className="form-select"
					value={type}
					onChange={(e) => setType(e.target.value)}
				>
					<option value="ban">ban</option>
					<option value="captcha">captcha</option>
				</select>
			</div>
			<div className="col-12 col-md-3">
				<label className="form-label" htmlFor="crowdsecBanReason">
					<T id="crowdsec.decision.reason" />
				</label>
				<input
					id="crowdsecBanReason"
					className="form-control"
					maxLength={255}
					value={reason}
					onChange={(e) => setReason(e.target.value)}
				/>
			</div>
			<div className="col-12 col-md-2">
				<Button type="submit" color="red" className="w-100" isLoading={busy} disabled={busy}>
					<IconBan size={16} className="me-1" />
					<T id="crowdsec.decision.add" />
				</Button>
			</div>
		</form>
	);
}

export default function Decisions({ status, onShowConfig }) {
	const connected = Boolean(status?.bouncer?.ok);
	const canManage = Boolean(status?.machine?.ok);
	const { data, isPending, error } = useCrowdsecDecisions({ enabled: connected });
	const [filter, setFilter] = useState("");
	const [page, setPage] = useState(0);
	const [deleting, setDeleting] = useState(null);

	if (status && !connected) return <SetupHint status={status} onShowConfig={onShowConfig} />;

	const onDelete = async (decision) => {
		setDeleting(decision.id);
		try {
			await deleteCrowdsecDecision(decision.id);
			showObjectSuccess("crowdsec.decision", "deleted");
		} catch (err) {
			showError(err.message);
		} finally {
			setDeleting(null);
		}
	};

	const rows = (data ?? []).filter((d) => matches(d, filter));
	const pages = Math.max(1, Math.ceil(rows.length / PAGE_SIZE));
	const current = Math.min(page, pages - 1);
	const visible = rows.slice(current * PAGE_SIZE, (current + 1) * PAGE_SIZE);

	return (
		<div className="card-body">
			{canManage ? (
				<BanForm />
			) : (
				<p className="text-secondary">
					<T id="crowdsec.machine-required" />
				</p>
			)}
			<div className="d-flex flex-wrap gap-2 align-items-center mb-2">
				<div className="input-group input-group-flat w-auto">
					<span className="input-group-text input-group-text-sm">
						<IconSearch size={16} />
					</span>
					<input
						type="text"
						className="form-control form-control-sm"
						autoComplete="off"
						placeholder={intl.formatMessage({ id: "crowdsec.search-placeholder" })}
						value={filter}
						onChange={(e) => {
							setFilter(e.target.value);
							setPage(0);
						}}
					/>
				</div>
				<span className="text-secondary small">
					<T id="crowdsec.decision.count" data={{ count: rows.length }} />
				</span>
			</div>
			{error && <Alert variant="danger">{error.message}</Alert>}
			{isPending && connected ? (
				<Loading noLogo />
			) : (
				<div className="table-responsive">
					<table className="table table-vcenter card-table">
						<thead>
							<tr>
								<th>
									<T id="crowdsec.decision.value" />
								</th>
								<th>
									<T id="crowdsec.decision.scenario" />
								</th>
								<th>
									<T id="crowdsec.decision.origin" />
								</th>
								<th>
									<T id="crowdsec.decision.type" />
								</th>
								<th>
									<T id="crowdsec.decision.remaining" />
								</th>
								{canManage && <th className="w-1" />}
							</tr>
						</thead>
						<tbody>
							{visible.length === 0 && (
								<tr>
									<td colSpan={6} className="text-secondary">
										<T id="crowdsec.decision.empty" />
									</td>
								</tr>
							)}
							{visible.map((d) => (
								<tr key={d.id}>
									<td>
										<code>{d.value}</code>
										{d.scope !== "Ip" && (
											<span className="badge bg-secondary-lt ms-1">{d.scope}</span>
										)}
									</td>
									<td className="text-break">{d.scenario}</td>
									<td>
										<span className="badge bg-blue-lt">{d.origin}</span>
									</td>
									<td>{d.type}</td>
									<td>{formatDuration(d.duration)}</td>
									{canManage && (
										<td>
											<button
												type="button"
												className="btn btn-sm btn-ghost-danger"
												title={intl.formatMessage({ id: "crowdsec.decision.delete" })}
												disabled={deleting === d.id}
												onClick={() => onDelete(d)}
											>
												<IconTrash size={16} />
											</button>
										</td>
									)}
								</tr>
							))}
						</tbody>
					</table>
				</div>
			)}
			{pages > 1 && (
				<div className="d-flex gap-2 justify-content-end align-items-center mt-2">
					<button
						type="button"
						className="btn btn-sm"
						disabled={current === 0}
						onClick={() => setPage(current - 1)}
					>
						‹
					</button>
					<span className="text-secondary small">
						{current + 1} / {pages}
					</span>
					<button
						type="button"
						className="btn btn-sm"
						disabled={current >= pages - 1}
						onClick={() => setPage(current + 1)}
					>
						›
					</button>
				</div>
			)}
		</div>
	);
}
