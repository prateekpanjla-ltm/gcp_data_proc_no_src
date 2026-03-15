# =============================================================================
# Variables: Layer 03 Operational (Cloud Functions 2nd gen)
# =============================================================================

variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Environment name (dev, test, staging, prod)"
  type        = string
  default     = "dev"
}

variable "staging_bucket_name" {
  description = "Name of the staging bucket from Phase 2 (trigger source)"
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

# =============================================================================
# Function Configuration
# =============================================================================

variable "function_memory" {
  description = "Memory allocated to the function"
  type        = string
  default     = "256M"
}

variable "function_timeout" {
  description = "Function timeout in seconds"
  type        = number
  default     = 120
}

variable "max_instances" {
  description = "Maximum number of function instances"
  type        = number
  default     = 10
}

variable "delete_after_load" {
  description = "Delete source file after successful BigQuery load"
  type        = bool
  default     = false
}
