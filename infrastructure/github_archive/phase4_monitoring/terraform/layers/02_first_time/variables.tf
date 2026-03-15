variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, test, staging, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "test", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, test, staging, prod"
  }
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "dashboard_sa_email" {
  description = "Email of the pipeline dashboard service account"
  type        = string
}

variable "pipeline_logs_dataset_id" {
  description = "BigQuery dataset ID for pipeline logs"
  type        = string
}
