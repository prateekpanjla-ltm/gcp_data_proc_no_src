"""
Schema definitions for GitHub Archive event processing.

Defines expected dtypes, validation rules, and output schema for
GitHub Archive events processed from Phase 1 landing zone to Phase 2 staging.
"""

from typing import Dict, List, Set, Any, Optional
from dataclasses import dataclass
from datetime import datetime
from google.cloud.bigquery import SchemaField


# =============================================================================
# KNOWN EVENT TYPES (GitHub Archive)
# =============================================================================
# This is a reference list of known GitHub event types for documentation.
# We use PASS-THROUGH mode - any event type string is accepted without
# validation. This provides flexibility when GitHub adds new event types.
VALID_EVENT_TYPES: Set[str] = {
    'PushEvent',
    'CreateEvent',
    'DeleteEvent',
    'WatchEvent',
    'IssuesEvent',
    'IssueCommentEvent',
    'PullRequestEvent',
    'PullRequestReviewEvent',
    'PullRequestReviewCommentEvent',
    'ForkEvent',
    'ReleaseEvent',
    'MemberEvent',
    'GollumEvent',
    'CommitCommentEvent',
    'TeamAddEvent',
    'ProtectBranchEvent',
    # Newer event types (added 2025+)
    'PublicEvent',
    'DiscussionEvent',
}


# =============================================================================
# INPUT SCHEMA (GitHub Archive - Nested JSON)
# =============================================================================
# Using pandas extension types that map naturally to JSON
# 'string'  - nullable string (handles JSON null)
# 'Int64'   - nullable integer (handles JSON null)
# 'boolean' - nullable boolean (handles JSON null)
# 'object'  - Python object (for nested dicts/lists)
GITHUB_EVENT_DTYPES: Dict[str, str] = {
    # Core fields (all present in 100% of records)
    'id': 'string',
    'type': 'string',
    'public': 'boolean',
    'created_at': 'string',
    # Nested objects (will be extracted/flattened)
    'actor': 'object',
    'repo': 'object',
    'payload': 'object',
    # Optional fields (not always present)
    'org': 'object',
    'other': 'object',
}


# =============================================================================
# ACTOR FIELD DEFINITIONS
# =============================================================================
# Based on actual GitHub Archive data analysis (161,786 records validated)
# Core fields: id, login, display_login, gravatar_id, url, avatar_url
# Note: 'type' and 'site_admin' are in GitHub API spec but not in GH Archive data
ACTOR_FIELDS: Dict[str, str] = {
    'actor_id': 'Int64',          # nullable integer (JSON null → pd.NA)
    'actor_login': 'string',       # nullable string
    'actor_display_login': 'string',  # Present in 100% of GH Archive records
    'actor_gravatar_id': 'string',  # nullable string (often empty)
    'actor_url': 'string',         # nullable string
    'actor_avatar_url': 'string',   # nullable string
    # Optional fields (GitHub API spec but rarely/never in GH Archive)
    'actor_type': 'string',        # Optional, nullable
    'actor_site_admin': 'boolean',  # Optional, nullable
}


# =============================================================================
# REPO FIELD DEFINITIONS
# =============================================================================
REPO_FIELDS: Dict[str, str] = {
    'repo_id': 'Int64',      # nullable integer
    'repo_name': 'string',   # nullable string
    'repo_url': 'string',    # nullable string
}


# =============================================================================
# OUTPUT SCHEMA (Flattened for Staging - NDJSON)
# =============================================================================
# Pandas extension types that map to JSON:
# - 'string': nullable string (JSON null → pd.NA)
# - 'Int64': nullable integer (JSON null → pd.NA)
# - 'boolean': nullable boolean (JSON null → pd.NA)
# - 'float64': floating point (handles decimals)
OUTPUT_SCHEMA: Dict[str, str] = {
    # Event identifiers
    'event_id': 'string',
    'event_type': 'string',
    'created_at': 'string',

    # Actor fields (from nested actor object)
    'actor_id': 'Int64',
    'actor_login': 'string',
    'actor_display_login': 'string',
    'actor_gravatar_id': 'string',
    'actor_url': 'string',
    'actor_avatar_url': 'string',
    # Optional (GitHub API spec but rarely/never in GH Archive)
    'actor_type': 'string',      # nullable
    'actor_site_admin': 'boolean', # nullable

    # Repository fields (from nested repo object)
    'repo_id': 'Int64',
    'repo_name': 'string',
    'repo_url': 'string',

    # Event metadata
    'public': 'boolean',

    # Payload fields (common across event types)
    'payload_ref': 'string',
    'payload_ref_type': 'string',
    'payload_push_id': 'Int64',
    'payload_size': 'Int64',
    'payload_distinct_size': 'Int64',
    'payload_head': 'string',
    'payload_before': 'string',

    # Issue fields (from payload.issue.*)
    'payload_issue_labels': 'object',  # Array of label objects (kept as-is)
}


