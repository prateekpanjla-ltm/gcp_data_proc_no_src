terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {
    bucket = "beaming-glyph-489707-b8-terraform-state"
    prefix = "terraform/state/phase3-static"
  }
  # Using local backend for development
}

provider "google" {
  project         = var.project_id
  region          = var.region
  request_timeout = "120s"
}

data "google_project" "current" {
  project_id = var.project_id
}
