const retentionDays = process.env.CLICKHOUSE_DATA_RETENTION_DAYS;

if (!/^[1-9][0-9]*$/.test(retentionDays ?? "")) {
  throw new Error("CLICKHOUSE_DATA_RETENTION_DAYS must be a positive integer");
}

const endpoint = new URL(process.env.CLICKHOUSE_URL ?? "http://clickhouse:8123");
endpoint.searchParams.set("database", process.env.CLICKHOUSE_DB ?? "default");
endpoint.searchParams.set("default_format", "TSVRaw");

const headers = {
  "X-ClickHouse-User": process.env.CLICKHOUSE_USER ?? "default",
  "X-ClickHouse-Key": process.env.CLICKHOUSE_PASSWORD ?? "",
};

async function query(sql) {
  const response = await fetch(endpoint, {
    method: "POST",
    headers,
    body: sql,
    signal: AbortSignal.timeout(10_000),
  });

  if (!response.ok) {
    throw new Error(`ClickHouse returned ${response.status}: ${await response.text()}`);
  }

  return (await response.text()).trim();
}

const sleep = (milliseconds) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

// The worker runs Langfuse's ClickHouse migrations in its entrypoint. The
// post_start hook runs concurrently, so wait until the core tables exist and
// the migration state has remained unchanged before altering any tables.
console.log("Waiting for Langfuse ClickHouse migrations...");
let previousState = "";
let stableChecks = 0;

for (let attempt = 0; attempt < 300 && stableChecks < 8; attempt += 1) {
  try {
    const coreTableCount = await query(`
      SELECT count()
      FROM system.tables
      WHERE database = currentDatabase()
        AND name IN ('traces', 'observations', 'scores')
    `);
    const migrationsTableCount = await query(`
      SELECT count()
      FROM system.tables
      WHERE database = currentDatabase()
        AND name = 'schema_migrations'
    `);

    if (coreTableCount === "3" && migrationsTableCount === "1") {
      const migrationState = await query(`
        SELECT concat(toString(version), ':', toString(dirty))
        FROM schema_migrations
        LIMIT 1
      `);

      if (migrationState.endsWith(":0")) {
        if (migrationState === previousState) {
          stableChecks += 1;
        } else {
          previousState = migrationState;
          stableChecks = 1;
        }
      } else {
        previousState = "";
        stableChecks = 0;
      }
    }
  } catch {
    previousState = "";
    stableChecks = 0;
  }

  if (stableChecks < 8) await sleep(2_000);
}

if (stableChecks < 8) {
  throw new Error("Timed out waiting for Langfuse ClickHouse migrations");
}

async function applyTtl(table, timestampColumn) {
  const compatibleTable = await query(`
    SELECT count()
    FROM system.tables AS t
    INNER JOIN system.columns AS c
      ON c.database = t.database AND c.table = t.name
    WHERE t.database = currentDatabase()
      AND t.name = '${table}'
      AND t.engine LIKE '%MergeTree%'
      AND c.name = '${timestampColumn}'
  `);

  if (compatibleTable === "0") {
    console.log(`Skipping ${table}: compatible table/column is not present`);
    return;
  }

  console.log(`Setting ${table} retention to ${retentionDays} days`);
  await query(`
    ALTER TABLE \`${table}\`
    MODIFY TTL \`${timestampColumn}\` + toIntervalDay(${retentionDays}) DELETE
  `);
}

// Other ClickHouse tables contain current metadata, migration state, or
// specialized fixed-window data and must not inherit the global TTL.
await applyTtl("traces", "timestamp");
await applyTtl("observations", "start_time");
await applyTtl("scores", "timestamp");
await applyTtl("event_log", "created_at");
await applyTtl("events_full", "start_time");
await applyTtl("events_core", "start_time");

console.log(
  "ClickHouse data retention policy applied. Expired rows are removed asynchronously during merges.",
);