# =============================================================================
# OPTIONAL PAYLOAD FIELDS (for specific event types)
# =============================================================================
OPTIONAL_PAYLOAD_FIELDS: Dict[str, List[str]] = {
    'PushEvent': ['ref', 'ref_type', 'push_id', 'size', 'distinct_size', 'head', 'before'],
    'CreateEvent': ['ref', 'ref_type', 'master_branch', 'description'],
    'DeleteEvent': ['ref', 'ref_type', 'pusher_type'],
    'WatchEvent': [],
    'IssuesEvent': ['action', 'issue'],
    'IssueCommentEvent': ['action', 'issue', 'comment'],
    'PullRequestEvent': ['action', 'pull_request'],
    'PullRequestReviewEvent': ['action', 'review', 'pull_request'],
    'PullRequestReviewCommentEvent': ['action', 'comment', 'pull_request'],
    'ForkEvent': ['forkee'],
    'ReleaseEvent': ['action', 'release'],
    'MemberEvent': ['action', 'member'],
    'GollumEvent': ['pages'],
    'CommitCommentEvent': ['comment'],
    'TeamAddEvent': ['team', 'repo'],
    'ProtectBranchEvent': ['protected_branch'],
}


# =============================================================================
# REQUIRED FIELDS (validation)
# =============================================================================
REQUIRED_FIELDS: List[str] = [
    'id',
    'type',
    'created_at',
    'actor',
    'repo',
]


# =============================================================================
# FIELD MAPPINGS (nested -> flattened)
# =============================================================================
ACTOR_FIELD_MAPPING: Dict[str, str] = {
    'id': 'actor_id',
    'login': 'actor_login',
    'display_login': 'actor_display_login',
    'gravatar_id': 'actor_gravatar_id',
    'url': 'actor_url',
    'avatar_url': 'actor_avatar_url',
    # Optional fields (GitHub API spec but rarely in GH Archive)
    'type': 'actor_type',
    'site_admin': 'actor_site_admin',
}


REPO_FIELD_MAPPING: Dict[str, str] = {
    'id': 'repo_id',
    'name': 'repo_name',
    'url': 'repo_url',
}


# =============================================================================
# ISSUE FIELD MAPPINGS (payload.issue.*)
# =============================================================================
# Fields from nested issue object in payload (2 levels deep: payload.issue.labels)
ISSUE_FIELD_MAPPING: Dict[str, str] = {
    'labels': 'payload_issue_labels',  # Array of label objects (kept as object type)
}


# =============================================================================
# VALIDATION RULES
# =============================================================================
@dataclass
class ValidationRule:
    """Defines a validation rule for a field."""
    field: str
    dtype: str
    nullable: bool = False
    allowed_values: Optional[Set[Any]] = None
    min_value: Optional[Any] = None
    max_value: Optional[Any] = None
    pattern: Optional[str] = None


VALIDATION_RULES: List[ValidationRule] = [
    # Event ID validation
    ValidationRule(field='event_id', dtype='string', nullable=False),

    # Event type - pass-through any string value (GitHub adds new types over time)
    # We validate dtype but not allowed_values to maintain flexibility
    ValidationRule(field='event_type', dtype='string', nullable=False),

    # Timestamp validation (ISO 8601 format)
    ValidationRule(field='created_at', dtype='string', nullable=False),

    # Actor fields (nullable Int64 for JSON null handling)
    ValidationRule(field='actor_id', dtype='Int64', nullable=False, min_value=1),
    ValidationRule(field='actor_login', dtype='string', nullable=False),

    # Repo fields (nullable Int64 for JSON null handling)
    ValidationRule(field='repo_id', dtype='Int64', nullable=False, min_value=1),
    ValidationRule(field='repo_name', dtype='string', nullable=False),

    # Public flag (nullable boolean for JSON null handling)
    ValidationRule(field='public', dtype='boolean', nullable=True),
]



