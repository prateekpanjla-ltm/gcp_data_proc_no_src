"""
File processor for GitHub Archive Phase 2 processing.

Main processing logic that validates, transforms, and writes files.
Uses Pandas with chunked processing for memory efficiency.
"""

import gzip
import logging
import os
import tempfile
import time
from typing import List, Optional
from dataclasses import dataclass

import pandas as pd
from google.api_core import exceptions as gcp_exceptions
from google.cloud import storage

from validators.file_validator import validate_file, validate_chunk
from processors.transformer import transform_chunk

from writers.ndjson_writer import write_dataframe_to_gcs


logger = logging.getLogger('file-processor')


# =============================================================================
# PROCESSING RESULT
# =============================================================================
@dataclass
class FileProcessingResult:
    """Result of processing a single file."""
    success: bool
    input_file: str
    output_file: Optional[str]
    output_files: List[str]
    records_in: int
    records_out: int
    errors: int
    warnings: int
    duration_seconds: float
    error_message: Optional[str] = None


# =============================================================================
# FILE PROCESSOR
# =============================================================================
def process_file(
    input_gcs_path: str,
    project_id: str,
    staging_bucket: str,
    chunksize: int = 100_000
) -> FileProcessingResult:
    """
    Process a GitHub Archive file: validate, transform, write to staging.

    Args:
        input_gcs_path: Input GCS path (gs://landing-bucket/raw/file.json.gz)
        project_id: GCP project ID
        staging_bucket: Staging bucket name
        chunksize: Number of records per chunk for processing

    Returns:
        FileProcessingResult with processing statistics
    """
    start_time = time.time()
    # Single client for the entire file: reused for download + all chunk uploads.
    # Creating a client per chunk would re-fetch credentials from the metadata server
    # and open fresh TLS connections on every write — pure overhead at scale.
    # Worst case: the metadata server (169.254.169.254) throttles credential requests
    # with HTTP 429s, causing storage operations to fail silently or raise
    # google.auth.exceptions.TransportError — hard to diagnose in logs since
    # the error surfaces as a storage failure, not an auth failure.
    storage_client = storage.Client(project=project_id)

    # Extract bucket/blob from gs:// path
    path_without_prefix = input_gcs_path.removeprefix("gs://")
    # Bucket name is always the first segment before the first /
    bucket_name, blob_path = path_without_prefix.split('/', 1)
    # File name is always the last segment — / is not allowed in GCS object names' final component
    # split('/') returns a list, [-1] gets the last element
    file_name = blob_path.split('/')[-1]

    # Get file metadata
    try:
        blob = storage_client.bucket(bucket_name).blob(blob_path)
        blob.reload()
    except (gcp_exceptions.Forbidden, gcp_exceptions.NotFound) as e:
        logger.error(f"Failed to get file metadata for {file_name}: {e}")
        return FileProcessingResult(
            success=False,
            input_file=input_gcs_path,
            output_file=None,
            output_files=[],
            records_in=0,
            records_out=0,
            errors=1,
            warnings=0,
            duration_seconds=time.time() - start_time,
            error_message=str(e)
        )

    # Validate file (name format and size)
    validation_result = validate_file(file_name)
    if not validation_result.is_valid:
        error_msg = '; '.join(validation_result.errors)
        logger.error(f"File validation failed for {file_name}: {error_msg}")
        return FileProcessingResult(
            success=False,
            input_file=input_gcs_path,
            output_file=None,
            output_files=[],
            records_in=0,
            records_out=0,
            errors=len(validation_result.errors),
            warnings=len(validation_result.warnings),
            duration_seconds=time.time() - start_time,
            error_message=error_msg
        )

    # Log start
    logger.info(f"Processing file: {file_name} ({blob.size} bytes)")

    # Process the file
    try:
        result = _process_with_pandas(
            blob, file_name, input_gcs_path,
            storage_client, staging_bucket, chunksize
        )

        # Log completion
        logger.info(f"Completed {file_name}: {result.records_in} in, {result.records_out} out, {result.errors} errors, {result.duration_seconds:.1f}s")

        return result

    except Exception as e:
        logger.error(f"{file_name}: Error during pandas processing: {e}")
        return FileProcessingResult(
            success=False,
            input_file=input_gcs_path,
            output_file=None,
            output_files=[],
            records_in=0,
            records_out=0,
            errors=1,
            warnings=0,
            duration_seconds=time.time() - start_time,
            error_message=str(e)
        )


