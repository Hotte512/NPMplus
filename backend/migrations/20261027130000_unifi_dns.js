import { migrate as logger } from "../logger.js";

const migrateName = "unifi_dns";

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

	if (await knex.schema.hasColumn("proxy_host", "npmplus_unifi_dns")) {
		logger.info(`[${migrateName}] proxy_host Table already altered, skipping`);
	} else {
		await knex.schema.alterTable("proxy_host", (table) => {
			table.string("npmplus_unifi_dns").notNull().defaultTo("off");
			table.string("npmplus_unifi_dns_target").notNull().defaultTo("");
		});
		logger.info(`[${migrateName}] proxy_host Table altered`);
	}

	// dns policies created on the unifi controller, only these are ever changed or deleted
	if (!(await knex.schema.hasTable("npmplus_unifi_dns_record"))) {
		await knex.schema.createTable("npmplus_unifi_dns_record", (table) => {
			table.integer("proxy_host_id").notNull().unsigned();
			table.string("domain").notNull();
			table.string("policy_id").notNull();
			table.string("type").notNull();
			table.string("value").notNull();
			table.primary(["proxy_host_id", "domain"]);
		});
		logger.info(`[${migrateName}] npmplus_unifi_dns_record Table created`);
	}

	if (!(await knex("setting").where({ id: "unifi-dns" }).first())) {
		await knex("setting").insert({
			id: "unifi-dns",
			name: "UniFi Local DNS",
			description: "Create local DNS records for proxy hosts on a UniFi gateway",
			value: "disabled",
			meta: JSON.stringify({ url: "", api_key: "", site_id: "", default_target: "", verify_tls: false }),
		});
		logger.info(`[${migrateName}] unifi-dns setting added`);
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
