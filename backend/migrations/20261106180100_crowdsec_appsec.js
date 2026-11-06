import { migrate as logger } from "../logger.js";

const migrateName = "crowdsec_appsec";

/**
 * Migrate
 *
 * AppSec request body limit (one row), applied by the crowdsec-helper container as appsec-config npmplus/body-limit
 *
 * @see https://knexjs.org/guide/migrations.html#migration-api
 *
 * @param   {Object} knex
 * @returns {Promise}
 */
const up = async (knex) => {
	logger.info(`[${migrateName}] Migrating Up...`);

	if (await knex.schema.hasTable("npmplus_crowdsec_appsec")) {
		logger.info(`[${migrateName}] npmplus_crowdsec_appsec Table already exists, skipping`);
		return;
	}
	await knex.schema.createTable("npmplus_crowdsec_appsec", (table) => {
		table.integer("id").notNull().primary();
		// MiB, 1 to 1024
		table.integer("max_body_size_mb").notNull();
		// drop, partial or allow
		table.string("action", 16).notNull();
		table.string("modified_on", 32).notNull().defaultTo("");
	});
	logger.info(`[${migrateName}] npmplus_crowdsec_appsec Table created`);
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
