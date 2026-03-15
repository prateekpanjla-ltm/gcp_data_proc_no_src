# Layer 01: Static Variables

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
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "Environment must be dev or prod"
  }
}

variable "landing_bucket_name" {
  description = "Name of the landing bucket from Phase 1"
  type        = string
}

variable "staging_retention_days" {
  description = "Number of days to keep processed files in staging"
  type        = number
  default     = 30

  validation {
    condition     = var.staging_retention_days >= 1
    error_message = "Retention must be at least 1 day"
  }
}
