"""
NDJSON writer for GitHub Archive staging output.

Writes processed DataFrames as gzip-compressed newline-delimited JSON to GCS
using streaming uploads.
"""

import json
import gzip
import logging
from typing import Any

import pandas as pd
from google.cloud.storage import Client as StorageClient, Blob


logger = logging.getLogger(__name__)


def write_dataframe_to_gcs(
    df: pd.DataFrame,
    blob_name: str,
    storage_client: StorageClient,
    bucket_name: str,
    compress: bool = True,
    chunk_size: int = 10 * 1024 * 1024  # 10MB upload chunks
) -> str:
    """
    Write a DataFrame to GCS as gzip-compressed NDJSON.

    Args:
        df: Input DataFrame
        blob_name: GCS blob name (e.g., 'processed/2026-03-05-12-chunk-001.ndjson.gz')
        storage_client: Existing GCS storage client (reused, not created per call)
        bucket_name: GCS bucket name
        compress: Whether to gzip compress the output
        chunk_size: Upload chunk size in bytes

    Returns:
        GCS output path (e.g., 'gs://bucket/processed/2026-03-05-12-chunk-001.ndjson.gz')
    """
    # Add .gz suffix if compressing and not already present
    blob_path = blob_name
    if compress and not blob_path.endswith('.gz'):
        blob_path = blob_path + '.gz'

    blob = Blob(blob_path, storage_client.bucket(bucket_name))

    # Stream upload
    with blob.open('wb', chunk_size=chunk_size) as f:
        if compress:
            gzip_file = gzip.GzipFile(fileobj=f, mode='wb')
        else:
            gzip_file = f

        try:
            for record in df.to_dict(orient='records'):
                json_str = json.dumps(
                    record,
                    default=_json_serializer,
                    ensure_ascii=False
                )
                gzip_file.write((json_str + '\n').encode('utf-8'))
        finally:
            if compress:
                gzip_file.close()

    return f"gs://{bucket_name}/{blob_path}"


def _json_serializer(obj: Any) -> Any:
    """Handle non-serializable types (pandas NA, nullable dtypes)."""
    if pd.isna(obj):
        return None
    return str(obj)
