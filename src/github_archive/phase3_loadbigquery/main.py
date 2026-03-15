"""
BigQuery Loader Cloud Function (2nd gen)

Triggered by Cloud Storage events when files are finalized in the staging bucket.
Loads .ndjson.gz files to BigQuery and optionally deletes the source file.

Cloud Functions 2nd gen uses CloudEvents format, not the legacy (data, context) format.

GCP-coupled: This function is tightly bound to GCP — functions_framework for the runtime,
Eventarc/CloudEvents for event delivery, BigQuery for the load target, and GCS for the
source files. Unlike Phase 2's core logic (validate/flatten/write), there is no portable
business logic here; the entire function is GCP integration glue.
"""

import os
import logging
from google.cloud import bigquery
from google.cloud import storage
import functions_framework
from cloudevents.http import CloudEvent

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Environment variables
PROJECT_ID = os.environ.get("PROJECT_ID")
DATASET_ID = os.environ.get("DATASET_ID", "github_archive")
TABLE_ID = os.environ.get("TABLE_ID", "github_events")
DELETE_AFTER_LOAD = os.environ.get("DELETE_AFTER_LOAD", "true").lower() == "true"

# Clients
bq_client = bigquery.Client(project=PROJECT_ID)
storage_client = storage.Client(project=PROJECT_ID)


@functions_framework.cloud_event
def load_to_bigquery(cloud_event: CloudEvent):
    """
    Cloud Function entry point (2nd gen CloudEvents format).

    Triggered by GCS object finalized event via Eventarc.

    Args:
        cloud_event: CloudEvent containing GCS object metadata
    """
    # CloudEvents format: data is in cloud_event.data
    data = cloud_event.data

    bucket_name = data.get("bucket")
    file_name = data.get("name")
    file_size = data.get("size", "unknown")

    logger.info(f"Event ID: {cloud_event['id']}, Type: {cloud_event['type']}")
    logger.info(f"Processing event: bucket={bucket_name}, file={file_name}, size={file_size}")

    # Validate file extension
    if not file_name.endswith(".ndjson.gz"):
        logger.info(f"Skipping {file_name} - not a .ndjson.gz file")
        return {"status": "skipped", "reason": "invalid_extension"}

    # Only process files in processed/ prefix
    if not file_name.startswith("processed/"):
        logger.info(f"Skipping {file_name} - not in processed/ prefix")
        return {"status": "skipped", "reason": "invalid_prefix"}

    # Construct URIs
    gcs_uri = f"gs://{bucket_name}/{file_name}"
    table_ref = f"{PROJECT_ID}.{DATASET_ID}.{TABLE_ID}"

    logger.info(f"Loading {gcs_uri} to {table_ref}")

    try:
        # Configure load job
        job_config = bigquery.LoadJobConfig(
            source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
            write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
            ignore_unknown_values=True,  # Skip fields not in table schema
            # Schema already exists in table - no autodetect needed
            # BigQuery automatically handles gzip compression
        )

        # Start load job
        load_job = bq_client.load_table_from_uri(
            gcs_uri,
            table_ref,
            job_config=job_config,
        )

        # Wait for completion
        result = load_job.result()

        logger.info(f"Load job completed: {load_job.job_id}")
        logger.info(f"Loaded {result.output_rows} rows")

        # Delete source file after successful load
        if DELETE_AFTER_LOAD:
            try:
                bucket = storage_client.bucket(bucket_name)
                blob = bucket.blob(file_name)
                blob.delete()
                logger.info(f"Deleted source file: {file_name}")
            except Exception as delete_error:
                logger.warning(f"Failed to delete source file: {delete_error}")
                # Don't fail the function if delete fails

        return {
            "status": "success",
            "job_id": load_job.job_id,
            "rows_loaded": result.output_rows,
            "source_file": file_name,
        }

    except Exception as e:
        logger.error(f"Failed to load {gcs_uri}: {e}")
        raise  # Re-raise to trigger retry policy
