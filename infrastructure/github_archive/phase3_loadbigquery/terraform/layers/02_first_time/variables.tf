# =============================================================================
# Variables: Layer 02 First-time
# =============================================================================

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, prod)"
  type        = string
}

variable "staging_bucket_name" {
  description = "Name of the staging bucket from Phase 2"
  type        = string
}

variable "dataset_id" {
  description = "BigQuery dataset ID"
  type        = string
  default     = "github_archive"
}

variable "table_id" {
  description = "BigQuery table ID"
  type        = string
  default     = "github_events"
}

