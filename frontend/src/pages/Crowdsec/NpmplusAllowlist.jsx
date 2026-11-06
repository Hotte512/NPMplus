import { IconPlus, IconTrash, IconUserCheck } from "@tabler/icons-react";
import cn from "clsx";
import Alert from "react-bootstrap/Alert";
import { deleteCrowdsecNpmplusAllowlistItem } from "src/api/backend";
import { Button, Loading } from "src/components";
import { useCrowdsecNpmplusAllowlist } from "src/hooks";
import { formatDateTime, intl, T } from "src/locale";
import { showDeleteConfirmModal } from "src/modals";
import { showObjectSuccess } from "src/notifications";
import { showAllowlistItemModal } from "./AllowlistItemModal";
import HelperHint from "./HelperHint";

const SYNC_BADGE = {
	ok: "bg-green-lt",
	pending: "bg-yellow-lt",
	error: "bg-red-lt",
	expired: "bg-secondary-lt",
};

function ClientIp({ ip, listed }) {
	if (!ip) return null;
	return (
		<Alert variant={listed ? "success" : "info"}>
			<div className="d-flex flex-wrap gap-2 align-items-center">
				<div className="me-auto">
					<T id="crowdsec.exception.my-ip" data={{ ip }} />{" "}
					{listed && <T id="crowdsec.npmplus-allowlist.my-ip.listed" />}
					<div className="small text-secondary">
						<T id="crowdsec.exception.my-ip.help" />
					</div>
				</div>
				{!listed && (
					<Button size="sm" onClick={() => showAllowlistItemModal({ value: ip })}>
						<IconUserCheck size={16} className="me-1" />
						<T id="crowdsec.exception.add-my-ip" />
					</Button>
				)}
			</div>
		</Alert>
	);
}

/**
 * The allowlist "npmplus": stored in NPMplus, applied by the crowdsec-helper container
 */
export default function NpmplusAllowlist() {
	const { data, isPending, error } = useCrowdsecNpmplusAllowlist();
	const items = data?.items ?? [];

	const onDelete = (item) =>
		showDeleteConfirmModal({
			tTitle: "crowdsec.npmplus-allowlist.delete",
			subject: item.value,
			details: item.description,
			onConfirm: async () => {
				await deleteCrowdsecNpmplusAllowlistItem(item.id);
				showObjectSuccess("crowdsec.npmplus-allowlist.item", "deleted");
			},
		});

	return (
		<div className="mb-4">
			<h3 className="mb-1">
				<T id="crowdsec.npmplus-allowlist.title" />
			</h3>
			<p className="text-secondary">
				<T id="crowdsec.npmplus-allowlist.intro" />
			</p>
			{error && <Alert variant="danger">{error.message}</Alert>}
			{isPending ? (
				<Loading noLogo />
			) : (
				data && (
					<>
						<HelperHint helper={data.helper} />
						{data.helper?.state === "active" && data.state === "error" && data.message && (
							<Alert variant="danger">
								<T id="crowdsec.helper.error" />: {data.message}
							</Alert>
						)}
						<ClientIp ip={data.clientIp} listed={data.clientIpListed} />
						<div className="d-flex mb-2">
							<Button color="teal" className="ms-auto" onClick={() => showAllowlistItemModal({})}>
								<IconPlus size={16} className="me-1" />
								<T id="crowdsec.npmplus-allowlist.add" />
							</Button>
						</div>
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
										<th>
											<T id="crowdsec.npmplus-allowlist.sync" />
										</th>
										<th className="w-1" />
									</tr>
								</thead>
								<tbody>
									{items.length === 0 && (
										<tr>
											<td colSpan={5} className="text-secondary">
												<T id="crowdsec.npmplus-allowlist.empty" />
											</td>
										</tr>
									)}
									{items.map((item) => (
										<tr key={item.id}>
											<td>
												<code>{item.value}</code>
											</td>
											<td className="text-break">{item.description}</td>
											<td>
												{item.expiresAt ? (
													formatDateTime(item.expiresAt)
												) : (
													<span className="text-secondary">
														<T id="crowdsec.allowlist.never" />
													</span>
												)}
											</td>
											<td>
												<span
													className={cn("badge", SYNC_BADGE[item.sync] ?? "bg-secondary-lt")}
													title={item.message || undefined}
												>
													<T id={`crowdsec.npmplus-allowlist.sync.${item.sync}`} />
												</span>
												{item.sync === "error" && item.message && (
													<div className="small text-danger text-break">{item.message}</div>
												)}
											</td>
											<td className="text-nowrap">
												<button
													type="button"
													className="btn btn-sm btn-ghost-danger"
													title={intl.formatMessage({
														id: "crowdsec.npmplus-allowlist.delete",
													})}
													onClick={() => onDelete(item)}
												>
													<IconTrash size={16} />
												</button>
											</td>
										</tr>
									))}
								</tbody>
							</table>
						</div>
					</>
				)
			)}
		</div>
	);
}
