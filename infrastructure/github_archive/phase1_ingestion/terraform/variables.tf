# Variables for Phase 1: GitHub Archive Ingestion

variable "project_id" {
  description = "Google Cloud Project ID"
  type        = string
}

variable "region" {
  description = "Google Cloud Region"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Environment name (dev, test, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "staging", "prod"], var.environment)
    error_message = "Environment must be either 'dev', 'test', 'staging', or 'prod'."
  }
}

variable "force_destroy" {
  description = "Force destroy buckets even if they contain objects (dev only)"
  type        = bool
  default     = false
}

variable "bucket_lifecycle_days" {
  description = "Number of days before landing bucket files are deleted"
  type        = number
  default     = 6

  validation {
    condition     = var.bucket_lifecycle_days >= 1
    error_message = "Lifecycle days must be at least 1."
  }
}

variable "deployer_sa_key_path" {
  description = "The path to the JSON key file for the deployer service account, used for local-exec authentication."
  type        = string
}
