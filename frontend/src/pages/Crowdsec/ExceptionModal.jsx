import { useState } from "react";
import { Alert } from "react-bootstrap";
import Modal from "react-bootstrap/Modal";
import Select from "react-select";
import { createCrowdsecException, updateCrowdsecException } from "src/api/backend";
import { Button } from "src/components";
import { useProxyHosts } from "src/hooks";
import { intl, T } from "src/locale";
import EasyModal from "src/modules/easyModal";
import { selectClassNames } from "src/modules/Select";
import { showObjectSuccess } from "src/notifications";

const hostLabel = (host) => {
	const names = host.domainNames ?? [];
	const label = names[0] ?? `#${host.id}`;
	return names.length > 1 ? `${label} (+${names.length - 1})` : label;
};

const showExceptionModal = (props) => {
	EasyModal.show(ExceptionModal, props);
};

const ExceptionModal = EasyModal.create(({ exception, value: initialValue, visible, remove }) => {
	const { data: hosts } = useProxyHosts();
	const [value, setValue] = useState(exception?.value ?? initialValue ?? "");
	const [description, setDescription] = useState(exception?.description ?? "");
	const [scope, setScope] = useState(exception?.scope ?? "global");
	const [hostIds, setHostIds] = useState(exception?.proxyHostIds ?? []);
	const [errorMsg, setErrorMsg] = useState(null);
	const [isSubmitting, setIsSubmitting] = useState(false);

	const options = (hosts ?? [])
		.map((h) => ({ value: h.id, label: hostLabel(h) }))
		.sort((a, b) => a.label.localeCompare(b.label));

	const onSubmit = async (e) => {
		e.preventDefault();
		if (isSubmitting) return;
		if (scope === "hosts" && hostIds.length === 0) {
			setErrorMsg(intl.formatMessage({ id: "crowdsec.exception.hosts-required" }));
			return;
		}
		setIsSubmitting(true);
		setErrorMsg(null);
		const payload = {
			value: value.trim(),
			description: description.trim(),
			scope,
			proxyHostIds: scope === "hosts" ? hostIds : [],
		};
		try {
			if (exception?.id) await updateCrowdsecException(exception.id, payload);
			else await createCrowdsecException(payload);
			showObjectSuccess("crowdsec.exception", "saved");
			remove();
		} catch (err) {
			setErrorMsg(err.message);
		} finally {
			setIsSubmitting(false);
		}
	};

	return (
		<Modal show={visible} backdrop="static" onHide={isSubmitting ? undefined : remove}>
			<form onSubmit={onSubmit}>
				<Modal.Header closeButton={!isSubmitting}>
					<Modal.Title>
						<T id={exception?.id ? "crowdsec.exception.edit" : "crowdsec.exception.add"} />
					</Modal.Title>
				</Modal.Header>
				<Modal.Body>
					<Alert variant="danger" show={Boolean(errorMsg)} onClose={() => setErrorMsg(null)} dismissible>
						{errorMsg}
					</Alert>
					<div className="mb-3">
						<label className="form-label" htmlFor="crowdsecExceptionValue">
							<T id="crowdsec.exception.value" />
						</label>
						<input
							id="crowdsecExceptionValue"
							className="form-control"
							required
							autoComplete="off"
							maxLength={64}
							pattern="[0-9a-fA-F:.]+(/[0-9]{1,3})?"
							placeholder="192.0.2.10 / 192.0.2.0/24 / 2001:db8::/48"
							value={value}
							onChange={(e) => setValue(e.target.value)}
						/>
						<div className="form-hint">
							<T id="crowdsec.exception.value.help" />
						</div>
					</div>
					<div className="mb-3">
						<label className="form-label" htmlFor="crowdsecExceptionDescription">
							<T id="crowdsec.exception.description" />
						</label>
						<input
							id="crowdsecExceptionDescription"
							className="form-control"
							autoComplete="off"
							maxLength={255}
							placeholder={intl.formatMessage({ id: "crowdsec.exception.description.placeholder" })}
							value={description}
							onChange={(e) => setDescription(e.target.value)}
						/>
					</div>
					<div className="mb-3">
						<div className="form-label">
							<T id="crowdsec.exception.scope" />
						</div>
						{["global", "hosts"].map((s) => (
							<label key={s} className="form-check" htmlFor={`crowdsecExceptionScope-${s}`}>
								<input
									id={`crowdsecExceptionScope-${s}`}
									className="form-check-input"
									type="radio"
									name="scope"
									value={s}
									checked={scope === s}
									onChange={() => setScope(s)}
								/>
								<span className="form-check-label">
									<T id={`crowdsec.exception.scope.${s}`} />
								</span>
							</label>
						))}
					</div>
					{scope === "hosts" && (
						<div className="mb-3">
							<label className="form-label" htmlFor="crowdsecExceptionHosts">
								<T id="crowdsec.exception.hosts" />
							</label>
							<Select
								unstyled
								classNames={selectClassNames}
								inputId="crowdsecExceptionHosts"
								isMulti
								closeMenuOnSelect={false}
								options={options}
								value={options.filter((o) => hostIds.includes(o.value))}
								onChange={(v) => setHostIds((v ?? []).map((o) => o.value))}
								placeholder={intl.formatMessage({ id: "crowdsec.exception.hosts.placeholder" })}
								noOptionsMessage={() => intl.formatMessage({ id: "crowdsec.exception.hosts.none" })}
							/>
						</div>
					)}
					<p className="text-secondary small mb-0">
						<T id="crowdsec.exception.effect" />
					</p>
				</Modal.Body>
				<Modal.Footer>
					<Button onClick={remove} disabled={isSubmitting}>
						<T id="cancel" />
					</Button>
					<Button
						type="submit"
						className="ms-auto"
						color="teal"
						isLoading={isSubmitting}
						disabled={isSubmitting}
					>
						<T id="save" />
					</Button>
				</Modal.Footer>
			</form>
		</Modal>
	);
});

export { showExceptionModal };
