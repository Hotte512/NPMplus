import express from "express";
import internalCrowdsec from "../internal/crowdsec.js";
import jwtdecode from "../lib/express/jwt-decode.js";
import validator from "../lib/validator/index.js";

// biome-ignore lint/security/noSecrets: regex, no newlines in crowdsec.conf values
const SINGLE_LINE = "^[^\\r\\n]*$";
const IP_OR_RANGE = "^[0-9a-fA-F:.]+(/[0-9]{1,3})?$";

const line = { type: "string", maxLength: 1024, pattern: SINGLE_LINE };
const ipOrRange = { type: "string", minLength: 2, maxLength: 64, pattern: IP_OR_RANGE };

const configSchema = {
	type: "object",
	additionalProperties: false,
	minProperties: 1,
	properties: {
		enabled: { type: "boolean" },
		api_url: { ...line, pattern: "^(https?://[^\\s]+)?$" },
		api_key: line,
		mode: { type: "string", enum: ["live", "stream"] },
		update_frequency: { ...line, pattern: "^[0-9]{0,6}$" },
		bouncing_on_type: { type: "string", enum: ["all", "ban", "captcha"] },
		fallback_remediation: { type: "string", enum: ["ban", "captcha"] },
		ret_code: { ...line, pattern: "^([1-5][0-9]{2})?$" },
		redirect_location: line,
		exclude_location: line,
		captcha_provider: { type: "string", enum: ["", "recaptcha", "hcaptcha", "turnstile"] },
		site_key: line,
		secret_key: line,
		captcha_expiration: { ...line, pattern: "^[0-9]{0,9}$" },
		appsec_url: { ...line, pattern: "^(https?://[^\\s]+)?$" },
		appsec_failure_action: { type: "string", enum: ["deny", "passthrough"] },
		always_send_to_appsec: { type: "boolean" },
		ssl_verify: { type: "boolean" },
		machine_id: { type: "string", maxLength: 255, pattern: "^[A-Za-z0-9._@-]*$" },
		password: { type: "string", maxLength: 255 },
	},
};

const addDecisionSchema = {
	type: "object",
	required: ["value", "type", "duration"],
	additionalProperties: false,
	properties: {
		value: ipOrRange,
		type: { type: "string", enum: ["ban", "captcha"] },
		duration: { type: "string", pattern: "^[1-9][0-9]{0,5}[smh]$" },
		reason: { type: "string", maxLength: 255, pattern: SINGLE_LINE },
	},
};

const deleteDecisionsSchema = {
	type: "object",
	required: ["ip"],
	additionalProperties: false,
	properties: {
		ip: ipOrRange,
	},
};

const deleteDecisionSchema = {
	type: "object",
	required: ["id"],
	additionalProperties: false,
	properties: {
		id: { $ref: "common#/properties/id" },
	},
};

const alertsSchema = {
	type: "object",
	additionalProperties: false,
	properties: {
		ip: ipOrRange,
		scenario: { type: "string", maxLength: 255, pattern: SINGLE_LINE },
		limit: { type: "integer", minimum: 1, maximum: 1000 },
	},
};

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
router
	.route("/status")
	.all(jwtdecode())
	.get(async (_, res) => {
		res.status(200).send(await internalCrowdsec.getStatus(res.locals.access));
	});

/**
 * GET|PUT /api/crowdsec/config
 *
 * The bouncer config (/data/crowdsec/crowdsec.conf) and the machine login, secrets are write only
 */
router
	.route("/config")
	.all(jwtdecode())
	.get(async (_, res) => {
		res.status(200).send(await internalCrowdsec.getConfig(res.locals.access));
	})
	.put(async (req, res) => {
		res.locals.access.canAdmin();
		const data = validator(configSchema, req.body);
		res.status(200).send(await internalCrowdsec.setConfig(res.locals.access, data));
	});

/**
 * GET    /api/crowdsec/decisions          active decisions, without the community blocklist
 * POST   /api/crowdsec/decisions          ban an ip or range
 * DELETE /api/crowdsec/decisions?ip=1.2.3.4  remove all decisions of an ip
 */
router
	.route("/decisions")
	.all(jwtdecode())
	.get(async (_, res) => {
		res.status(200).send(await internalCrowdsec.getDecisions(res.locals.access));
	})
	.post(async (req, res) => {
		res.locals.access.canAdmin();
		const data = validator(addDecisionSchema, req.body);
		res.status(201).send(await internalCrowdsec.addDecision(res.locals.access, data));
	})
	.delete(async (req, res) => {
		res.locals.access.canAdmin();
		const data = validator(deleteDecisionsSchema, { ip: req.query.ip });
		res.status(200).send({ deleted: await internalCrowdsec.deleteDecisions(res.locals.access, data) });
	});

/**
 * DELETE /api/crowdsec/decisions/123
 */
router
	.route("/decisions/:decision_id")
	.all(jwtdecode())
	.delete(async (req, res) => {
		res.locals.access.canAdmin();
		const data = validator(deleteDecisionSchema, { id: req.params.decision_id });
		res.status(200).send({ deleted: await internalCrowdsec.deleteDecisions(res.locals.access, data) });
	});

/**
 * GET /api/crowdsec/alerts?ip=1.2.3.4&scenario=http-probing&limit=100
 */
router
	.route("/alerts")
	.all(jwtdecode())
	.get(async (req, res) => {
		res.locals.access.canAdmin();
		const data = validator(alertsSchema, {
			ip: req.query.ip || undefined,
			scenario: req.query.scenario || undefined,
			limit: req.query.limit ?? 100,
		});
		res.status(200).send(await internalCrowdsec.getAlerts(res.locals.access, data));
	});

export default router;
