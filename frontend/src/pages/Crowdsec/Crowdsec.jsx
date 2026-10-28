import { IconRefresh } from "@tabler/icons-react";
import cn from "clsx";
import { useState } from "react";
import { useSearchParams } from "react-router";
import { queryClient } from "src/api/backend/base";
import { useCrowdsecStatus } from "src/hooks";
import { T } from "src/locale";
import Alerts from "./Alerts";
import Config from "./Config";
import Decisions from "./Decisions";

const TABS = { decisions: Decisions, alerts: Alerts, config: Config };

const StatusBadge = ({ ok, label, title }) => (
	<span className={cn("badge", ok ? "bg-green-lt" : "bg-red-lt")} title={title || undefined}>
		<T id={label} />
	</span>
);

export default function Crowdsec() {
	const [searchParams, setSearchParams] = useSearchParams();
	const [tab, setTab] = useState(() => (TABS[searchParams.get("tab")] ? searchParams.get("tab") : "decisions"));
	const { data: status } = useCrowdsecStatus();
	const Tab = TABS[tab];

	const selectTab = (key) => {
		setTab(key);
		setSearchParams(key === "decisions" ? {} : { tab: key }, { replace: true });
	};

	return (
		<div className="card mt-4">
			<div className="card-status-top bg-orange" />
			<div className="card-header">
				<div className="row w-full g-2 align-items-center">
					<div className="col-auto">
						<h2 className="mt-1 mb-0">CrowdSec</h2>
					</div>
					<div className="col-md col-sm-12">
						<div className="d-flex flex-wrap gap-2 justify-content-md-end align-items-center">
							{status && (
								<>
									<StatusBadge
										ok={status.enabled && status.active}
										label={
											status.enabled && status.active
												? "crowdsec.status.active"
												: "crowdsec.status.inactive"
										}
									/>
									<StatusBadge
										ok={status.lapi.ok}
										label={
											status.lapi.ok ? "crowdsec.status.lapi-ok" : "crowdsec.status.lapi-error"
										}
										title={status.lapi.error}
									/>
									{status.lapi.ok && (
										<StatusBadge
											ok={status.bouncer.ok}
											label={
												status.bouncer.ok
													? "crowdsec.status.bouncer-ok"
													: "crowdsec.status.bouncer-error"
											}
											title={status.bouncer.error}
										/>
									)}
									{status.lapi.ok && status.machine.configured && (
										<StatusBadge
											ok={status.machine.ok}
											label={
												status.machine.ok
													? "crowdsec.status.machine-ok"
													: "crowdsec.status.machine-error"
											}
											title={status.machine.error}
										/>
									)}
								</>
							)}
							<button
								type="button"
								className="btn btn-sm"
								onClick={() => queryClient.invalidateQueries({ queryKey: ["crowdsec"] })}
							>
								<IconRefresh size={16} />
								<T id="logs.refresh" />
							</button>
						</div>
					</div>
				</div>
			</div>
			<div className="card-header">
				<ul className="nav nav-tabs card-header-tabs">
					{Object.keys(TABS).map((key) => (
						<li key={key} className="nav-item">
							<button
								type="button"
								className={cn("nav-link", { active: tab === key })}
								onClick={() => selectTab(key)}
							>
								<T id={`crowdsec.tab.${key}`} />
							</button>
						</li>
					))}
				</ul>
			</div>
			<Tab status={status} onShowConfig={() => selectTab("config")} />
		</div>
	);
}
