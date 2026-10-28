import express from "express";
import internalCrowdsec from "../internal/crowdsec.js";
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

export default router;
