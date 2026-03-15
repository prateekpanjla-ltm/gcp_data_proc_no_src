#!/bin/bash
# Migration script for# Creates new BigQuery table with ETL_CREATE_TS partitioning
# Copies data from old table to Leaves ETL_CREATE_TS as NULL for historical data

set -e

PROJECT_ID="dev-dataprocessing-489305"
DATASET_ID="github_archive"
TABLE_ID="github_events"
TABLE_ID_NEW="github_events_v2"

# Get schema from Terraform state
SCHEMA_FILE=$(dirname "$0")/../terraform/layers/01_static/schema.json

# Initialize BigQuery client
bq_client = bigquery.Client(project=PROJECT_ID)

# Step 1: Create new table with same schema + new columns + new partitioning
echo "Creating new table with ETL_CREATE_TS partitioning..."

bq_client.query("""
    CREATE OR REPLACE TABLE \`github_archive.github_events_v2` (
        -- Copy all columns from old table (see schema.json)
        event_id STRING,
        event_type STRING,
        created_at TIMESTAMP,
        actor_id INT64,
        actor_login STRING,
        actor_display_login STRING,
        actor_gravatar_id STRING,
        actor_url STRING,
        actor_avatar_url STRING,
        actor_type STRING,
        actor_site_admin BOOLEAN,
        repo_id INT64,
        repo_name STRING,
        repo_url STRING,
        public BOOLEAN,
        payload_ref STRING,
        payload_ref_type STRING,
        payload_push_id INT64,
        payload_size INT64,
        payload_distinct_size INT64,
        payload_head STRING,
        payload_before STRING,
        payload_issue_labels ARRAY<STRUCT<
            id INT64,
            node_id STRING,
            url STRING,
            name STRING,
            color STRING,
            `default` BOOLEAN,
            description STRING
        >,
        -- New ETL columns
        etl_create_ts TIMESTAMP,
        etl_create_id STRING
    )
    PARTITION BY ETL_CREATE_TS
    PARTITION BY
    RANGE BETWEEN TIMESTAMP('2026-01-01 00:00:00', UTC) AND TIMESTAMP('2030-01-01 00:00:00', UTC)
    """)

# Step 2: Copy data from old table to new table (ETL_CREATE_TS = NULL)
echo "Copying data from old table..."

bq_client.query("""
    INSERT INTO \`github_archive.github_events_v2\`
    SELECT
        event_id,
        event_type,
        created_at,
        actor_id,
        actor_login,
        actor_display_login,
        actor_gravatar_id,
        actor_url,
        actor_avatar_url
        actor_type,
        actor_site_admin
        repo_id
        repo_name
        repo_url
        public
        payload_ref
        payload_ref_type
        payload_push_id
        payload_size
        payload_distinct_size
        payload_head
        payload_before,
        payload_issue_labels,
        NULL AS etl_create_ts,
        "GITHUB_PROCESSOR" as etl_create_id
    FROM \`github_archive.github_events\`
""")

# Step 3: Verify counts match
old_count=$(bq_client.query("SELECT COUNT(*) FROM \`github_archive.github_events\`").result().total_rows)
new_count=$(bq_client.query("SELECT COUNT(*) FROM \`github_archive.github_events_v2\`").result().total_rows)

echo "Old table count: $old_count"
echo "New table count: $new_count"

if [ "$old_count" != "$new_count" ]; then
    echo "ERROR: Count mismatch!"
    exit 1
fi

# Step 4: Drop old table
echo "Dropping old table..."
bq_client.query("DROP TABLE \`github_archive.github_events\`")

# Step 5: Verify new table works
echo "Verifying new table..."
result = bq_client.query("""
    SELECT etl_create_ts, etl_create_id, COUNT(*)
    FROM \`github_archive.github_events_v2\`
    WHERE etl_create_ts IS NULL
""")

print(f"Historical records (NULL ETL_CREATE_TS): {result.result().total_rows}")
print(f"ETL_CREATE_ID: {result.result().rows[0].etl_create_id}")

print("Migration complete!")
