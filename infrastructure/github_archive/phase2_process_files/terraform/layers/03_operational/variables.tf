# Layer 03: Operational Variables

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

variable "image_tag" {
  description = "Docker image tag to deploy"
  type        = string
  default     = "latest"
}

variable "file_size_threshold_mb" {
  description = "File size threshold for splitting (in MB)"
  type        = number
  default     = 50

  validation {
    condition     = var.file_size_threshold_mb >= 50
    error_message = "File size threshold must be at least 50 MB"
  }
}

variable "processor_memory" {
  description = "Memory for processor service (in GiB)"
  type        = number
  default     = 4

  validation {
    condition     = var.processor_memory >= 1 && var.processor_memory <= 32
    error_message = "Memory must be between 1 and 32 GiB"
  }
}

variable "processor_cpu" {
  description = "CPU for processor service"
  type        = number
  default     = 2

  validation {
    condition     = var.processor_cpu >= 1 && var.processor_cpu <= 8
    error_message = "CPU must be between 1 and 8"
  }
}

variable "max_instances" {
  description = "Maximum number of Cloud Run instances"
  type        = number
  default     = 5

  validation {
    condition     = var.max_instances >= 1 && var.max_instances <= 100
    error_message = "Max instances must be between 1 and 100"
  }
}

variable "chunksize" {
  description = "Number of records per chunk for processing"
  type        = number
  default     = 100000

  validation {
    condition     = var.chunksize >= 10000 && var.chunksize <= 1000000
    error_message = "Chunksize must be between 10,000 and 1,000,000"
  }
}

variable "eventarc_ack_deadline_seconds" {
  description = "Pub/Sub acknowledgement deadline for Eventarc trigger (max 600 seconds)"
  type        = number
  default     = 600

  validation {
    condition     = var.eventarc_ack_deadline_seconds >= 10 && var.eventarc_ack_deadline_seconds <= 600
    error_message = "Eventarc ack deadline must be between 10 and 600 seconds"
  }
}
