import { useState } from "react";
import { Alert } from "react-bootstrap";
import Modal from "react-bootstrap/Modal";
import { createCrowdsecNpmplusAllowlistItem } from "src/api/backend";
import { Button } from "src/components";
import { intl, T } from "src/locale";
import EasyModal from "src/modules/easyModal";
import { showObjectSuccess } from "src/notifications";

// hours, "" = never
const EXPIRY = ["", "1h", "24h", "168h", "720h", "8760h"];

const showAllowlistItemModal = (props) => {
	EasyModal.show(AllowlistItemModal, props);
};

const AllowlistItemModal = EasyModal.create(({ value: initialValue, visible, remove }) => {
	const [value, setValue] = useState(initialValue ?? "");
	const [description, setDescription] = useState("");
	const [expiry, setExpiry] = useState("");
	const [errorMsg, setErrorMsg] = useState(null);
	const [isSubmitting, setIsSubmitting] = useState(false);

	const onSubmit = async (e) => {
		e.preventDefault();
		if (isSubmitting) return;
		setIsSubmitting(true);
		setErrorMsg(null);
		const hours = Number.parseInt(expiry, 10);
		try {
			await createCrowdsecNpmplusAllowlistItem({
				value: value.trim(),
				description: description.trim(),
				expiresAt: hours ? new Date(Date.now() + hours * 3600 * 1000).toISOString() : null,
			});
			showObjectSuccess("crowdsec.npmplus-allowlist.item", "saved");
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
						<T id="crowdsec.npmplus-allowlist.add" />
					</Modal.Title>
				</Modal.Header>
				<Modal.Body>
					<Alert variant="danger" show={Boolean(errorMsg)} onClose={() => setErrorMsg(null)} dismissible>
						{errorMsg}
					</Alert>
					<div className="mb-3">
						<label className="form-label" htmlFor="crowdsecAllowlistValue">
							<T id="crowdsec.allowlist.value" />
						</label>
						<input
							id="crowdsecAllowlistValue"
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
						<label className="form-label" htmlFor="crowdsecAllowlistDescription">
							<T id="crowdsec.allowlist.description" />
						</label>
						<input
							id="crowdsecAllowlistDescription"
							className="form-control"
							autoComplete="off"
							maxLength={255}
							placeholder={intl.formatMessage({ id: "crowdsec.exception.description.placeholder" })}
							value={description}
							onChange={(e) => setDescription(e.target.value)}
						/>
					</div>
					<div className="mb-3">
						<label className="form-label" htmlFor="crowdsecAllowlistExpiry">
							<T id="crowdsec.npmplus-allowlist.expiry" />
						</label>
						<select
							id="crowdsecAllowlistExpiry"
							className="form-select"
							value={expiry}
							onChange={(e) => setExpiry(e.target.value)}
						>
							{EXPIRY.map((d) => (
								<option key={d} value={d}>
									{intl.formatMessage({
										id: d ? `crowdsec.duration.${d}` : "crowdsec.npmplus-allowlist.expiry.never",
									})}
								</option>
							))}
						</select>
					</div>
					<p className="text-secondary small mb-0">
						<T id="crowdsec.npmplus-allowlist.effect" />
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

export { showAllowlistItemModal };
