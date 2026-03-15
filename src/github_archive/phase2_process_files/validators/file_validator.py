"""
Validators for GitHub Archive files.

Validates file name format (pre-processing) and chunk data quality (during processing).
"""

import re
import pandas as pd
from datetime import datetime, timezone
from typing import Dict, List, Optional
from dataclasses import dataclass, field

from schemas.dtype_definitions import GITHUB_EVENT_DTYPES, REQUIRED_FIELDS


# =============================================================================
# FILE NAME PATTERN
# =============================================================================
# Expected format: YYYY-MM-DD-H.json.gz (hour can be 1 or 2 digits)
# GitHub Archive uses single-digit hours (0-9) for hours 0-9, not zero-padded
FILE_NAME_PATTERN = re.compile(r'^(\d{4}-\d{2}-\d{2}-\d{1,2})\.json\.gz$')


# =============================================================================
# RESULT TYPES
# =============================================================================
@dataclass
class ValidationResult:
    """Result of file name validation."""
    is_valid: bool
    errors: List[str]
    warnings: List[str]


@dataclass
class ChunkValidationResult:
    """Result of chunk data validation."""
    is_valid: bool
    valid_df: Optional[pd.DataFrame]
    records_in: int
    records_out: int
    errors: Dict[str, int] = field(default_factory=dict)
    warnings: Dict[str, int] = field(default_factory=dict)


# =============================================================================
# FILE NAME VALIDATION
# =============================================================================
def validate_file(file_name: str) -> ValidationResult:
    """
    Validate a GitHub Archive file name and format.

    Checks:
    1. File name format (YYYY-MM-DD-HH.json.gz)
    2. Gzip extension

    Args:
        file_name: Name of the file (e.g., 2026-03-05-12.json.gz)

    Returns:
        ValidationResult with validation status
    """
    errors = []
    warnings = []

    # Check .gz extension
    if not file_name.endswith('.gz'):
        errors.append(f"File must have .gz extension, got: {file_name}")
        return ValidationResult(is_valid=False, errors=errors, warnings=warnings)

    # Check .json.gz extension specifically
    if not file_name.endswith('.json.gz'):
        errors.append(f"File must have .json.gz extension, got: {file_name}")
        return ValidationResult(is_valid=False, errors=errors, warnings=warnings)

    # Check pattern
    match = FILE_NAME_PATTERN.match(file_name)
    if not match:
        errors.append(f"File name must match format YYYY-MM-DD-HH.json.gz, got: {file_name}")
        return ValidationResult(is_valid=False, errors=errors, warnings=warnings)

    # Extract and validate date/time components
    date_str = match.group(1)  # YYYY-MM-DD-HH
    parts = date_str.split('-')

    try:
        year, month, day, hour = map(int, parts)

        # Basic sanity checks
        if year < 2011 or year > 2100:
            errors.append(f"Invalid year: {year}")
        if month < 1 or month > 12:
            errors.append(f"Invalid month: {month}")
        if day < 1 or day > 31:
            errors.append(f"Invalid day: {day}")
        if hour < 0 or hour > 23:
            errors.append(f"Invalid hour: {hour}")
    except ValueError:
        errors.append(f"Invalid date/time format: {date_str}")

    return ValidationResult(
        is_valid=len(errors) == 0,
        errors=errors,
        warnings=warnings
    )


# =============================================================================
# CHUNK DATA VALIDATION
# =============================================================================
def validate_chunk(df: pd.DataFrame) -> ChunkValidationResult:
    """
    Validate a chunk of GitHub events in a single pass.

    Coerces dtypes, then builds a boolean mask across all checks.
    Drops invalid rows once at the end.

    Args:
        df: Raw chunk from pd.read_json

    Returns:
        ChunkValidationResult with filtered DataFrame and error counts
    """
    errors = {}
    warnings = {}
    records_in = len(df)

    # --- Phase 1: Dtype coercion (in-place on the chunk, no copy) ---
    for col, expected_dtype in GITHUB_EVENT_DTYPES.items():
        if col not in df.columns:
            continue
        try:
            source_nulls = df[col].isna().sum()
            if expected_dtype in ('string', 'boolean', 'object'):
                df[col] = df[col].astype(expected_dtype)
            nulls_after = df[col].isna().sum()
            coercion_nulls = int(nulls_after - source_nulls)
            if coercion_nulls > 0:
                errors[f'{col}_coercion'] = coercion_nulls
        except Exception:
            warnings[f'{col}_coercion_error'] = 1

    # --- Phase 2: Build mask (all checks, one filter) ---
    mask = pd.Series(True, index=df.index)

    # Required fields: must be present, non-null, non-empty
    missing_cols = set(REQUIRED_FIELDS) - set(df.columns)
    if missing_cols:
        for col in missing_cols:
            errors[col] = records_in
        return ChunkValidationResult(
            is_valid=False, valid_df=None,
            records_in=records_in, records_out=0,
            errors=errors, warnings=warnings,
        )

    for col in REQUIRED_FIELDS:
        bad = df[col].isna() | (df[col].astype(str).str.strip() == '')
        n = int(bad.sum())
        if n:
            errors[col] = n
        mask &= ~bad

    # ID fields: must be non-null and >= 0
    for col in ('actor_id', 'repo_id'):
        if col in df.columns:
            bad = df[col].isna() | (df[col] < 0)
            n = int(bad.sum())
            if n:
                errors[col] = n
            mask &= ~bad

    # event_id: non-null and non-empty (checked on flattened schema)
    if 'event_id' in df.columns:
        bad = df['event_id'].isna() | (df['event_id'] == '')
        n = int(bad.sum())
        if n:
            errors['event_id'] = n
        mask &= ~bad

    # Future timestamps
    if 'created_at' in df.columns:
        now = datetime.now(timezone.utc)

        def _is_future(ts):
            if pd.isna(ts):
                return False
            try:
                if isinstance(ts, str):
                    ts = ts.replace('Z', '+00:00')
                    dt = datetime.fromisoformat(ts)
                    if dt.tzinfo is None:
                        dt = dt.replace(tzinfo=timezone.utc)
                    return dt > now
            except Exception:
                return False
            return False

        future = df['created_at'].apply(_is_future)
        n = int(future.sum())
        if n:
            errors['created_at_future'] = n
            warnings['future_timestamps'] = n
        mask &= ~future

    # --- Phase 3: Single filter ---
    valid_df = df[mask]
    records_out = len(valid_df)

    return ChunkValidationResult(
        is_valid=records_out == records_in,
        valid_df=valid_df,
        records_in=records_in,
        records_out=records_out,
        errors=errors,
        warnings=warnings,
    )


