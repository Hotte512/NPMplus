import { IconEdit, IconPlus, IconTrash, IconUserCheck } from "@tabler/icons-react";
import Alert from "react-bootstrap/Alert";
import { deleteCrowdsecException } from "src/api/backend";
import { Button, Loading } from "src/components";
import { useCrowdsecClientIp, useCrowdsecExceptions } from "src/hooks";
import { intl, T } from "src/locale";
import { showDeleteConfirmModal } from "src/modals";
import { showObjectSuccess } from "src/notifications";
import { showExceptionModal } from "./ExceptionModal";

const hostName = (host) => host.domainNames?.[0] ?? `#${host.id}`;

function ClientIp() {
	const { data } = useCrowdsecClientIp();
	if (!data?.ip) return null;
	const covered = data.exemptGlobal;
	const hostCount = data.exemptProxyHostIds?.length ?? 0;

	return (
		<Alert variant={covered ? "success" : "info"}>
			<div className="d-flex flex-wrap gap-2 align-items-center">
				<div className="me-auto">
					<T id="crowdsec.exception.my-ip" data={{ ip: data.ip }} />{" "}
					{covered ? (
						<T id="crowdsec.exception.my-ip.global" />
					) : hostCount > 0 ? (
						<T id="crowdsec.exception.my-ip.hosts" data={{ count: hostCount }} />
					) : null}
					<div className="small text-secondary">
						<T id="crowdsec.exception.my-ip.help" />
					</div>
				</div>
				{!covered && (
					<Button size="sm" onClick={() => showExceptionModal({ value: data.ip })}>
						<IconUserCheck size={16} className="me-1" />
						<T id="crowdsec.exception.add-my-ip" />
					</Button>
				)}
			</div>
		</Alert>
	);
}

export default function Exceptions() {
	const { data, isPending, error } = useCrowdsecExceptions();
	const exceptions = data ?? [];

	const onDelete = (exception) =>
		showDeleteConfirmModal({
			tTitle: "crowdsec.exception.delete",
			subject: exception.value,
			details: exception.description,
			onConfirm: async () => {
				await deleteCrowdsecException(exception.id);
				showObjectSuccess("crowdsec.exception", "deleted");
			},
		});

	return (
		<div className="card-body">
			<p className="text-secondary">
				<T id="crowdsec.exception.intro" />
			</p>
			<ClientIp />
			<div className="d-flex mb-2">
				<Button color="teal" className="ms-auto" onClick={() => showExceptionModal({})}>
					<IconPlus size={16} className="me-1" />
					<T id="crowdsec.exception.add" />
				</Button>
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
									<T id="crowdsec.exception.value" />
								</th>
								<th>
									<T id="crowdsec.exception.scope" />
								</th>
								<th>
									<T id="crowdsec.exception.description" />
								</th>
								<th className="w-1" />
							</tr>
						</thead>
						<tbody>
							{exceptions.length === 0 && (
								<tr>
									<td colSpan={4} className="text-secondary">
										<T id="crowdsec.exception.empty" />
									</td>
								</tr>
							)}
							{exceptions.map((e) => (
								<tr key={e.id}>
									<td>
										<code>{e.value}</code>
										{e.effective === false && (
											<div>
												<span className="badge bg-red-lt">
													<T id="crowdsec.exception.too-large" />
												</span>
											</div>
										)}
									</td>
									<td>
										{e.scope === "global" ? (
											<span className="badge bg-orange-lt">
												<T id="crowdsec.exception.scope.global.short" />
											</span>
										) : e.proxyHosts.length === 0 ? (
											<span className="badge bg-red-lt">
												<T id="crowdsec.exception.no-hosts" />
											</span>
										) : (
											<div className="d-flex flex-wrap gap-1">
												{e.proxyHosts.map((h) => (
													<span
														key={h.id}
														className={`badge ${h.enabled ? "bg-blue-lt" : "bg-secondary-lt"}`}
													>
														{hostName(h)}
													</span>
												))}
											</div>
										)}
									</td>
									<td className="text-break">{e.description}</td>
									<td className="text-nowrap">
										<button
											type="button"
											className="btn btn-sm btn-ghost-secondary"
											title={intl.formatMessage({ id: "crowdsec.exception.edit" })}
											onClick={() => showExceptionModal({ exception: e })}
										>
											<IconEdit size={16} />
										</button>
										<button
											type="button"
											className="btn btn-sm btn-ghost-danger"
											title={intl.formatMessage({ id: "crowdsec.exception.delete" })}
											onClick={() => onDelete(e)}
										>
											<IconTrash size={16} />
										</button>
									</td>
								</tr>
							))}
						</tbody>
					</table>
				</div>
			)}
		</div>
	);
}
