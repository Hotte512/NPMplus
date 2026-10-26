import { IconSearch } from "@tabler/icons-react";
import { useEffect, useState } from "react";
import Alert from "react-bootstrap/Alert";
import { deleteProxyHost, toggleProxyHost } from "src/api/backend";
import { Button, HasPermission, LoadingPage } from "src/components";
import { getDirectory, useProxyHosts } from "src/hooks";
import { intl, T } from "src/locale";
import { showDeleteConfirmModal, showProxyHostModal } from "src/modals";
import { baseDomain } from "src/modules/Domain";
import { forwardSummary } from "src/modules/Forward";
import { MANAGE, PROXY_HOSTS } from "src/modules/Permissions";
import { showError, showObjectSuccess } from "src/notifications";
import Table from "./Table";

const GROUP_STORAGE_KEY = "npmplus.proxyHosts.groupBy";
const GROUP_MODES = ["directory", "domain", "destination", "tag", "none"];

const loadGroupMode = () => {
	try {
		const v = localStorage.getItem(GROUP_STORAGE_KEY);
		return GROUP_MODES.includes(v) ? v : "directory";
	} catch {
		return "directory";
	}
};

const groupKeyFns = {
	directory: getDirectory,
	domain: (item) => baseDomain(item.domainNames?.[0]),
	destination: (item) => (item.forwardHost ?? "").split("/")[0].toLowerCase(),
	tag: (item) => item.npmplusTags?.[0] ?? "",
};

export default function TableWrapper() {
	const [searchText, setSearchText] = useState("");
	const [groupMode, setGroupMode] = useState(loadGroupMode);
	const search = searchText.toLowerCase().trim();
	const [sorting, setSorting] = useState([{ id: "enabled", desc: false }]);
	const { isFetching, isPending, isError, error, data } = useProxyHosts(["owner", "access_lists", "certificate"]);

	useEffect(() => {
		// this can happen if someone deletes the last item while searching
		if (searchText !== "" && !data?.length) {
			setSearchText("");
		}
	});

	if (isPending) {
		return <LoadingPage />;
	}

	if (isError) {
		return <Alert variant="danger">{error?.message}</Alert>;
	}

	const handleDisableToggle = async (id, enabled) => {
		try {
			await toggleProxyHost(id, enabled);
			showObjectSuccess("proxy-host", enabled ? "enabled" : "disabled");
		} catch (err) {
			showError(<T id={err.message} />);
		}
	};

	let filtered = null;
	if (search) {
		filtered = data?.filter((item) => {
			const directory = getDirectory(item).toLowerCase();
			return (
				item.domainNames.some((domain) => domain.toLowerCase().includes(search)) ||
				forwardSummary(item).toLowerCase().includes(search) ||
				directory.includes(search) ||
				item.npmplusDescription?.toLowerCase().includes(search) ||
				item.npmplusTags?.some((tag) => tag.toLowerCase().includes(search))
			);
		});
	}

	const displayedHosts = filtered ?? data ?? [];
	const groupBy = groupMode === "none" ? undefined : groupKeyFns[groupMode];
	// the directory grouping only shows up once at least one host has a directory
	const groupingActive = groupBy && (groupMode !== "directory" || displayedHosts.some(getDirectory));

	const changeGroupMode = (mode) => {
		setGroupMode(mode);
		try {
			localStorage.setItem(GROUP_STORAGE_KEY, mode);
		} catch {
			// storage unavailable, the choice just isn't remembered
		}
	};

	const sharedTableProps = {
		isFiltered: search,
		onTagClick: (tag) => setSearchText(tag),
		isFetching,
		sorting,
		onSortingChange: setSorting,
		onEdit: (id) => showProxyHostModal(id),
		onClone: (id) => showProxyHostModal(id, true),
		onDelete: (id) => {
			const host = data?.find((item) => item.id === id);
			showDeleteConfirmModal({
				title: <T id="object.delete" tData={{ object: "proxy-host" }} />,
				onConfirm: async () => {
					await deleteProxyHost(id);
					showObjectSuccess("proxy-host", "deleted");
				},
				children: <T id="object.delete.content" tData={{ object: "proxy-host" }} />,
				subject: host?.domainNames.join(", "),
				details: host && forwardSummary(host),
			});
		},
		onDisableToggle: handleDisableToggle,
		onNew: () => showProxyHostModal("new"),
	};

	return (
		<div className="card mt-4">
			<div className="card-status-top bg-lime" />
			<div className="card-table">
				<div className="card-header">
					<div className="row w-full">
						<div className="col">
							<h2 className="mt-1 mb-0">
								<T id="proxy-hosts" />
							</h2>
						</div>
						<div className="col-md-auto col-sm-12">
							<div className="ms-auto d-flex flex-wrap btn-list">
								{data?.length ? (
									<div className="input-group input-group-flat w-auto">
										<span className="input-group-text input-group-text-sm">
											<IconSearch size={16} />
										</span>
										<input
											type="text"
											className="form-control form-control-sm"
											autoComplete="off"
											value={searchText}
											onChange={(e) => setSearchText(e.target.value)}
										/>
									</div>
								) : null}
								{data?.length ? (
									<select
										className="form-select form-select-sm w-auto"
										aria-label={intl.formatMessage({ id: "proxy-hosts.group-by" })}
										title={intl.formatMessage({ id: "proxy-hosts.group-by" })}
										value={groupMode}
										onChange={(e) => changeGroupMode(e.target.value)}
									>
										{GROUP_MODES.map((mode) => (
											<option key={mode} value={mode}>
												{intl.formatMessage({ id: "proxy-hosts.group-by" })}:{" "}
												{intl.formatMessage({ id: `proxy-hosts.group-by.${mode}` })}
											</option>
										))}
									</select>
								) : null}
								<HasPermission section={PROXY_HOSTS} permission={MANAGE} hideError>
									{data?.length ? (
										<Button
											size="sm"
											className="btn-lime"
											onClick={() => showProxyHostModal("new")}
										>
											<T id="object.add" tData={{ object: "proxy-host" }} />
										</Button>
									) : null}
								</HasPermission>
							</div>
						</div>
					</div>
				</div>
				<Table
					data={displayedHosts}
					groupBy={groupingActive ? groupBy : undefined}
					renderGroupLabel={(key) =>
						key === "" ? (
							<T
								id={
									groupMode === "directory" ? "proxy-host.no-directory" : "proxy-hosts.group-by.other"
								}
							/>
						) : (
							key
						)
					}
					{...sharedTableProps}
				/>
			</div>
		</div>
	);
}
