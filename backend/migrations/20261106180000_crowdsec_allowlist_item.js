import { migrate as logger } from "../logger.js";

const migrateName = "crowdsec_allowlist_item";

/**
 * Migrate
 *
 * Entries of the CrowdSec allowlist "npmplus", applied by the crowdsec-helper container (cscli allowlists)
 *
 * @see https://knexjs.org/guide/migrations.html#migration-api
 *
 * @param   {Object} knex
 * @returns {Promise}
 */
const up = async (knex) => {
	logger.info(`[${migrateName}] Migrating Up...`);

	if (await knex.schema.hasTable("npmplus_crowdsec_allowlist_item")) {
		logger.info(`[${migrateName}] npmplus_crowdsec_allowlist_item Table already exists, skipping`);
		return;
	}
	await knex.schema.createTable("npmplus_crowdsec_allowlist_item", (table) => {
		table.increments().primary();
		table.string("value", 64).notNull().unique();
		table.string("description", 255).notNull().defaultTo("");
		// ISO 8601 (UTC), empty = never
		table.string("expires_at", 32).notNull().defaultTo("");
		table.string("created_on", 32).notNull().defaultTo("");
	});
	logger.info(`[${migrateName}] npmplus_crowdsec_allowlist_item Table created`);
};

/**
 * Undo Migrate
 *
 * @param   {Object} _knex
 * @returns {Promise}
 */
const down = (_knex) => {
	throw new Error(`[${migrateName}] You can't migrate down this one.`);
};

export { down, up };
