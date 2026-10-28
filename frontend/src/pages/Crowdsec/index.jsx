import { HasPermission } from "src/components";
import { ADMIN, VIEW } from "src/modules/Permissions";
import Crowdsec from "./Crowdsec";

const CrowdsecPage = () => (
	<HasPermission section={ADMIN} permission={VIEW} pageLoading loadingNoLogo>
		<Crowdsec />
	</HasPermission>
);

export default CrowdsecPage;
