import { useQueryClient } from "@tanstack/react-query";
import cn from "clsx";
import { Field, Form, Formik } from "formik";
import { useState } from "react";
import { Alert } from "react-bootstrap";
import { Button, Loading } from "src/components";
import { useSetSetting, useSetting, useUnifiDnsStatus } from "src/hooks";
import { intl, T } from "src/locale";
import { showObjectSuccess } from "src/notifications";
import UnifiDnsStatus from "./UnifiDnsStatus";

const textField = (name, placeholder, help, props = {}) => (
	<Field name={name}>
		{({ field }) => (
			<div className="mb-3">
				<label className="form-label" htmlFor={name}>
					<T id={`settings.unifi-dns.${name}`} />
				</label>
				<input
					id={name}
					type="text"
					autoComplete="off"
					className="form-control"
					placeholder={placeholder}
					{...props}
					{...field}
				/>
				{help ? (
					<div className="form-hint">
						<T id={help} />
					</div>
				) : null}
			</div>
		)}
	</Field>
);

export default function UnifiDns() {
	const { data, isPending, error } = useSetting("unifi-dns");
	const { mutate: setSetting } = useSetSetting();
	const { data: status } = useUnifiDnsStatus();
	const queryClient = useQueryClient();
	const [errorMsg, setErrorMsg] = useState(null);
	const [isSubmitting, setIsSubmitting] = useState(false);

	const onSubmit = (values, { setSubmitting, setFieldValue }) => {
		if (isSubmitting) return;
		setIsSubmitting(true);
		setErrorMsg(null);

		setSetting(
			{
				id: "unifi-dns",
				value: values.enabled ? "enabled" : "disabled",
				meta: {
					url: values.url.trim(),
					// empty keeps the stored key
					apiKey: values.apiKey,
					siteId: values.siteId.trim(),
					defaultTarget: values.defaultTarget.trim(),
					verifyTls: values.verifyTls,
					tlsFingerprint: values.tlsFingerprint.trim(),
					ttl: Number.parseInt(values.ttl, 10) || 0,
				},
			},
			{
				onError: (err) => setErrorMsg(err.message),
				onSuccess: () => {
					setFieldValue("apiKey", "");
					showObjectSuccess("setting", "saved");
				},
				onSettled: () => {
					// saving syncs all hosts
					void queryClient.invalidateQueries({ queryKey: ["unifi-dns-status"] });
					setIsSubmitting(false);
					setSubmitting(false);
				},
			},
		);
	};

	if (error) {
		return (
			<div className="card-body">
				<Alert variant="danger" show>
					{error.message}
				</Alert>
			</div>
		);
	}

	if (isPending) {
		return (
			<div className="card-body">
				<Loading noLogo />
			</div>
		);
	}

	return (
		<Formik
			initialValues={{
				enabled: data?.value === "enabled",
				url: data?.meta?.url ?? "",
				apiKey: "",
				siteId: data?.meta?.siteId ?? "",
				defaultTarget: data?.meta?.defaultTarget ?? "",
				verifyTls: data?.meta?.verifyTls ?? false,
				tlsFingerprint: data?.meta?.tlsFingerprint ?? "",
				ttl: data?.meta?.ttl || "",
			}}
			onSubmit={onSubmit}
		>
			{({ values, setFieldValue }) => (
				<Form>
					<div className="card-body">
						<Alert variant="danger" show={Boolean(errorMsg)} onClose={() => setErrorMsg(null)} dismissible>
							{errorMsg}
						</Alert>
						<p className="text-secondary">
							<T id="settings.unifi-dns.description" />
						</p>
						<Field name="enabled" type="checkbox">
							{({ field }) => (
								<label className="row cursor-pointer mb-3" htmlFor="enabled">
									<span className="col">
										<T id="settings.unifi-dns.enabled" />
									</span>
									<span className="col-auto">
										<span className="form-check form-check-single form-switch">
											<input
												{...field}
												id="enabled"
												type="checkbox"
												className={cn("form-check-input", { "bg-lime": field.checked })}
											/>
										</span>
									</span>
								</label>
							)}
						</Field>
						{textField("url", "https://192.168.1.1", null, { pattern: "https?://\\S+" })}
						{textField(
							"apiKey",
							data?.meta?.apiKeySet ? intl.formatMessage({ id: "settings.unifi-dns.apiKey.set" }) : "",
							"settings.unifi-dns.apiKey.help",
							{ type: "password", autoComplete: "new-password" },
						)}
						{textField("siteId", "default", "settings.unifi-dns.siteId.help")}
						{textField("defaultTarget", "192.168.1.5", "settings.unifi-dns.defaultTarget.help")}
						{textField(
							"ttl",
							intl.formatMessage({ id: "settings.unifi-dns.ttl.auto" }),
							"settings.unifi-dns.ttl.help",
							{
								type: "number",
								min: 0,
								max: 86400,
							},
						)}
						<Field name="verifyTls" type="checkbox">
							{({ field }) => (
								<label className="row cursor-pointer mb-3" htmlFor="verifyTls">
									<span className="col">
										<T id="settings.unifi-dns.verifyTls" />
									</span>
									<span className="col-auto">
										<span className="form-check form-check-single form-switch">
											<input
												{...field}
												id="verifyTls"
												type="checkbox"
												className={cn("form-check-input", { "bg-lime": field.checked })}
											/>
										</span>
									</span>
								</label>
							)}
						</Field>
						{values.verifyTls
							? null
							: textField("tlsFingerprint", "AB:CD:…", "settings.unifi-dns.tlsFingerprint.help", {
									pattern: "[0-9a-fA-F:\\s]*",
								})}
						{!values.verifyTls && !values.tlsFingerprint.trim() ? (
							<Alert variant="warning" show>
								<T id="settings.unifi-dns.tlsFingerprint.warning" />
								{status?.tlsFingerprintSeen ? (
									<div className="mt-2">
										<code className="text-break">{status.tlsFingerprintSeen}</code>{" "}
										<Button
											size="sm"
											onClick={() => setFieldValue("tlsFingerprint", status.tlsFingerprintSeen)}
										>
											<T id="settings.unifi-dns.tlsFingerprint.use" />
										</Button>
									</div>
								) : null}
							</Alert>
						) : null}
						<UnifiDnsStatus gatewayUrl={data?.meta?.url ?? ""} />
					</div>
					<div className="card-footer bg-transparent mt-auto">
						<div className="btn-list justify-content-end">
							<Button
								type="submit"
								color="teal"
								className="ms-auto"
								isLoading={isSubmitting}
								disabled={isSubmitting}
							>
								<T id="save" />
							</Button>
						</div>
					</div>
				</Form>
			)}
		</Formik>
	);
}
