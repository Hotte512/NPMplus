import { migrate as logger } from "../logger.js";

const migrateName = "proxy_host_acme_passthrough";

/**
 * Migrate
 *
 * @see https://knexjs.org/guide/migrations.html#migration-api
 *
 * @param   {Object} knex
 * @returns {Promise}
 */
const up = async (knex) => {
	logger.info(`[${migrateName}] Migrating Up...`);

	if (await knex.schema.hasColumn("proxy_host", "npmplus_acme_passthrough")) {
		logger.info(`[${migrateName}] proxy_host Table already altered, skipping`);
		return;
	}

	await knex.schema.alterTable("proxy_host", (table) => {
		table.integer("npmplus_acme_passthrough").notNull().unsigned().defaultTo(0);
	});
	logger.info(`[${migrateName}] proxy_host Table altered`);
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
