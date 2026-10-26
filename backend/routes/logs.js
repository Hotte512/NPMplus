import express from "express";
import internalLogs from "../internal/logs.js";
import jwtdecode from "../lib/express/jwt-decode.js";
import validator from "../lib/validator/index.js";

const commonProperties = {
	source: {
		type: "string",
		enum: internalLogs.sources(),
	},
	host_id: {
		$ref: "common#/properties/id",
	},
	filter: {
		type: "string",
		maxLength: 255,
	},
};

const tailSchema = {
	type: "object",
	required: ["source"],
	additionalProperties: false,
	properties: {
		...commonProperties,
		lines: {
			type: "integer",
			minimum: 1,
			maximum: internalLogs.MAX_LINES,
		},
	},
};

const sinceSchema = {
	type: "object",
	required: ["source", "cursor"],
	additionalProperties: false,
	properties: {
		...commonProperties,
		cursor: {
			type: "string",
			pattern: "^[0-9]{1,40}(:[0-9]{1,20})?$",
		},
	},
};

const router = express.Router({
	caseSensitive: true,
	strict: true,
	mergeParams: true,
});

/**
 * GET /api/logs/access?lines=500&host_id=1&filter=foo
 *
 * Retrieve the last lines of a log
 */
router
	.route("/:source")
	.all(jwtdecode())
	.get(async (req, res) => {
		res.locals.access.canAdmin();
		const data = validator(tailSchema, {
			source: req.params.source,
			lines: req.query.lines ?? 500,
			host_id: req.query.host_id || undefined,
			filter: req.query.filter || undefined,
		});
		const result = await internalLogs.tail(res.locals.access, data.source, data);
		res.status(200).send(result);
	});

/**
 * GET /api/logs/access/since?cursor=123:456&host_id=1&filter=foo
 *
 * Retrieve the lines appended to a log after the cursor
 */
router
	.route("/:source/since")
	.all(jwtdecode())
	.get(async (req, res) => {
		res.locals.access.canAdmin();
		const data = validator(sinceSchema, {
			source: req.params.source,
			cursor: req.query.cursor,
			host_id: req.query.host_id || undefined,
			filter: req.query.filter || undefined,
		});
		const result = await internalLogs.since(res.locals.access, data.source, data.cursor, data);
		res.status(200).send(result);
	});

export default router;
