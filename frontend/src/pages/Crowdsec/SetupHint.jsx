import Alert from "react-bootstrap/Alert";
import { T } from "src/locale";

const STEPS = [
	"docker exec crowdsec cscli bouncers add npmplus",
	"docker exec crowdsec cscli machines add npmplus-gui --auto -f -",
];

export default function SetupHint({ status, onShowConfig }) {
	const error = status?.lapi?.error || status?.bouncer?.error;
	return (
		<div className="card-body">
			<Alert variant="warning">
				<T id="crowdsec.not-connected" />
				{error && <div className="small mt-1 text-break">{error}</div>}
			</Alert>
			<p>
				<T id="crowdsec.setup.intro" />
			</p>
			<ol>
				<li>
					<T id="crowdsec.setup.container" />
				</li>
				<li>
					<T id="crowdsec.setup.bouncer" />
					<pre className="p-2 mt-1 mb-2">{STEPS[0]}</pre>
				</li>
				<li>
					<T id="crowdsec.setup.machine" />
					<pre className="p-2 mt-1 mb-2">{STEPS[1]}</pre>
				</li>
				<li>
					<T id="crowdsec.setup.config" />
				</li>
			</ol>
			<button type="button" className="btn btn-primary" onClick={onShowConfig}>
				<T id="crowdsec.tab.config" />
			</button>
		</div>
	);
}
