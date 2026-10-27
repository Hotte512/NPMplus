import express from "express";
import internalUnifiDns from "../internal/unifi-dns.js";
import jwtdecode from "../lib/express/jwt-decode.js";

const router = express.Router({
	caseSensitive: true,
	strict: true,
	mergeParams: true,
});

/**
 * GET /api/unifi-dns/status
 *
 * Own local dns records and the last sync result of the visible proxy hosts
 */
router
	.route("/status")
	.all(jwtdecode())
	.get(async (_, res) => {
		res.status(200).send(await internalUnifiDns.getStatus(res.locals.access));
	});

/**
 * POST /api/unifi-dns/sync
 *
 * Sync the records of all proxy hosts now
 */
router
	.route("/sync")
	.all(jwtdecode())
	.post(async (_, res) => {
		res.locals.access.canAdmin();
		const errors = await internalUnifiDns.syncAll();
		res.status(200).send({ errors });
	});

export default router;
