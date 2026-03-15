# =============================================================================
# Outputs: Layer 02 First-time
# =============================================================================

output "staging_viewer_role_configured" {
  description = "Whether staging viewer IAM was configured"
  value       = google_storage_bucket_iam_member.bq_loader_staging_viewer != null
}
