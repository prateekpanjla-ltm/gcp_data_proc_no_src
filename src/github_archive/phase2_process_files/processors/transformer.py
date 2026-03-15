"""
Transformer for GitHub Archive events.

Flattens nested JSON structures into the staging schema format.
"""

import pandas as pd
from typing import Dict, List, Any
from dataclasses import dataclass

# Import field mappings from source of truth
from schemas.dtype_definitions import (
    ACTOR_FIELD_MAPPING,
    REPO_FIELD_MAPPING,
    ISSUE_FIELD_MAPPING,
)


# =============================================================================
# TRANSFORMATION RESULT
# =============================================================================
@dataclass
class TransformationResult:
    """Result of a transformation operation."""
    df: pd.DataFrame
    records_in: int
    records_out: int
    error_count: int


# =============================================================================
# PAYLOAD FIELD MAPPING (not in dtype_definitions as it varies by event type)
# =============================================================================
PAYLOAD_FIELD_MAPPING = {
    'ref': 'payload_ref',
    'ref_type': 'payload_ref_type',
    'push_id': 'payload_push_id',
    'size': 'payload_size',
    'distinct_size': 'payload_distinct_size',
    'head': 'payload_head',
    'before': 'payload_before',
}


# =============================================================================
# TRANSFORMER FUNCTIONS
# =============================================================================
def _safe_get(obj: Any, field: str, default: Any = None) -> Any:
    """Safely get a field from a dictionary."""
    if isinstance(obj, dict):
        return obj.get(field, default)
    return default


def _merge_extracted(
    result: pd.DataFrame,
    source_df: pd.DataFrame,
    source_columns: List[str],
    field_mapping: Dict[str, str]
) -> pd.DataFrame:
    """Merge extracted fields into result dataframe."""
    for source_col in source_columns:
        if source_col not in source_df.columns:
            # Add empty columns with default None
            for target_field in field_mapping.values():
                if target_field not in result.columns:
                    result[target_field] = None
            continue

        for source_field, target_field in field_mapping.items():
            if target_field not in result.columns:
                result[target_field] = source_df[source_col].apply(
                    lambda x: _safe_get(x, source_field) if isinstance(x, dict) else None
                )

    return result


def _merge_extracted_nested(
    result: pd.DataFrame,
    source_df: pd.DataFrame,
    path_parts: List[str],
    field_mapping: Dict[str, str]
) -> pd.DataFrame:
    """
    Merge extracted fields from nested path (e.g., payload.issue.labels).

    Navigates multiple levels of nesting to extract fields.
    """
    if not path_parts or path_parts[0] not in source_df.columns:
        # Add empty columns for all mapped fields
        for target_field in field_mapping.values():
            if target_field not in result.columns:
                result[target_field] = None
        return result

    # Navigate the nested path step by step
    current_data = source_df[path_parts[0]]
    for part in path_parts[1:]:
        current_data = current_data.apply(
            lambda x: _safe_get(x, part) if isinstance(x, dict) else None
        )

    # Extract fields from the final nested object
    for source_field, target_field in field_mapping.items():
        if target_field not in result.columns:
            result[target_field] = current_data.apply(
                lambda x: _safe_get(x, source_field) if isinstance(x, dict) else None
            )

    return result


def flatten_schema(df: pd.DataFrame) -> pd.DataFrame:
    """
    Transform nested schema to flattened staging schema.

    Args:
        df: Input dataframe with nested GitHub events

    Returns:
        Flattened dataframe ready for staging output
    """
    # Start with core fields
    result = pd.DataFrame()

    # Map core fields
    result['event_id'] = df.get('id', pd.Series(dtype='string'))
    result['event_type'] = df.get('type', pd.Series(dtype='string'))
    result['created_at'] = df.get('created_at', pd.Series(dtype='string'))
    result['public'] = df.get('public', True)

    # Extract nested fields
    result = _merge_extracted(result, df, ['actor'], ACTOR_FIELD_MAPPING)
    result = _merge_extracted(result, df, ['repo'], REPO_FIELD_MAPPING)
    result = _merge_extracted(result, df, ['payload'], PAYLOAD_FIELD_MAPPING)

    # Extract deeply nested fields (e.g., payload.issue.labels)
    result = _merge_extracted_nested(result, df, ['payload', 'issue'], ISSUE_FIELD_MAPPING)

    # Add ETL metadata columns
    result['etl_create_ts'] = pd.Timestamp.now(tz='UTC')
    result['etl_create_id'] = "GITHUB_PROCESSOR"

    return result


def _ensure_dtypes(df: pd.DataFrame) -> pd.DataFrame:
    """Ensure proper dtypes for output columns."""
    # String columns
    string_cols = [
        'event_id', 'event_type', 'created_at',
        'actor_login', 'actor_display_login', 'actor_avatar_url', 'actor_gravatar_id',
        'actor_type', 'actor_url',
        'repo_name', 'repo_url',
        'payload_ref', 'payload_ref_type',
        'payload_head', 'payload_before',
        'etl_create_id'
    ]

    for col in string_cols:
        if col in df.columns:
            df[col] = df[col].astype('string')

    # Integer columns (nullable Int64 - handles JSON null properly)
    int_cols = [
        'actor_id', 'repo_id', 'payload_push_id',
        'payload_size', 'payload_distinct_size'
    ]

    for col in int_cols:
        if col in df.columns:
            df[col] = df[col].astype('Int64')

    # Boolean columns
    bool_cols = ['public', 'actor_site_admin']

    for col in bool_cols:
        if col in df.columns:
            df[col] = df[col].astype('boolean')

    return df


def transform_chunk(df: pd.DataFrame) -> TransformationResult:
    """
    Transform a chunk of GitHub events.

    Args:
        df: Input dataframe with nested GitHub events

    Returns:
        TransformationResult with flattened dataframe
    """
    records_in = len(df)

    try:
        # Flatten schema
        flattened = flatten_schema(df)

        # Ensure proper dtypes
        flattened = _ensure_dtypes(flattened)

        records_out = len(flattened)

        return TransformationResult(
            df=flattened,
            records_in=records_in,
            records_out=records_out,
            error_count=records_in - records_out
        )

    except Exception as e:
        # Return empty dataframe on error
        return TransformationResult(
            df=pd.DataFrame(),
            records_in=records_in,
            records_out=0,
            error_count=records_in
        )
