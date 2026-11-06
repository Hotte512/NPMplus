import cn from "clsx";
import { useEffect, useState } from "react";
import Alert from "react-bootstrap/Alert";
import { updateCrowdsecAppsecBody } from "src/api/backend";
import { Button, Loading } from "src/components";
import { useCrowdsecAppsecBody } from "src/hooks";
import { formatDateTime, T } from "src/locale";
import { showObjectSuccess } from "src/notifications";
import HelperHint from "./HelperHint";

const ACTIONS = ["partial", "drop", "allow"];
const MIB = 1024 * 1024;

const SYNC_BADGE = {
	ok: "bg-green-lt",
	pending: "bg-yellow-lt",
	error: "bg-red-lt",
	unmanaged: "bg-secondary-lt",
};

const formatMb = (bytes) => (bytes % MIB === 0 ? String(bytes / MIB) : (bytes / MIB).toFixed(1));

/**
 * AppSec request body limit, applied by the crowdsec-helper container (appsec-config npmplus/body-limit)
 */
export default function AppsecBody() {
	const { data, isPending, error } = useCrowdsecAppsecBody();
	const [mb, setMb] = useState("");
	const [action, setAction] = useState("partial");
	const [errorMsg, setErrorMsg] = useState(null);
	const [isSubmitting, setIsSubmitting] = useState(false);
	const [loaded, setLoaded] = useState(false);

	// start with the stored values, else with what crowdsec uses now, else the installer default
	useEffect(() => {
		if (!data || loaded) return;
		const applied = data.applied?.maxBodySize && data.applied?.action ? data.applied : null;
		if (data.configured) {
			setMb(String(data.maxBodySizeMb));
			setAction(data.action);
		} else if (applied && applied.maxBodySize % MIB === 0) {
			setMb(String(applied.maxBodySize / MIB));
			setAction(applied.action);
		} else {
			setMb(String(data.default.maxBodySizeMb));
			setAction(data.default.action);
		}
		setLoaded(true);
	}, [data, loaded]);

	const onSubmit = async (e) => {
		e.preventDefault();
		if (isSubmitting) return;
		setIsSubmitting(true);
		setErrorMsg(null);
		try {
			await updateCrowdsecAppsecBody({ maxBodySizeMb: Number.parseInt(mb, 10), action });
			showObjectSuccess("crowdsec.appsec-body", "saved");
		} catch (err) {
			setErrorMsg(err.message);
		} finally {
			setIsSubmitting(false);
		}
	};

	return (
		<form onSubmit={onSubmit} className="card-body border-top">
			<h3>
				<T id="crowdsec.appsec-body" />
			</h3>
			<p className="text-secondary">
				<T id="crowdsec.appsec-body.intro" />
			</p>
			{error && <Alert variant="danger">{error.message}</Alert>}
			{isPending ? (
				<Loading noLogo />
			) : (
				data && (
					<>
						<HelperHint helper={data.helper} />
						<Alert variant="danger" show={Boolean(errorMsg)} onClose={() => setErrorMsg(null)} dismissible>
							{errorMsg}
						</Alert>
						<div className="mb-3 d-flex flex-wrap gap-2 align-items-center">
							<span className={cn("badge", SYNC_BADGE[data.sync] ?? "bg-secondary-lt")}>
								<T id={`crowdsec.appsec-body.sync.${data.sync}`} />
							</span>
							{data.applied?.maxBodySize && (
								<span className="text-secondary small">
									<T
										id="crowdsec.appsec-body.applied"
										data={{
											mb: formatMb(data.applied.maxBodySize),
											action: data.applied.action ?? "?",
										}}
									/>
									{data.applied.reloadedAt && (
										<>
											{" "}
											<T
												id="crowdsec.appsec-body.reloaded"
												data={{ time: formatDateTime(data.applied.reloadedAt) }}
											/>
										</>
									)}
								</span>
							)}
						</div>
						{data.helper?.state === "active" && data.applied?.state === "error" && data.applied.message && (
							<Alert variant="danger">
								<T id="crowdsec.helper.error" />: {data.applied.message}
							</Alert>
						)}
						{data.helper?.state === "active" && data.applied && !data.applied.referenced && (
							<Alert variant="warning">
								<T id="crowdsec.appsec-body.not-referenced" />
							</Alert>
						)}
						<div className="row">
							<div className="col-md-4 mb-3">
								<label className="form-label" htmlFor="crowdsecAppsecBodyMb">
									<T id="crowdsec.appsec-body.limit" />
								</label>
								<input
									id="crowdsecAppsecBodyMb"
									type="number"
									className="form-control"
									required
									min={1}
									max={1024}
									step={1}
									value={mb}
									onChange={(e) => setMb(e.target.value)}
								/>
							</div>
							<div className="col-md-8 mb-3">
								<label className="form-label" htmlFor="crowdsecAppsecBodyAction">
									<T id="crowdsec.appsec-body.action" />
								</label>
								<select
									id="crowdsecAppsecBodyAction"
									className="form-select"
									value={action}
									onChange={(e) => setAction(e.target.value)}
								>
									{ACTIONS.map((a) => (
										<option key={a} value={a}>
											{a}
										</option>
									))}
								</select>
								<div className="form-hint">
									<T id={`crowdsec.appsec-body.action.${action}`} />
								</div>
							</div>
						</div>
						<p className="text-secondary small">
							<T id="crowdsec.appsec-body.scope" />
						</p>
						<div className="btn-list justify-content-end">
							<Button
								type="submit"
								color="teal"
								className="ms-auto"
								isLoading={isSubmitting}
								disabled={isSubmitting}
							>
								<T id="crowdsec.appsec-body.save" />
							</Button>
						</div>
					</>
				)
			)}
		</form>
	);
}
