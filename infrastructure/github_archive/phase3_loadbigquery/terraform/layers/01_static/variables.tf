# Layer 01: Static Variables
# These resources rarely change after initial deployment

variable "project_id" {
  description = "Google Cloud Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Environment name (dev/prod)"
  type        = string

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be dev or prod"
  }
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

variable "partition_expiration_days" {
  description = "Partition expiration in days (0 = no expiration)"
  type        = number
  default     = 366

  validation {
    condition     = var.partition_expiration_days >= 0
    error_message = "Partition expiration must be >= 0"
  }
}

variable "kms_key_name" {
  description = "KMS key for BigQuery encryption (optional)"
  type        = string
  default     = null
}