# =============================================================================
# BIGQUERY OUTPUT SCHEMA
# =============================================================================
# Explicit schema definition for BigQuery table creation using SchemaField class.
# Maps directly to BigQuery SchemaField format with field name, type, and mode.
# Reference: https://cloud.google.com/bigquery/docs/schemas
#
# Type mappings (pandas -> BigQuery):
# - 'string' -> 'STRING' (nullable)
# - 'Int64'   -> 'INT64' (nullable)
# - 'boolean' -> 'BOOLEAN' (nullable)
# - 'object'  -> 'STRING' (JSON serialized) or 'JSON' type
#
# For the 'object' type (labels), we store as JSON string which can be
# parsed with JSON_EXTRACT() or PARSE_JSON() functions in BigQuery.
#
# Note: This schema is for reference and can be used with:
# - bq CLI: bq load --schema_file bigquery_schema.json ...
# - BigQuery API: when creating tables programmatically
# Our pipeline does NOT load data to BigQuery directly - it writes NDJSON
# to GCS, which is then loaded to BigQuery separately.

# Schema as SchemaField objects
BIGQUERY_SCHEMA: List[SchemaField] = [
    # Event identifiers
    SchemaField('event_id', 'STRING', mode='NULLABLE', description='Unique event identifier from GitHub Archive'),
    SchemaField('event_type', 'STRING', mode='NULLABLE', description='Type of GitHub event (PushEvent, IssuesEvent, etc.)'),
    SchemaField('created_at', 'TIMESTAMP', mode='NULLABLE', description='Event timestamp (ISO 8601 format)'),

    # Actor fields (from nested actor object)
    SchemaField('actor_id', 'INT64', mode='NULLABLE', description='GitHub user ID of the actor'),
    SchemaField('actor_login', 'STRING', mode='NULLABLE', description='Username of the actor'),
    SchemaField('actor_display_login', 'STRING', mode='NULLABLE', description='Display name of the actor'),
    SchemaField('actor_gravatar_id', 'STRING', mode='NULLABLE', description='Gravatar hash for actor avatar'),
    SchemaField('actor_url', 'STRING', mode='NULLABLE', description='GitHub API URL for the actor'),
    SchemaField('actor_avatar_url', 'STRING', mode='NULLABLE', description='Avatar image URL'),
    SchemaField('actor_type', 'STRING', mode='NULLABLE', description='Type of user account (if available)'),
    SchemaField('actor_site_admin', 'BOOLEAN', mode='NULLABLE', description='Whether actor is a site admin'),

    # Repository fields (from nested repo object)
    SchemaField('repo_id', 'INT64', mode='NULLABLE', description='GitHub repository ID'),
    SchemaField('repo_name', 'STRING', mode='NULLABLE', description='Repository name (owner/repo)'),
    SchemaField('repo_url', 'STRING', mode='NULLABLE', description='GitHub API URL for the repository'),

    # Event metadata
    SchemaField('public', 'BOOLEAN', mode='NULLABLE', description='Whether the event is public'),

    # Payload fields (common across event types)
    SchemaField('payload_ref', 'STRING', mode='NULLABLE', description='Git reference (branch/tag) from payload'),
    SchemaField('payload_ref_type', 'STRING', mode='NULLABLE', description='Reference type (branch, tag, etc.)'),
    SchemaField('payload_push_id', 'INT64', mode='NULLABLE', description='Push event ID'),
    SchemaField('payload_size', 'INT64', mode='NULLABLE', description='Number of commits in push'),
    SchemaField('payload_distinct_size', 'INT64', mode='NULLABLE', description='Number of distinct commits'),
    SchemaField('payload_head', 'STRING', mode='NULLABLE', description='HEAD commit SHA'),
    SchemaField('payload_before', 'STRING', mode='NULLABLE', description='Before commit SHA'),

    # Issue fields (from payload.issue.*)
    # Stored as REPEATED RECORD (array of label objects)
    SchemaField(
        'payload_issue_labels',
        'RECORD',
        mode='REPEATED',
        fields=[
            SchemaField('id', 'INT64', description='Label ID'),
            SchemaField('node_id', 'STRING', description='Label node ID'),
            SchemaField('url', 'STRING', description='Label URL'),
            SchemaField('name', 'STRING', description='Label name'),
            SchemaField('color', 'STRING', description='Label color hex code'),
            SchemaField('default', 'BOOLEAN', description='Whether this is the default label'),
            SchemaField('description', 'STRING', description='Label description'),
        ],
        description='Issue labels as array of label objects'
    ),

    # ETL metadata (added by transformer at runtime)
    SchemaField('etl_create_ts', 'TIMESTAMP', mode='NULLABLE', description='Timestamp when Phase 2 processor created this record'),
    SchemaField('etl_create_id', 'STRING', mode='NULLABLE', description='ETL processor identifier'),
]


