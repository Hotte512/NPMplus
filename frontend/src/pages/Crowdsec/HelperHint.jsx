import Alert from "react-bootstrap/Alert";
import { formatDateTime, T } from "src/locale";

const UPDATE =
	'MODE=update bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/install.sh)"';

/**
 * Shown while the crowdsec-helper container does not report: what it does and how to set it up
 */
export default function HelperHint({ helper }) {
	if (!helper || helper.state === "active") return null;
	return (
		<Alert variant="warning">
			<div>
				<T
					id={`crowdsec.helper.hint.${helper.state}`}
					data={{ time: helper.heartbeat ? formatDateTime(helper.heartbeat) : "" }}
				/>{" "}
				<T id="crowdsec.helper.hint.saved" />
			</div>
			<div className="mt-2">
				<T id="crowdsec.helper.hint.install" />
			</div>
			<pre className="p-2 mt-1 mb-1 text-wrap">{UPDATE}</pre>
			<div className="mt-2">
				<T id="crowdsec.helper.hint.logs" />
			</div>
			<pre className="p-2 mt-1 mb-0">docker logs crowdsec-helper</pre>
		</Alert>
	);
}
