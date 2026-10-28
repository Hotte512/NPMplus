import cn from "clsx";
import { Field, Form, Formik } from "formik";
import { useState } from "react";
import { Alert } from "react-bootstrap";
import { updateCrowdsecConfig } from "src/api/backend";
import { Button, Loading } from "src/components";
import { useCrowdsecConfig } from "src/hooks";
import { intl, T } from "src/locale";
import { showObjectSuccess } from "src/notifications";

const SECRETS = ["apiKey", "secretKey", "password"];

const textField = (name, { placeholder, help, ...props } = {}) => (
	<Field name={name}>
		{({ field }) => (
			<div className="mb-3">
				<label className="form-label" htmlFor={`crowdsec-${name}`}>
					<T id={`crowdsec.config.${name}`} />
				</label>
				<input
					id={`crowdsec-${name}`}
					type="text"
					autoComplete="off"
					className="form-control"
					placeholder={placeholder}
					{...props}
					{...field}
				/>
				{help && (
					<div className="form-hint">
						<T id={help} />
					</div>
				)}
			</div>
		)}
	</Field>
);

const selectField = (name, options, help) => (
	<Field name={name}>
		{({ field }) => (
			<div className="mb-3">
				<label className="form-label" htmlFor={`crowdsec-${name}`}>
					<T id={`crowdsec.config.${name}`} />
				</label>
				<select id={`crowdsec-${name}`} className="form-select" {...field}>
					{options.map((o) => (
						<option key={o} value={o}>
							{o || "—"}
						</option>
					))}
				</select>
				{help && (
					<div className="form-hint">
						<T id={help} />
					</div>
				)}
			</div>
		)}
	</Field>
);

const switchField = (name, help) => (
	<Field name={name} type="checkbox">
		{({ field }) => (
			<label className="row cursor-pointer mb-3" htmlFor={`crowdsec-${name}`}>
				<span className="col">
					<T id={`crowdsec.config.${name}`} />
					{help && (
						<div className="text-secondary small">
							<T id={help} />
						</div>
					)}
				</span>
				<span className="col-auto">
					<span className="form-check form-check-single form-switch">
						<input
							{...field}
							id={`crowdsec-${name}`}
							type="checkbox"
							className={cn("form-check-input", { "bg-lime": field.checked })}
						/>
					</span>
				</span>
			</label>
		)}
	</Field>
);

const storedPlaceholder = (isSet) => (isSet ? intl.formatMessage({ id: "crowdsec.config.secret-set" }) : "");

export default function Config() {
	const { data, isPending, error } = useCrowdsecConfig();
	const [errorMsg, setErrorMsg] = useState(null);

	const onSubmit = async (values, { setSubmitting, setFieldValue }) => {
		setErrorMsg(null);
		const payload = { ...values };
		// empty secrets keep the stored ones
		for (const key of SECRETS) {
			if (!payload[key]) delete payload[key];
		}
		try {
			await updateCrowdsecConfig(payload);
			for (const key of SECRETS) setFieldValue(key, "");
			showObjectSuccess("crowdsec", "saved");
		} catch (err) {
			setErrorMsg(err.message);
		} finally {
			setSubmitting(false);
		}
	};

	if (error) {
		return (
			<div className="card-body">
				<Alert variant="danger">{error.message}</Alert>
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
				enabled: data.enabled,
				apiUrl: data.apiUrl,
				apiKey: "",
				mode: data.mode || "live",
				updateFrequency: data.updateFrequency,
				bouncingOnType: data.bouncingOnType || "all",
				fallbackRemediation: data.fallbackRemediation || "ban",
				retCode: data.retCode,
				redirectLocation: data.redirectLocation,
				excludeLocation: data.excludeLocation,
				captchaProvider: data.captchaProvider,
				siteKey: data.siteKey,
				secretKey: "",
				captchaExpiration: data.captchaExpiration,
				appsecUrl: data.appsecUrl,
				appsecFailureAction: data.appsecFailureAction || "deny",
				alwaysSendToAppsec: data.alwaysSendToAppsec,
				sslVerify: data.sslVerify,
				machineId: data.machineId,
				password: "",
			}}
			onSubmit={onSubmit}
		>
			{({ isSubmitting, values }) => (
				<Form>
					<div className="card-body">
						<Alert variant="danger" show={Boolean(errorMsg)} onClose={() => setErrorMsg(null)} dismissible>
							{errorMsg}
						</Alert>
						<p className="text-secondary">
							<T id="crowdsec.config.description" />
						</p>
						{data.useTlsAuth && (
							<Alert variant="info">
								<T id="crowdsec.config.tls-auth" />
							</Alert>
						)}

						<h3>
							<T id="crowdsec.config.bouncer" />
						</h3>
						{switchField("enabled", "crowdsec.config.enabled.help")}
						{textField("apiUrl", { placeholder: "http://127.0.0.1:8080", required: values.enabled })}
						{textField("apiKey", {
							placeholder: storedPlaceholder(data.apiKeySet),
							help: "crowdsec.config.apiKey.help",
							type: "password",
							autoComplete: "new-password",
						})}
						<div className="row">
							<div className="col-md-6">
								{selectField("mode", ["live", "stream"], "crowdsec.config.mode.help")}
							</div>
							<div className="col-md-6">
								{textField("updateFrequency", {
									placeholder: "10",
									inputMode: "numeric",
									pattern: "[0-9]*",
								})}
							</div>
						</div>
						<div className="row">
							<div className="col-md-6">{selectField("bouncingOnType", ["all", "ban", "captcha"])}</div>
							<div className="col-md-6">{selectField("fallbackRemediation", ["ban", "captcha"])}</div>
						</div>
						<div className="row">
							<div className="col-md-6">
								{textField("retCode", { placeholder: "403", pattern: "[1-5][0-9]{2}" })}
							</div>
							<div className="col-md-6">{textField("redirectLocation")}</div>
						</div>
						{textField("excludeLocation", { help: "crowdsec.config.excludeLocation.help" })}
						{switchField("sslVerify")}

						<h3 className="mt-4">
							<T id="crowdsec.config.captcha" />
						</h3>
						<div className="row">
							<div className="col-md-6">
								{selectField("captchaProvider", ["", "recaptcha", "hcaptcha", "turnstile"])}
							</div>
							<div className="col-md-6">
								{textField("captchaExpiration", { placeholder: "3600", pattern: "[0-9]*" })}
							</div>
						</div>
						<div className="row">
							<div className="col-md-6">{textField("siteKey")}</div>
							<div className="col-md-6">
								{textField("secretKey", {
									placeholder: storedPlaceholder(data.secretKeySet),
									type: "password",
									autoComplete: "new-password",
								})}
							</div>
						</div>

						<h3 className="mt-4">
							<T id="crowdsec.config.appsec" />
						</h3>
						{textField("appsecUrl", {
							placeholder: "http://127.0.0.1:7422",
							help: "crowdsec.config.appsecUrl.help",
						})}
						{selectField("appsecFailureAction", ["deny", "passthrough"])}
						{switchField("alwaysSendToAppsec")}

						<h3 className="mt-4">
							<T id="crowdsec.config.machine" />
						</h3>
						<p className="text-secondary">
							<T id="crowdsec.config.machine.help" />
						</p>
						<div className="row">
							<div className="col-md-6">{textField("machineId", { placeholder: "npmplus-gui" })}</div>
							<div className="col-md-6">
								{textField("password", {
									placeholder: storedPlaceholder(data.passwordSet),
									type: "password",
									autoComplete: "new-password",
								})}
							</div>
						</div>
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
