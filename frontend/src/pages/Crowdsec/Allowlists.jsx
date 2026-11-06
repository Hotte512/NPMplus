import { IconSearch } from "@tabler/icons-react";
import { useState } from "react";
import Alert from "react-bootstrap/Alert";
import { checkCrowdsecAllowlist } from "src/api/backend";
import { Button, Loading } from "src/components";
import { useCrowdsecAllowlists } from "src/hooks";
import { formatDateTime, T } from "src/locale";
import NpmplusAllowlist from "./NpmplusAllowlist";
import SetupHint from "./SetupHint";

const CSCLI = [
	'docker exec crowdsec cscli allowlists create my_allowlist -d "my allowlist"',
	'docker exec crowdsec cscli allowlists add my_allowlist 192.0.2.10 -d "office"',
];

function CheckForm() {
	const [value, setValue] = useState("");
	const [result, setResult] = useState(null);
	const [error, setError] = useState(null);
	const [busy, setBusy] = useState(false);

	const onSubmit = async (e) => {
		e.preventDefault();
		if (busy) return;
		setBusy(true);
		setError(null);
		setResult(null);
		try {
			setResult(await checkCrowdsecAllowlist(value.trim()));
		} catch (err) {
			setError(err.message);
		} finally {
			setBusy(false);
		}
	};

	return (
		<form className="mb-3" onSubmit={onSubmit}>
			<label className="form-label" htmlFor="crowdsecAllowlistCheck">
				<T id="crowdsec.allowlist.check" />
			</label>
			<div className="input-group">
				<input
					id="crowdsecAllowlistCheck"
					className="form-control"
					required
					autoComplete="off"
					maxLength={64}
					pattern="[0-9a-fA-F:.]+(/[0-9]{1,3})?"
					placeholder="192.0.2.10 / 192.0.2.0/24"
					value={value}
					onChange={(e) => setValue(e.target.value)}
				/>
				<Button type="submit" isLoading={busy} disabled={busy}>
					<IconSearch size={16} className="me-1" />
					<T id="crowdsec.allowlist.check.button" />
				</Button>
			</div>
			{error && (
				<Alert variant="danger" className="mt-2 mb-0">
					{error}
				</Alert>
			)}
			{result && (
				<Alert variant={result.allowlisted ? "success" : "secondary"} className="mt-2 mb-0">
					<code>{result.value}</code>{" "}
					<T id={result.allowlisted ? "crowdsec.allowlist.check.yes" : "crowdsec.allowlist.check.no"} />
					{result.reason && <div className="small text-break">{result.reason}</div>}
				</Alert>
			)}
		</form>
	);
}

export default function Allowlists({ status, onShowConfig }) {
	const connected = Boolean(status?.lapi?.ok);
	const canRead = Boolean(status?.machine?.ok);
	const { data, isPending, error } = useCrowdsecAllowlists({ enabled: canRead });

	if (status && !connected) {
		return (
			<>
				<div className="card-body pb-0">
					<NpmplusAllowlist />
				</div>
				<SetupHint status={status} onShowConfig={onShowConfig} />
			</>
		);
	}

	return (
		<div className="card-body">
			<NpmplusAllowlist />
			<h3 className="mb-1">
				<T id="crowdsec.allowlist.all" />
			</h3>
			<p className="text-secondary">
				<T id="crowdsec.allowlist.intro" />
			</p>
			<Alert variant="info">
				<T id="crowdsec.allowlist.cscli" />
				{CSCLI.map((line) => (
					<pre key={line} className="p-2 mt-1 mb-1">
						{line}
					</pre>
				))}
			</Alert>
			{!canRead ? (
				<p className="text-secondary">
					<T id="crowdsec.machine-required" />
				</p>
			) : (
				<>
					<CheckForm />
					{error && <Alert variant="danger">{error.message}</Alert>}
					{isPending ? (
						<Loading noLogo />
					) : (
						<>
							{(data ?? []).length === 0 && !error && (
								<p className="text-secondary">
									<T id="crowdsec.allowlist.empty" />
								</p>
							)}
							{(data ?? []).map((list) => (
								<div key={list.name} className="mb-4">
									<h3 className="mb-1">
										{list.name}
										{list.name === "npmplus" && (
											<span className="badge bg-teal-lt ms-2">
												<T id="crowdsec.allowlist.managed" />
											</span>
										)}
										{list.consoleManaged && (
											<span className="badge bg-purple-lt ms-2">
												<T id="crowdsec.allowlist.console" />
											</span>
										)}
									</h3>
									{list.description && <div className="text-secondary mb-2">{list.description}</div>}
									<div className="table-responsive">
										<table className="table table-vcenter card-table table-sm">
											<thead>
												<tr>
													<th>
														<T id="crowdsec.allowlist.value" />
													</th>
													<th>
														<T id="crowdsec.allowlist.description" />
													</th>
													<th>
														<T id="crowdsec.allowlist.expiration" />
													</th>
												</tr>
											</thead>
											<tbody>
												{list.items.length === 0 && (
													<tr>
														<td colSpan={3} className="text-secondary">
															<T id="crowdsec.allowlist.no-items" />
														</td>
													</tr>
												)}
												{list.items.map((item) => (
													<tr key={item.value}>
														<td>
															<code>{item.value}</code>
														</td>
														<td className="text-break">{item.description}</td>
														<td>
															{item.expiration ? (
																formatDateTime(item.expiration)
															) : (
																<span className="text-secondary">
																	<T id="crowdsec.allowlist.never" />
																</span>
															)}
														</td>
													</tr>
												))}
											</tbody>
										</table>
									</div>
								</div>
							))}
						</>
					)}
				</>
			)}
		</div>
	);
}
