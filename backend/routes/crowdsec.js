import express from "express";
import internalCrowdsec from "../internal/crowdsec.js";
import internalCrowdsecExceptions from "../internal/crowdsec-exceptions.js";
import internalCrowdsecHelper from "../internal/crowdsec-helper.js";
import jwtdecode from "../lib/express/jwt-decode.js";
import validate from "../lib/express/validate.js";

const router = express.Router({
	caseSensitive: true,
	strict: true,
	mergeParams: true,
});

/**
 * GET /api/crowdsec/status
 *
 * Whether the bouncer is enabled and the local api, bouncer key and machine login work
 */
router.route("/status").get(jwtdecode(), validate, async (_, res) => {
	res.status(200).send(await internalCrowdsec.getStatus(res.locals.access));
});

/**
 * GET|PUT /api/crowdsec/config
 *
 * The bouncer config (/data/crowdsec/crowdsec.conf) and the machine login, secrets are write only
 */
router
	.route("/config")
	.get(jwtdecode(), validate, async (_, res) => {
		res.status(200).send(await internalCrowdsec.getConfig(res.locals.access));
	})
	.put(jwtdecode(), validate, async (_, res) => {
		res.locals.access.canAdmin();
		res.status(200).send(await internalCrowdsec.setConfig(res.locals.access, res.locals.body));
	});

/**
 * GET    /api/crowdsec/decisions          active decisions, without the community blocklist
 * POST   /api/crowdsec/decisions          ban an ip or range
 * DELETE /api/crowdsec/decisions?ip=1.2.3.4  remove all decisions of an ip
 */
router
	.route("/decisions")
	.get(jwtdecode(), validate, async (_, res) => {
		res.status(200).send(await internalCrowdsec.getDecisions(res.locals.access));
	})
	.post(jwtdecode(), validate, async (_, res) => {
		res.locals.access.canAdmin();
		res.status(201).send(await internalCrowdsec.addDecision(res.locals.access, res.locals.body));
	})
	.delete(jwtdecode(), validate, async (_, res) => {
		res.locals.access.canAdmin();
		res.status(200).send({
			deleted: await internalCrowdsec.deleteDecisions(res.locals.access, { ip: res.locals.query.ip }),
		});
	});

/**
 * DELETE /api/crowdsec/decisions/123
 */
router.route("/decisions/:decision_id").delete(jwtdecode(), validate, async (_, res) => {
	res.locals.access.canAdmin();
	res.status(200).send({
		deleted: await internalCrowdsec.deleteDecisions(res.locals.access, {
			id: Number(res.locals.params.decision_id),
		}),
	});
});

/**
 * GET /api/crowdsec/alerts?ip=1.2.3.4&scenario=http-probing&limit=100
 */
router.route("/alerts").get(jwtdecode(), validate, async (_, res) => {
	res.locals.access.canAdmin();
	const { ip, scenario, limit } = res.locals.query;
	res.status(200).send(
		await internalCrowdsec.getAlerts(res.locals.access, {
			ip: ip || undefined,
			scenario: scenario || undefined,
			limit: limit ?? 100,
		}),
	);
});

/**
 * GET /api/crowdsec/allowlists  allowlists of the local api with their entries (read only)
 */
router.route("/allowlists").get(jwtdecode(), validate, async (_, res) => {
	res.locals.access.canAdmin();
	res.status(200).send(await internalCrowdsec.getAllowlists(res.locals.access));
});

/**
 * GET /api/crowdsec/allowlists/check?value=192.0.2.1
 */
router.route("/allowlists/check").get(jwtdecode(), validate, async (_, res) => {
	res.locals.access.canAdmin();
	res.status(200).send(await internalCrowdsec.checkAllowlist(res.locals.access, res.locals.query.value));
});

/**
 * GET /api/crowdsec/helper  state of the crowdsec-helper container (status.json in the spool directory)
 */
router.route("/helper").get(jwtdecode(), validate, async (_, res) => {
	res.locals.access.canAdmin();
	res.status(200).send(await internalCrowdsecHelper.getHelper(res.locals.access));
});

/**
 * GET  /api/crowdsec/npmplus-allowlist  entries of the allowlist "npmplus" with their sync state
 * POST /api/crowdsec/npmplus-allowlist  add an entry, the helper applies it with cscli
 */
router
	.route("/npmplus-allowlist")
	.get(jwtdecode(), validate, async (req, res) => {
		res.locals.access.canAdmin();
		res.status(200).send(await internalCrowdsecHelper.getAllowlist(res.locals.access, req.ip));
	})
	.post(jwtdecode(), validate, async (_, res) => {
		res.locals.access.canAdmin();
		res.status(201).send(await internalCrowdsecHelper.createItem(res.locals.access, res.locals.body));
	});

/**
 * DELETE /api/crowdsec/npmplus-allowlist/123
 */
router.route("/npmplus-allowlist/:item_id").delete(jwtdecode(), validate, async (_, res) => {
	res.locals.access.canAdmin();
	res.status(200).send(await internalCrowdsecHelper.deleteItem(res.locals.access, Number(res.locals.params.item_id)));
});

/**
 * GET /api/crowdsec/appsec-body  AppSec request body limit (stored, applied by the helper)
 * PUT /api/crowdsec/appsec-body  set limit and action, applies to all hosts
 */
router
	.route("/appsec-body")
	.get(jwtdecode(), validate, async (_, res) => {
		res.locals.access.canAdmin();
		res.status(200).send(await internalCrowdsecHelper.getAppsec(res.locals.access));
	})
	.put(jwtdecode(), validate, async (_, res) => {
		res.locals.access.canAdmin();
		res.status(200).send(await internalCrowdsecHelper.setAppsec(res.locals.access, res.locals.body));
	});

/**
 * GET  /api/crowdsec/exceptions  client addresses the bouncer and appsec skip
 * POST /api/crowdsec/exceptions  add one, for all hosts or some proxy hosts
 */
router
	.route("/exceptions")
	.get(jwtdecode(), validate, async (_, res) => {
		res.locals.access.canAdmin();
		res.status(200).send(await internalCrowdsecExceptions.getAll(res.locals.access));
	})
	.post(jwtdecode(), validate, async (_, res) => {
		res.locals.access.canAdmin();
		res.status(201).send(await internalCrowdsecExceptions.create(res.locals.access, res.locals.body));
	});

/**
 * PUT|DELETE /api/crowdsec/exceptions/123
 */
router
	.route("/exceptions/:exception_id")
	.put(jwtdecode(), validate, async (_, res) => {
		res.locals.access.canAdmin();
		res.status(200).send(
			await internalCrowdsecExceptions.update(
				res.locals.access,
				Number(res.locals.params.exception_id),
				res.locals.body,
			),
		);
	})
	.delete(jwtdecode(), validate, async (_, res) => {
		res.locals.access.canAdmin();
		res.status(200).send(
			await internalCrowdsecExceptions.delete(res.locals.access, Number(res.locals.params.exception_id)),
		);
	});

/**
 * GET /api/crowdsec/client-ip
 *
 * The address nginx passes for this request (X-Forwarded-For is set to $remote_addr, see proxy-headers.conf)
 */
router.route("/client-ip").get(jwtdecode(), validate, async (req, res) => {
	res.locals.access.canAdmin();
	res.status(200).send(await internalCrowdsecExceptions.getClientIp(res.locals.access, req.ip));
});

export default router;
