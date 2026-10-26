import express from "express";
import internalLogs from "../internal/logs.js";
import jwtdecode from "../lib/express/jwt-decode.js";
import validate from "../lib/express/validate.js";

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
router.route("/:source").get(jwtdecode(), validate, async (_, res) => {
	res.locals.access.canAdmin();
	const { lines, host_id, filter } = res.locals.query;
	const result = await internalLogs.tail(res.locals.access, res.locals.params.source, {
		lines: lines ?? 500,
		host_id: host_id || undefined,
		filter: filter || undefined,
	});
	res.status(200).send(result);
});

/**
 * GET /api/logs/access/since?cursor=123:456&host_id=1&filter=foo
 *
 * Retrieve the lines appended to a log after the cursor
 */
router.route("/:source/since").get(jwtdecode(), validate, async (_, res) => {
	res.locals.access.canAdmin();
	const { cursor, host_id, filter } = res.locals.query;
	const result = await internalLogs.since(res.locals.access, res.locals.params.source, cursor, {
		host_id: host_id || undefined,
		filter: filter || undefined,
	});
	res.status(200).send(result);
});

export default router;