def _schema_field_to_dict(field: SchemaField) -> Dict[str, Any]:
    """
    Convert a SchemaField object to a dictionary for JSON serialization.
    """
    result = {
        'name': field.name,
        'type': field.field_type,
        'mode': field.mode,
    }
    if field.description:
        result['description'] = field.description
    if field.fields:
        result['fields'] = [_schema_field_to_dict(f) for f in field.fields]
    return result


def get_bigquery_schema_json() -> str:
    """
    Return the BigQuery schema as a JSON string.

    This can be used directly with:
    - bq command-line tool: bq load --schema_file schema.json
    - Terraform google_bigquery_table schema resource

    Returns:
        JSON string representation of the schema
    """
    import json

    schema_dicts = [_schema_field_to_dict(f) for f in BIGQUERY_SCHEMA]
    return json.dumps(schema_dicts, indent=2)


def get_bigquery_schema_fields() -> List[SchemaField]:
    """
    Return the BigQuery schema as SchemaField objects for direct API use.

    This can be used directly with:
    - google.cloud.bigquery.Client.create_table(): Table(table_id, schema=schema)
    - google.cloud.bigquery.LoadJobConfig: LoadJobConfig(schema=schema)

    Returns:
        List of SchemaField objects

    Example:
        from google.cloud import bigquery
        from src.github_archive.phase2_process_files.schemas.dtype_definitions import get_bigquery_schema_fields

        client = bigquery.Client()
        schema = get_bigquery_schema_fields()
        table = bigquery.Table('project.dataset.table', schema=schema)
        client.create_table(table)
    """
    return BIGQUERY_SCHEMA.copy()


# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
def is_valid_event_type(event_type: str) -> bool:
    """
    Check if an event type is in the known list (informational only).

    Note: This is for documentation/reference only. The pipeline uses
    pass-through mode and accepts any event type string from GitHub Archive.
    """
    return event_type in VALID_EVENT_TYPES


def get_optional_fields_for_event(event_type: str) -> List[str]:
    """Get optional payload fields for a specific event type."""
    return OPTIONAL_PAYLOAD_FIELDS.get(event_type, [])


def validate_output_schema(record: Dict[str, Any]) -> List[str]:
    """
    Validate a record against the output schema.

    Returns a list of validation errors (empty if valid).
    """
    errors: List[str] = []

    for rule in VALIDATION_RULES:
        value = record.get(rule.field)

        # Check nullability
        if value is None:
            if not rule.nullable:
                errors.append(f"Field '{rule.field}' is required but is null")
            continue

        # Check dtype (basic check)
        expected_type = rule.dtype
        if expected_type == 'Int64':
            if not isinstance(value, int):
                errors.append(f"Field '{rule.field}' should be Int64, got {type(value).__name__}")
        elif expected_type == 'int64':
            if not isinstance(value, int):
                errors.append(f"Field '{rule.field}' should be int64, got {type(value).__name__}")
        elif expected_type == 'string':
            if not isinstance(value, str):
                errors.append(f"Field '{rule.field}' should be string, got {type(value).__name__}")
        elif expected_type == 'boolean':
            if not isinstance(value, bool):
                errors.append(f"Field '{rule.field}' should be boolean, got {type(value).__name__}")

        # Check allowed values
        if rule.allowed_values is not None and value not in rule.allowed_values:
            errors.append(
                f"Field '{rule.field}' value '{value}' not in allowed values: {rule.allowed_values}"
            )

        # Check min/max for numeric values
        if rule.min_value is not None and isinstance(value, (int, float)):
            if value < rule.min_value:
                errors.append(f"Field '{rule.field}' value {value} below minimum {rule.min_value}")

        if rule.max_value is not None and isinstance(value, (int, float)):
            if value > rule.max_value:
                errors.append(f"Field '{rule.field}' value {value} above maximum {rule.max_value}")

    return errors
