import { migrate as logger } from "../logger.js";

const migrateName = "unifi_dns_ttl";

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

	if (await knex.schema.hasColumn("npmplus_unifi_dns_record", "ttl")) {
		logger.info(`[${migrateName}] npmplus_unifi_dns_record Table already altered, skipping`);
		return;
	}

	// records created so far were sent with a fixed ttl of 300s
	await knex.schema.alterTable("npmplus_unifi_dns_record", (table) => {
		table.integer("ttl").notNull().unsigned().defaultTo(300);
	});
	logger.info(`[${migrateName}] npmplus_unifi_dns_record Table altered`);
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