def _process_with_pandas(
    blob,
    file_name: str,
    input_gcs_path: str,
    storage_client,
    staging_bucket: str,
    chunksize: int
) -> FileProcessingResult:
    """
    Process file using Pandas with chunked reading and streaming writes.

    Each chunk is processed and written immediately to GCS, avoiding memory accumulation.
    """
    start_time = time.time()
    total_records_in = 0
    total_records_out = 0
    total_errors = 0
    total_warnings = 0

    # Download to temp file (use .json.gz suffix so decompress logic works)
    with tempfile.NamedTemporaryFile(delete=False, suffix='.json.gz') as tmp:
        tmp_path = tmp.name

    try:
        # Download and decompress from GCS
        blob.download_to_filename(tmp_path)
        decompressed_path = tmp_path[:-3]  # remove .gz
        with gzip.open(tmp_path, 'rb') as f_in:
            with open(decompressed_path, 'wb') as f_out:
                f_out.write(f_in.read())
        os.remove(tmp_path)
        tmp_path = decompressed_path

        # Extract date/hour from filename for output naming
        date_prefix = file_name.replace('.json.gz', '')

        # Track output files
        output_files = []
        chunks_processed = 0

        # TODO: Memory optimization — current flow creates ~4 DataFrame copies per chunk (~400MB):
        #   1. chunk_df from pd.read_json
        #   2. valid_df from validate_chunk (df[mask] copy)
        #   3. flattened df from flatten_schema (new DataFrame)
        #   4. to_dict list from write_dataframe_to_gcs
        # Can reduce to ~2 copies by:
        #   - validate_chunk returns mask only (no valid_df copy)
        #   - flatten_schema receives chunk_df[mask] view
        #   - writer uses itertuples instead of to_dict

        # Process chunks sequentially
        for chunk_df in pd.read_json(tmp_path, lines=True, chunksize=chunksize):
            chunks_processed += 1
            records_in_chunk = len(chunk_df)
            total_records_in += records_in_chunk

            # Validate (dtypes + values in single pass)
            val_result = validate_chunk(chunk_df)
            total_errors += len(val_result.errors)
            total_warnings += len(val_result.warnings)

            working_df = val_result.valid_df if val_result.valid_df is not None else chunk_df

            # Transform (flatten schema)
            transform_result = transform_chunk(working_df)
            total_records_out += transform_result.records_out
            total_errors += transform_result.error_count

            # Write this chunk immediately to GCS
            if not transform_result.df.empty:
                blob_name = f"processed/{date_prefix}-chunk-{chunks_processed:03d}.ndjson.gz"

                output_path = write_dataframe_to_gcs(
                    transform_result.df,
                    blob_name,
                    storage_client,
                    staging_bucket
                )
                output_files.append(output_path)

            # Log progress
            logger.info(f"Chunk {chunks_processed} processed: {records_in_chunk} records")

    finally:
        # Clean up temp file
        try:
            os.remove(tmp_path)
        except OSError:
            pass

    duration = time.time() - start_time

    # Determine success
    success = (
        total_records_out > 0 and
        (total_errors == 0 or total_errors / total_records_in < 0.1)
    )

    # Return result with multiple output files
    return FileProcessingResult(
        success=success,
        input_file=input_gcs_path,
        output_file=output_files[0] if output_files else None,
        output_files=output_files,
        records_in=total_records_in,
        records_out=total_records_out,
        errors=total_errors,
        warnings=total_warnings,
        duration_seconds=duration
    )
