import { migrate as logger } from "../logger.js";

const migrateName = "crowdsec_exception";

/**
 * Migrate
 *
 * Client addresses (ip or cidr) the CrowdSec bouncer and AppSec skip, for all hosts or only for some proxy hosts
 *
 * @see https://knexjs.org/guide/migrations.html#migration-api
 *
 * @param   {Object} knex
 * @returns {Promise}
 */
const up = async (knex) => {
	logger.info(`[${migrateName}] Migrating Up...`);

	if (await knex.schema.hasTable("npmplus_crowdsec_exception")) {
		logger.info(`[${migrateName}] npmplus_crowdsec_exception Table already exists, skipping`);
	} else {
		await knex.schema.createTable("npmplus_crowdsec_exception", (table) => {
			table.increments().primary();
			table.string("value", 64).notNull();
			table.string("description", 255).notNull().defaultTo("");
			// "global" or "hosts" (the hosts are in npmplus_crowdsec_exception_host)
			table.string("scope", 16).notNull().defaultTo("global");
		});
		logger.info(`[${migrateName}] npmplus_crowdsec_exception Table created`);
	}

	if (await knex.schema.hasTable("npmplus_crowdsec_exception_host")) {
		logger.info(`[${migrateName}] npmplus_crowdsec_exception_host Table already exists, skipping`);
	} else {
		await knex.schema.createTable("npmplus_crowdsec_exception_host", (table) => {
			table.integer("exception_id").notNull().unsigned();
			table.integer("proxy_host_id").notNull().unsigned().index();
			table.primary(["exception_id", "proxy_host_id"]);
		});
		logger.info(`[${migrateName}] npmplus_crowdsec_exception_host Table created`);
	}
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
