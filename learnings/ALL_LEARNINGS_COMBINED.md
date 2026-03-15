# All Learnings — Combined Reference

> This document consolidates all learning files from the project (21 from learnings/ + 6 from other directories).
> Items flagged with **⚠️ INACCURACY** have been identified as potentially incorrect and need review.

---

# Table of Contents

1. [Cloud Run Billing Optimization](#1-cloud-run-billing-optimization)
2. [Cloud Run Service Accounts](#2-cloud-run-service-accounts)
3. [Cloud Build Local Permissions](#3-cloud-build-local-permissions)
4. [Dev Code Change Live Deployment](#4-dev-code-change-live-deployment)
5. [External Integration Timezone Handling](#5-external-integration-timezone-handling)
6. [GitHub Actions CI Issues](#6-github-actions-ci-issues)
7. [Google Service Agents](#7-google-service-agents)
8. [IAM Permission Testing](#8-iam-permission-testing)
9. [IAM Propagation Fix](#9-iam-propagation-fix)
10. [Mermaid Diagram Rendering Issues](#10-mermaid-diagram-rendering-issues)
11. [Open Questions](#11-open-questions)
12. [Phase 1 Deployment Issues](#12-phase-1-deployment-issues)
13. [Phase 2 blob.reload() 403 Error](#13-phase-2-blobreload-403-error)
14. [Phase 2 Cloud Run v2 Errors](#14-phase-2-cloud-run-v2-errors)
15. [Phase 2 Null Handling Validation](#15-phase-2-null-handling-validation)
16. [Phase 2 Test Project Deployment Errors](#16-phase-2-test-project-deployment-errors)
17. [Phase 3 Cloud Functions Deployment](#17-phase-3-cloud-functions-deployment)
18. [Phase 3 Test Project Deployment Errors](#18-phase-3-test-project-deployment-errors)
19. [Phase 4 Deployment Issues](#19-phase-4-deployment-issues)
20. [Terraform Destroy Test Project](#20-terraform-destroy-test-project)
21. [Terraform Request Timeout](#21-terraform-request-timeout)
22. [How IAM Permissions Work](#22-how-iam-permissions-work)
23. [GCR vs GAR Permissions](#23-gcr-vs-gar-permissions)
24. [Missing Permissions During Deployment](#24-missing-permissions-during-deployment)
25. [Data Pipeline Issues and Fixes (Emulators, Pandas, Memory)](#25-data-pipeline-issues-and-fixes)
26. [Cost Optimization and Free Tier Limits](#26-cost-optimization-and-free-tier-limits)
27. [Why Editor Role is Problematic](#27-why-editor-role-is-problematic)

---

# 1. Cloud Run Billing Optimization

**Source:** `cloud_run_billing_optimization.md`

## Problem

Billing analysis (March 1-15, 2026) showed Cloud Run as the #1 cost driver at ₹710/15 days (~₹1,420/month projected). The services were using **instance-based billing** (`cpu_idle = false`), meaning CPU and memory were charged even when idle.

### Cost breakdown (Cloud Run only):
| SKU | Usage | Cost (₹) |
|-----|-------|----------|
| Services CPU (Instance-based) | 321,191 seconds (~89 hrs) | 525.87 |
| Services Memory (Instance-based) | 615,110 GiB-seconds | 111.90 |
| Services CPU (Request-based) | 27,887 seconds | 60.88 |
| Jobs CPU | 17,220 seconds | 28.19 |
| Services Memory (Request-based) | 53,470 GiB-seconds | 12.16 |
| Jobs Memory | 8,610 GiB-seconds | 1.57 |

Instance-based billing accounted for ₹637.77 (90% of Cloud Run costs).

## Root Cause

The terraform config had `cpu_idle = false` for both Cloud Run services:
- **Phase 2 processor**: `cloud_run_service.tf` line 66 and `layers/03_operational/main.tf` line 121
- **Phase 4 dashboard**: `layers/03_operational/main.tf` — no `cpu_idle` set (defaults to `false`)

## Instance-based vs Request-based Billing

| Aspect | Instance-based (`cpu_idle = false`) | Request-based (`cpu_idle = true`) |
|--------|-------------------------------------|-----------------------------------|
| **CPU charging** | Always, even when idle | Only during request processing |
| **Memory charging** | Always, even when idle | Always (memory can't be throttled) |
| **Cold start** | None — instances always warm | 2-5 seconds after idle period |
| **Performance** | Consistent, no cold starts | Variable, depends on idle time |
| **Cost** | High for infrequent traffic | Low for infrequent traffic |
| **Best for** | High-traffic, latency-sensitive | Hourly batch jobs, dashboards |

## Fix

Changed `cpu_idle = false` → `cpu_idle = true` in 3 terraform files:
1. `infrastructure/github_archive/phase2_process_files/terraform/cloud_run_service.tf`
2. `infrastructure/github_archive/phase2_process_files/terraform/layers/03_operational/main.tf`
3. `infrastructure/github_archive/phase4_monitoring/terraform/layers/03_operational/main.tf`

## Impact Analysis

### Phase 2 Processor
- Pipeline runs hourly → 1 cold start per hour (2-5 seconds)
- Processing takes ~30 seconds per file → cold start adds <15% overhead
- Eventarc ack deadline is 600 seconds → plenty of margin for cold start
- **Memory-intensive processing**: `cpu_idle = true` still allocates full CPU during request. The `cpu_idle` flag only affects CPU between requests, not during.

### Phase 4 Dashboard
- Accessed infrequently (manual viewing)
- 2-5 second cold start is acceptable for a monitoring dashboard
- Scales to 0 when not in use → near-zero cost

## Cloud Run Free Tier (per month)
- 2 million requests
- 180,000 vCPU-seconds
- 360,000 GiB-seconds
- 1 GiB network egress (North America)

Our usage exceeded the free tier with instance-based billing but should stay within with request-based billing.

## Other Billing Observations

From the same billing report, services NOT from our pipeline:
- **Cloud SQL (₹34.60)**: PostgreSQL micro instance — likely from dev-dataprocessing project
- **Networking Intelligence Center (₹19.37)**: Resource monitoring — not from our pipeline
- **Compute Engine (₹34.10 charged, ₹34.10 discount)**: Free tier covers it
- **Gemini API (₹0.02)**: Minimal API usage

The billing CSV covers the **entire billing account** (all projects), not just the test project. Filter by project ID in the billing console for project-specific costs.

---

# 2. Cloud Run Service Accounts

**Source:** `cloud_run_service_accounts.md`

## Overview

Cloud Run involves **two different service accounts** that are often confused:

| Service Account | Type | Created By | Email Format | Purpose |
|-----------------|------|------------|--------------|---------|
| **Service Agent** | Google-managed | Google (auto) | `service-NUMBER@serverless-robot-prod.iam.gserviceaccount.com` | Pull images, manage infra |
| **Service Identity** | User-managed | You | `NAME@PROJECT_ID.iam.gserviceaccount.com` | Your code's permissions |

## Service Agent (Google-Managed)

**You CANNOT create your own.** This is automatically created when you enable Cloud Run API.

**Purpose:**
- Pulls container images from Artifact Registry
- Manages revisions and scaling
- Handles internal Cloud Run operations

**Permissions needed:**
- `roles/artifactregistry.reader` - to pull images (auto-granted in same project)
- `roles/run.serviceAgent` - auto-granted by Google

## Service Identity (User-Managed)

**You SHOULD create your own.** This is the service account that runs INSIDE your container.

**Purpose:**
- Your application code uses this to access Google Cloud resources
- Permissions are based on what your app needs (GCS, BigQuery, etc.)

**Example:** `dev-github-archive-processor@PROJECT_ID.iam.gserviceaccount.com`

**Typical permissions for data processing:**
- `roles/storage.objectViewer` - read input files
- `roles/storage.objectCreator` - write output files
- `roles/logging.logWriter` - write logs
- `roles/monitoring.metricWriter` - write metrics

## Common Errors

### Error: Container Cannot Access Resources

**Error Message:**
```
403 Your service account does not have storage.objects.get access
```

**Root Cause:** Your Service Identity (not Service Agent) is missing permissions.

**Fix:** Grant the required role (e.g., `roles/storage.objectViewer`) to your Service Identity.

## Summary

| Question | Answer |
|----------|--------|
| Can I create my own Service Agent? | NO - Google-managed only |
| Can I create my own Service Identity? | YES - Recommended |
| Does Service Agent need Artifact Registry access? | Auto-granted in same project |
| Does Service Identity need Artifact Registry access? | NO - Agent handles this |

## References

- [Cloud Run Service Identity](https://cloud.google.com/run/docs/securing/service-identity)
- [Service Account Types](https://cloud.google.com/iam/docs/service-account-types)

---

# 3. Cloud Build Local Permissions

**Source:** `cloudbuild_local_permissions.md`

## The Issue

When running `gcloud builds submit` from a local machine, you may encounter multiple permission errors:

```
# Error 1: Storage permissions
ERROR: could not resolve source: googleapi: Error 403:
973986259857-compute@developer.gserviceaccount.com does not have
storage.objects.get access to the Google Cloud Storage object.

# Error 2: Artifact Registry permissions (pulling base images)
Permission "artifactregistry.repositories.downloadArtifacts" denied on resource "projects/google.com:cloud-sdk"

# Error 3: Build permissions
ERROR: (gcloud.builds.submit) PERMISSION_DENIED: Request had insufficient authentication scopes
```

## Root Cause

**Cloud Build changed its default service account in mid-2024:**

| Before (Legacy) | After (Current) |
|------------------|-----------------|
| Cloud Build SA (`@cloudbuild.gserviceaccount.com`) | **Compute Engine SA** (`@compute@developer.gserviceaccount.com`) |

The new default Compute Engine SA has **minimal permissions** by default and must be granted explicit permissions for Cloud Build operations.

## How It Works: Two Service Accounts

```
┌─────────────────────────────────────────────────────────────────┐
│           gcloud builds submit (from your laptop)              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   1. YOUR Personal Account (authentication)                    │
│      └── your-email@gmail.com                                 │
│         (logged in via `gcloud auth login`)                   │
│                              ↓                                  │
│   2. Cloud Build API receives your request                       │
│                              ↓                                  │
│   3. Cloud Build EXECUTES the build using:                    │
│      └── {PROJECT_NUMBER}-compute@developer.gserviceaccount.com │
│         (Project's Compute Engine Service Account)              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Key Point:** Your personal account authenticates to Cloud Build, but Cloud Build uses a **project-level service account** to execute the build.

## Complete Required Permissions for Container Builds

When running `gcloud builds submit` for Docker image builds, the Compute Engine SA needs:

| Role | Purpose | Status |
|------|---------|--------|
| `roles/storage.objectAdmin` | Upload source to GCS staging bucket | Required |
| `roles/artifactregistry.reader` | Pull base images (e.g., `gcr.io/google.com/cloud-sdk:slim`) | Required |
| `roles/cloudbuild.builds.builder` | Push images, create builds, execute all Cloud Build operations | **Comprehensive** |

**Recommended Approach:** Grant `roles/cloudbuild.builds.builder` which includes:
- `artifactregistry.repositories.downloadArtifacts` - Pull images
- `artifactregistry.repositories.uploadArtifacts` - Push images
- `artifactregistry.repositories.createOnPush` - Auto-create repo on push
- `storage.objects.create/get/list/update` - GCS operations
- `cloudbuild.builds.create` - Create builds
- `logging.logEntries.create` - Write logs

## The Fix (Complete)

Grant all required roles to the Compute Engine service account:

```bash
PROJECT_ID="your-project-id"
PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')
COMPUTE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# Option 1: Grant individual roles (for least privilege)
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:${COMPUTE_SA}" \
  --role="roles/storage.objectAdmin"

gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:${COMPUTE_SA}" \
  --role="roles/artifactregistry.reader"

# Option 2: Grant the comprehensive Cloud Build role (RECOMMENDED)
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
  --member="serviceAccount:${COMPUTE_SA}" \
  --role="roles/cloudbuild.builds.builder"
```

## Permissions Breakdown by Build Stage

| Stage | Operation | Required Permission | Role |
|-------|-----------|-------------------|------|
| Source Upload | `gcloud builds submit` uploads source to GCS | `storage.objects.create` | `storage.objectAdmin` or `cloudbuild.builds.builder` |
| Pull Base Image | Docker pulls `gcr.io/google.com/cloud-sdk:slim` | `artifactregistry.repositories.downloadArtifacts` | `artifactregistry.reader` or `cloudbuild.builds.builder` |
| Pull Builder | Docker pulls `gcr.io/cloud-builders/docker` | `artifactregistry.repositories.downloadArtifacts` | Same as above |
| Build Image | Docker build executes | (local to build worker) | N/A |
| Push Image | Docker pushes to `gcr.io/$PROJECT_ID/...` | `artifactregistry.repositories.uploadArtifacts` | `cloudbuild.builds.builder` |
| Create Repo | Auto-create on first push | `artifactregistry.repositories.createOnPush` | `cloudbuild.builds.builder` |
| Logging | Write build logs | `logging.logEntries.create` | `cloudbuild.builds.builder` |

## References

- [Cloud Build Service Account](https://cloud.google.com/build/docs/cloud-build-service-account)
- [Cloud Build Permissions](https://cloud.google.com/iam/docs/roles-permissions#cloudbuild)
- [Google Cloud CLI Docker Images](https://cloud.google.com/sdk/docs/downloads-docker)
- [Migrating Docker Images](https://cloud.google.com/sdk/docs/migrate-docker-images)

---

# 4. Dev Code Change Live Deployment

**Source:** `dev_code_change_live.md`

**Date**: 2026-03-09

## Summary

This document captures a combined deployment that:
1. Added ETL metadata columns (`etl_create_ts`, `etl_create_id`) to track data lineage
2. Changed staging file deletion from immediate to 2-day lifecycle retention

## Services Overview

| Service | Type | Name | Trigger Name | Purpose |
|---------|------|------|--------------|---------|
| Phase 2 | Cloud Run | `dev-github-archive-processor` | `dev-github-archive-storage` | Process raw GitHub Archive files |
| Phase 3 | Cloud Function 2nd gen | `dev-bq-loader` | `dev-bq-loader-199448` | Load processed files to BigQuery |

**Data Flow:**
```
Landing Bucket → Phase 2 Cloud Run → Staging Bucket → Phase 3 Cloud Function → BigQuery
```

## Changes Made

### 1. BigQuery Schema Change (ALTER TABLE)

**Rationale**: Add columns to existing table without data loss. Using `ALTER TABLE` instead of recreating the table preserves 2.5M+ existing rows.

```sql
ALTER TABLE `dev-dataprocessing-489305.github_archive.github_events`
ADD COLUMN IF NOT EXISTS etl_create_ts TIMESTAMP OPTIONS(description='Timestamp when Phase 2 processor created this record');

ALTER TABLE `dev-dataprocessing-489305.github_archive.github_events`
ADD COLUMN IF NOT EXISTS etl_create_id STRING OPTIONS(description='ETL processor identifier');
```

### 2. Terraform Schema Update (schema.json)

**File**: `infrastructure/github_archive/phase3_loadbigquery/terraform/layers/01_static/schema.json`

### 3. Phase 2 Transformer Update (transformer.py)

**File**: `src/github_archive/phase2_process_files/processors/transformer.py`

```python
# Add ETL metadata columns
result['etl_create_ts'] = pd.Timestamp.now(tz='UTC')
result['etl_create_id'] = "GITHUB_PROCESSOR"
```

### 4. Phase 3 Variable Update (variables.tf)

Changed `delete_after_load` default from `true` to `false`.

## Why We Didn't Pause Eventarc Triggers

**Investigation Result**: Eventarc triggers cannot be directly paused via gcloud.

**Decision**: Proceed without pausing triggers because:
1. **Backward Compatibility**: Phase 3 uses `ignore_unknown_values=True` in BigQuery load jobs
2. **ALTER TABLE is Instant**: The schema change completes in < 1 second
3. **Low Risk**: Adding NULLABLE columns is non-breaking

## Deployment Order (Critical)

1. **ALTER TABLE** - Adds columns to BigQuery (instant, no impact)
2. **Update schema.json** - Terraform state sync
3. **Update transformer.py** - Phase 2 starts writing new columns
4. **Update variables.tf** - Phase 3 stops deleting files
5. **Deploy Phase 2** - Cloud Run gets new transformer code
6. **Deploy Phase 3** - Cloud Function gets new environment variable

## Lessons Learned

1. **Eventarc triggers cannot be paused** - Must accept risk or use destructive methods
2. **`ignore_unknown_values=True` is a safety net** - Allows schema evolution without coordination
3. **ALTER TABLE ADD COLUMN is instant** - No need for complex migration strategies
4. **Terraform schema must match actual table** - Prevents state drift
5. **NULLABLE columns are backward compatible** - Existing rows get NULL values automatically

---

# 5. External Integration Timezone Handling

**Source:** `external_integration_timezone_handling.md`

## Key Learnings

### 1. Always Use UTC for Time Calculations

External APIs typically use UTC as their canonical timezone.

**Example - Cloud Scheduler:**
```hcl
resource "google_cloud_scheduler_job" "github_archive_download" {
  schedule    = "30 * * * *"  # 30 minutes past each hour
  time_zone   = "UTC"         # Always specify UTC
}
```

### 2. Hour Precision Matters

| Format | Example | Correct? |
|--------|---------|----------|
| `{YYYY}-{MM}-{DD}.json.gz` | `2026-03-05.json.gz` | Missing hour |
| `{YYYY}-{MM}-{DD}-{HH}.json.gz` | `2026-03-05-12.json.gz` | Correct |

### 3. Date Format String Bugs Are Subtle

```bash
# WRONG - Missing %d (day) in format string
TARGET_HOUR=$(date -u -d "1 hour ago" '+%Y-%m-%-H')
# Produces: 2026-03-12.json.gz (hour 12 interpreted as day!)

# CORRECT - Include %d for day
TARGET_HOUR=$(date -u -d "1 hour ago" '+%Y-%m-%d-%-H')
# Produces: 2026-03-05-12.json.gz
```

### 4. File Availability Timing

| Scenario | File Status | Action |
|----------|-------------|--------|
| Current hour (in progress) | 404 Not Found | Wait, use `HOURS_AGO=1` |
| Previous hour | Usually available | Safe to download |
| 2+ hours ago | Always available | Safe to download |

```bash
# Schedule at minute 30 of each hour
schedule: "30 * * * *"  # :30 past each hour in UTC
```

### 5. Cross-Platform Date Compatibility

| Platform | Date Command | Hour Format |
|----------|--------------|-------------|
| Linux (GNU) | `date -d "1 hour ago"` | `%-H` (no leading zero) |
| macOS (BSD) | `date -v-1H` | `%H` (leading zero) |

## References

- [GitHub Archive - Data Format](https://www.gharchive.org/)
- [Google Cloud Scheduler - Time Zones](https://cloud.google.com/scheduler/docs/configuring/cron-job-schedules#time_zones)

---

# 6. GitHub Actions CI Issues

**Source:** `github_actions_ci_issues.md`

## Issue 1: Workflow doesn't trigger on first push

**Problem**: GitHub requires the workflow file to already exist on the branch before a push triggers it.

**Fix**: Push the branch first, then make a second push (even an empty commit) to trigger.

## Issue 2: GCP_SA_KEY_BASE64 secret — decode failure

**Fix**: Removed `auth@v2` action. Decode base64 to file and use `gcloud auth activate-service-account --key-file`.

## Issue 3: Deploy script can't find key file

**Fix**: Added fallback to `GOOGLE_APPLICATION_CREDENTIALS` env var in deploy/destroy scripts.

## Issue 4: Scripts not executable

**Problem**: Bash scripts committed from Windows have `100644` permissions. GitHub runner can't execute them.

**Fix**: `git update-index --chmod=+x` and `chmod +x` in workflow.

## Issue 5: `gcloud beta` not installed on GitHub runner

**Fix**: Added `--quiet` flag to all `gcloud beta` commands for non-interactive install.

## Issue 6: PowerShell not available on GitHub runner

> **⚠️ INACCURACY: GitHub Ubuntu runners DO have PowerShell (`pwsh`) pre-installed. The actual issue was using `interpreter = ["powershell", "-Command"]` which is Windows-specific syntax. The cross-platform equivalent is `interpreter = ["pwsh", "-Command"]`. Regardless, converting to bash was the right fix for portability.**

**Problem**: All terraform `null_resource` provisioners used `interpreter = ["powershell", "-Command"]`. GitHub runners (ubuntu-latest) don't have PowerShell by default.

**Fix**: Converted all 6 PowerShell provisioners to bash using `interpreter = ["bash", "-c"]` and heredoc syntax.

## Issue 7: Terraform state lost between CI runs

**Fix**: Switched from local backend to GCS remote backend:
```hcl
backend "gcs" {
  bucket = "beaming-glyph-489707-b8-terraform-state"
  prefix = "terraform/state/phase1-ingestion"
}
```

## Issue 8: schema.json not in git (gitignored by *.json)

**Fix**: Added exceptions to `.gitignore`:
```
!**/schema.json
!**/.terraform.lock.hcl
```

## Issue 9: Terraform state lock conflict from parallel runs

**Fix**: Added concurrency control:
```yaml
concurrency:
  group: gh-archive-deploy-${{ github.ref }}
  cancel-in-progress: true
```

## Issue 10: `data.terraform_remote_state` still using local backend

**Fix**: Updated all `data.terraform_remote_state` blocks to use GCS.

## GitHub Actions Concurrency Control — Deep Dive

```yaml
concurrency:
  group: gh-archive-deploy-${{ github.ref }}
  cancel-in-progress: true
```

- **Group key**: All pushes to the same branch share the same concurrency group
- **cancel-in-progress: true**: Cancels the currently running workflow and starts the new one
- **Why cancel** (not queue): Old run deploys based on old code; terraform state locks would block; saves CI minutes

### When NOT to use `cancel-in-progress`
- **Destroy workflows**: Never cancel a destroy mid-way
- **Prod deployments**: May want to queue instead of cancel

## Terraform null_resource — Phantom Additions/Deletions

`null_resource` with `triggers = { always_run = timestamp() }` shows as "1 added, 1 destroyed" every apply — this is just state churn, no GCP infrastructure changes.

## GitHub Runner Environment

- OS: Ubuntu (latest)
- Python: pre-installed
- gcloud: installed via `google-github-actions/setup-gcloud@v2`
- terraform: installed via `hashicorp/setup-terraform@v3`
- PowerShell: **NOT available** by default (⚠️ INACCURACY — `pwsh` IS pre-installed)
- `gcloud beta`: **NOT pre-installed** — needs `--quiet` flag for auto-install

---

# 7. Google Service Agents

**Source:** `google_service_agents.md`

## The Problem

```
Error: Service account service-PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com does not exist.
Error: Service account service-PROJECT_NUMBER@gcp-sa-eventarc.iam.gserviceaccount.com does not exist.
```

## Root Cause

**Google-managed service agents are NOT created automatically when APIs are enabled.** They are activated lazily — when first used or when you explicitly request the service agent's name.

## Solution: Explicitly Activate Service Agents

### 1. Cloud Storage Service Agent

```bash
gcloud storage service-agent --project=PROJECT_ID
```

Grant required role:
```bash
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:service-PROJECT_NUMBER@gs-project-accounts.iam.gserviceaccount.com" \
  --role="roles/pubsub.publisher"
```

### 2. Eventarc Service Agent

```bash
gcloud beta services identity create --service=eventarc.googleapis.com --project=PROJECT_ID
```

## Terraform Considerations

### The `depends_on` Pitfall

`depends_on` only waits for the `google_project_service` resource to report "created". It does NOT wait for the service agent accounts to actually be provisioned.

**Solutions:**
1. Pre-activate service agents before running Terraform
2. Add `time_sleep` resource (60s)
3. Use `null_resource` with `local-exec` to activate

## Common Service Agents

| Service Agent | Role Needed | Purpose |
|---------------|-------------|---------|
| `service-NUMBER@gs-project-accounts.iam.gserviceaccount.com` | `roles/pubsub.publisher` | Cloud Storage → Pub/Sub notifications |
| `service-NUMBER@gcp-sa-eventarc.iam.gserviceaccount.com` | `roles/eventarc.eventReceiver` | Eventarc event receiver |
| `service-NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com` | `roles/pubsub.serviceAgent` | Pub/Sub service agent |
| `service-NUMBER@serverless-robot-prod.iam.gserviceaccount.com` | `roles/run.serviceAgent` | Cloud Run service agent |
| `service-NUMBER@gcp-sa-artifactregistry.iam.gserviceaccount.com` | `roles/artifactregistry.serviceAgent` | Artifact Registry service agent |

## Eventarc: Pub/Sub Service Agent Token Creator Permission

When using Eventarc to trigger authenticated Cloud Run services, the Pub/Sub service agent needs `roles/iam.serviceAccountTokenCreator` on the Eventarc invoker service account to generate OIDC tokens.

**Important:** This is **service account IAM** (granted on the SA), not project IAM.

## References

- [Cloud Storage Service Agents](https://cloud.google.com/storage/docs/projects)
- [IAM Service Agents](https://cloud.google.com/iam/docs/service-agents)

---

# 8. IAM Permission Testing

**Source:** `iam_permission_testing.md`

## Method 1: `gcloud policy-troubleshoot iam` (Recommended)

**Required API**: `policytroubleshooter.googleapis.com` (free to use)

**Important**: To test permissions **as the service account**, BOTH flags are required:

```bash
gcloud policy-troubleshoot iam //cloudresourcemanager.googleapis.com/projects/PROJECT_ID \
  --permission="iam.serviceAccounts.create" \
  --principal-email="SA_EMAIL" \
  --impersonate-service-account="SA_EMAIL"
```

**What each flag does**:
- `--principal-email` = Which principal's permissions to CHECK (required)
- `--impersonate-service-account` = Which principal's CREDENTIALS to use for the API call (optional but recommended)

## Method 2: Check Granted Roles (Simpler, No Extra API)

```bash
gcloud projects get-iam-policy PROJECT_ID \
  --format="flattened(bindings)" \
  --filter="bindings.member:serviceAccount:SA_EMAIL"
```

## Method 3: Actual Test (Creates Real Resource)

**Warning**: This actually creates resources. Use only in test environments.

---

# 9. IAM Propagation Fix

**Source:** `iam_propagation_fix.md`

**Date:** 2026-03-13

## Problem

Cloud Build step failed with 403 after IAM binding was created — `storage.objects.get` denied.

## Root Cause

**IAM eventual consistency.** GCP IAM has two layers:

1. **Control plane** — records the policy. API calls return immediately.
2. **Enforcement layer** — actually checks permissions. Can lag behind by up to 60 seconds.

Terraform's `depends_on` only waits for the control plane, not enforcement.

## Key Discovery: testIamPermissions API

The `testIamPermissions` API tests against the **enforcement layer**, not the control plane:

```bash
curl -H "Authorization: Bearer $(gcloud auth print-access-token --impersonate-service-account=SA)" \
  "https://storage.googleapis.com/storage/v1/b/BUCKET/iam/testPermissions?permissions=storage.objects.get"
```

## Fix Applied

Added `wait_for_iam_propagation` resource that polls `testIamPermissions` every 10 seconds (up to 120s) before the build step runs.

## Lessons

1. **GCP IAM is eventually consistent.** Never assume permissions are enforced immediately.
2. **`testIamPermissions` tests enforcement, not policy.**
3. **`depends_on` is not enough** for IAM-dependent operations.
4. **Use proper error handling in `local-exec`.**

---

# 10. Mermaid Diagram Rendering Issues

**Source:** `mermaid_diagram_rendering_issues.md`

## Key Rules

- **Special characters** (`()`, `[]`, `{}`, `&`, `#`, `?`) in node text must be wrapped in double quotes
- Use `<br>` (not `<br/>`) for line breaks
- Prefer `graph` over `flowchart` when using subgraphs for maximum compatibility

## Common Special Characters Requiring Quotes

| Character | Example | Solution |
|-----------|---------|----------|
| `{` `}` | `{filename}` | `["Text {filename}"]` |
| `(` `)` | `(project)` | `["Text (project)"]` |
| `?` | `Status = 200?` | `{Status = 200?}` (diamond node) |
| `:` in URL | `https://...` | `["URL text"]` |

---

# 11. Open Questions

**Source:** `open_questions.md`

## Cloud Functions Revisions for DevOps Flow

**Question:** Is it possible to use Cloud Functions revisions for safer operational deployment (traffic splitting/blue-green) in our data processing scenario?

**Notes:**
- Investigate Cloud Functions 2nd gen + revisions
- Compare with Cloud Run deployment strategies

---

# 12. Phase 1 Deployment Issues

**Source:** `phase1_deployment_issues.md`

## Issue 1: Terraform Schema Errors in `google_cloud_run_v2_job`

| Incorrect | Correct |
|-----------|---------|
| `service_account_name` | `service_account` |
| `timeout_seconds = 1800` | `timeout = "1800s"` |

## Issue 2: `google_cloud_run_v2_job_iam_member` uses `name` not `job_name`

## Issue 3: Cloud Scheduler `retry_config` uses `min_backoff_duration` not `min_backoff`

## Issue 4: Cloud Run v2 Memory Requirement

Cloud Run v2 (gen2 execution environment) requires **minimum 512Mi memory** when CPU is allocated (unthrottled).

## Issue 5: gsutil Does Not Support HTTP/HTTPS URLs

gsutil `cp` only supports `gs://` URLs and local file paths.

**Fix**: Use `curl` for HTTP download, pipe to `gsutil cp` for GCS upload:
```bash
curl -fsSL "${SOURCE_URL}" | gsutil cp - "${TARGET_PATH}"
```

## Issue 6: Deployment Script Target Flag Syntax

Each target needs its own `-target=` flag:
```bash
-target=resource1 -target=resource2 -target=resource3
```

## Issue 7: Cloud Scheduler 401 UNAUTHENTICATED - OIDC vs OAuth

| Token Type | Use Case | Target URL Pattern |
|------------|----------|-------------------|
| **OAuth Token** | Google APIs (`*.googleapis.com`) | `https://*.googleapis.com/...` |
| **OIDC Token** | Cloud Run services, external endpoints | `https://*.a.run.app`, external APIs |

Cloud Run **Jobs API** is a Google API endpoint — needs OAuth, not OIDC.

## Lessons Learned

### Cloud Run v2 Has Different Requirements

| Requirement | Value |
|-------------|-------|
| Min memory (with CPU) | 512Mi |
| Min memory (without CPU) | 128Mi |
| Valid CPU values | "1", "2", "4", "6", "8" |
| Timeout format | String with "s" suffix |

---

# 13. Phase 2 blob.reload() 403 Error

**Source:** `phase2_blob_reload_403_error.md`

**Date:** 2026-03-08

## Issue 1: 403 on blob.reload() After Successful Upload

**Root Cause**: `blob.reload()` requires `storage.objects.get` permission. Called after upload to fetch blob metadata (size).

**Fix**: Wrapped in try-except in `processors/file_processor.py` — non-critical operation shouldn't fail the entire process.

## Issue 2: 403 Error When Reprocessing Existing Files

**Root Cause**: `roles/storage.objectCreator` only allows **creating NEW objects**. GCS requires `storage.objects.delete` to overwrite.

**Fix**: Changed to `roles/storage.objectAdmin`.

| Role | Create | Delete | Overwrite |
|------|--------|--------|-----------|
| `objectCreator` | Yes | No | No |
| `objectViewer` | No | No | No |
| `objectAdmin` | Yes | Yes | Yes |

---

# 14. Phase 2 Cloud Run v2 Errors

**Source:** `phase2_cloud_run_v2_errors.md`

**Date:** 2026-03-06

## Cloud Run v2 vs v1 Schema Reference

| v1 (Job/old) | v2 Service |
|--------------|------------|
| `metadata { annotations }` | `annotations` (in template) |
| `container_concurrency` | `max_instance_request_concurrency` |
| `timeout_seconds` (number) | `timeout` (string with "s") |
| `resources { limits, requests }` | `resources { limits, cpu_idle }` |
| Autoscaling annotations | `scaling { min/max_instance_count }` |

## Error 5: Reserved Environment Variable `PORT`

`PORT` is automatically set by Cloud Run. Remove it from your container config.

**Reserved Variables:** `PORT`, `K_CONFIGURATION`, `K_REVISION`, `K_SERVICE`

## Error 6: Quota Exceeded - Max Instances

**Default Quotas (varies by project/region):**
| Quota | Default |
|-------|---------|
| CPU | 20 vCPUs |
| Memory | 40 GiB |

## Error 9-10: Container Failed to Start / Module Not Found

Multi-stage Dockerfile issue — packages installed as root but container runs as `appuser`.

**Fix**: Copy packages to `/usr/local` (accessible to all users) instead of `/root/.local`.

## Error 14: Single-Digit Hours in Filename

GitHub Archive uses `H` not `HH`:
- Single digit (0-9) for hours 0-9
- Double digit (10-23) for hours 10-23

**Fix**: Regex `\d{2}` → `\d{1,2}`

## Error 16: Eventarc Pub/Sub Ack Deadline Too Short

Default ack deadline is **10 seconds**. Processing takes minutes → Pub/Sub redelivers → duplicate processing.

**Fix**: Increase to 600 seconds (maximum).

**Important**: This change is NOT managed by Terraform. If trigger is destroyed/recreated, deadline resets to 10s.

## Error 17: 403 Unauthenticated Requests to Cloud Run

Eventarc invoker SA needs `roles/run.invoker` on the Cloud Run service (not just `roles/eventarc.eventReceiver`).

## Error 18: Pub/Sub Service Agent Token Creator Missing

Pub/Sub SA needs `roles/iam.serviceAccountTokenCreator` on the Eventarc invoker SA to generate OIDC tokens for authenticated push.

**Required IAM for Eventarc → Authenticated Cloud Run:**

| Grant To | Role | On Target | Purpose |
|----------|------|-----------|---------|
| Pub/Sub SA | `roles/iam.serviceAccountTokenCreator` | Eventarc Invoker SA | Generate OIDC tokens |
| Eventarc Invoker SA | `roles/run.invoker` | Cloud Run Service | Invoke the service |
| Eventarc Invoker SA | `roles/eventarc.eventReceiver` | Project | Receive events |

---

# 15. Phase 2 Null Handling Validation

**Source:** `phase2_null_handling_validation.md`

## Problem

Original dtype validation counted ALL nulls after coercion as errors, without distinguishing:
1. **Source nulls** - Null values present in original JSON data
2. **Coercion nulls** - New nulls from failed dtype coercion

## Solution

Check nulls **before** and **after** coercion:

```python
source_nulls = result_df[col].isna().sum()
result_df[col] = result_df[col].astype(dtype)
nulls_after = result_df[col].isna().sum()
coercion_nulls = int(nulls_after - source_nulls)
```

**Key Insight**: Source nulls are valid JSON — only coercion failures should be errors.

---

# 16. Phase 2 Test Project Deployment Errors

**Source:** `phase2_test_project_deployment_errors.md`

**Date:** 2026-03-12

## Error 19: Cloud Build SHORT_SHA Empty for gcloud builds submit

`SHORT_SHA` is only populated for Git-triggered builds. Use `BUILD_ID` instead.

| Variable | Available When |
|----------|---------------|
| `$SHORT_SHA` | Git-triggered builds only |
| `$COMMIT_SHA` | Git-triggered builds only |
| `$BUILD_ID` | Always |
| `$PROJECT_ID` | Always |

## Error 20: Cloud Run Service Created Before Image Exists

**Fix**: Add `depends_on = [null_resource.build_processor_image]` to Cloud Run service.

## Error 21: Google-Managed Service Agents Don't Exist

Service agents are NOT created automatically via `google_project_service`. Use `gcloud beta services identity create` to initialize.

## Error 22: Eventarc GCS Events Don't Support Path Filtering

GCS direct events only support `type` and `bucket` filters. Handle path routing in application code.

## Error 23: Provider v5.x Schema Differences

| Feature | Provider 5.x | Provider 6+/7+ |
|---------|-------------|-----------------|
| `deletion_protection` | Not supported | Supported |
| `scaling {}` block | Inside `template {}` | At root level |

## Error 24: Terraform Number Literal Underscore Separators

Terraform does NOT support `100_000` — use `100000`.

---

# 17. Phase 3 Cloud Functions Deployment

**Source:** `phase3_cloud_functions_deployment.md`

## Architecture Decision: Cloud Functions vs Cloud Run

| Aspect | Cloud Run | Cloud Functions 2nd gen |
|--------|-----------|-------------------------|
| Deployment | Docker container | Source code zip |
| Event Trigger | Separate Eventarc resource | Built-in event_trigger block |
| Build | Cloud Build (Docker) | Cloud Build (source) |
| Runtime | Any language (container) | Supported runtimes only |

## Eventarc Acknowledgement Deadline

Cloud Functions 2nd gen automatically configures the Pub/Sub subscription with:

| Setting | Value |
|---------|-------|
| Acknowledgement Deadline | 600 seconds (maximum) |
| Message Retention | 24 hours |
| Retry Policy | Exponential backoff (10s to 600s) |

## IAM Requirements Summary

**For `bq_loader` service account:**
- `roles/bigquery.dataEditor` - Write to BigQuery tables
- `roles/bigquery.jobUser` - Run BigQuery load jobs
- `roles/storage.objectAdmin` - Read/delete from staging bucket
- `roles/logging.logWriter` - Write logs
- `roles/monitoring.metricWriter` - Write metrics
- `roles/artifactregistry.reader` - Read container images (Cloud Build)

**For `eventarc_invoker` service account:**
- `roles/eventarc.eventReceiver` - Receive events
- `roles/run.invoker` - Invoke Cloud Function (runs on Cloud Run)
- `roles/logging.logWriter` - Write logs

## BigQuery Schema Considerations

`created_at` must be `TIMESTAMP` type for time-based partitioning (not STRING).

---

# 18. Phase 3 Test Project Deployment Errors

**Source:** `phase3_test_project_deployment_errors.md`

**Date:** 2026-03-13

## Error 25: Missing schema.json for BigQuery Table

Generated from the Python `get_github_events_schema()` function.

## Error 26: Provider Version ~> 7.0 Lock File Conflict

Changed constraint from `~> 7.0` to `~> 5.0` and ran `terraform init -upgrade`.

## Error 27: Environment Validation Missing "test"

Added `"test"` to allowed values: `contains(["dev", "test", "prod"], var.environment)`

## Error 28: Cloud Function Using Wrong Event Format (1st gen vs 2nd gen)

| Aspect | 1st Gen | 2nd Gen |
|--------|---------|---------|
| Signature | `def fn(data, context)` | `@cloud_event def fn(cloud_event)` |
| Event data | `data` parameter directly | `cloud_event.data` |
| Event ID | `context.event_id` | `cloud_event["id"]` |
| Decorator | None needed | `@functions_framework.cloud_event` |
| Dependencies | None extra | `functions-framework`, `cloudevents` |

## Error 30: Relative Path Depth Wrong for Layered Terraform

Count directory levels carefully when using layered structures.

## Error 31: Cloud Functions Build Fails — AR Permission Denied

Cloud Functions 2nd gen uses Compute Engine default SA for builds. Fix: specify a custom build SA with `artifactregistry.writer` and `storage.objectAdmin`:

```hcl
build_config {
  service_account = "projects/${var.project_id}/serviceAccounts/${var.environment}-cloud-build@${var.project_id}.iam.gserviceaccount.com"
}
```

Note: `service_account` in `build_config` requires the **full resource name** format.

## Error 36: BQ Load Failed — Schema Generated from Wrong Source

Always verify schema source against actual pipeline output. `dtype_definitions.py` and the dev BQ table are the source of truth.

---

# 19. Phase 4 Deployment Issues

**Source:** `phase4_deployment_issues.md`

## Issue 1: Missing terraform config files

Created `terraform.tf`, `variables.tf`, and `outputs.tf` for all 3 layers.

## Issue 2: Naming convention not followed

All GCP resource names must be prefixed with `${var.environment}-`.

## Issue 3: Cloud Build requires logs bucket with custom SA

**Fix**: Added `--default-buckets-behavior=REGIONAL_USER_OWNED_BUCKET` flag.

## Issue 4: Terraform deployer SA missing logging.sinks.create permission

`roles/logging.logWriter` (write entries) is not `roles/logging.admin` (manage sinks).

## Issue 5: GOOGLE_APPLICATION_CREDENTIALS path must be absolute

Relative paths resolve from the terraform layer directory, not the repo root.

## Issue 6: SQL queries hardcoded dataset name

Replaced with `DATASET_ID` placeholder, replaced at runtime from env var.

## Issue 7: Dashboard crashes when log tables don't exist yet

Log sink auto-creates BQ tables when logs first flow. Added try/except in `_run_query()`.

## Issue 8: Phase 2 logs go to stderr, not stdout

Python's `logging` module writes to stderr by default. Changed queries to use `run_googleapis_com_stderr`.

## Issue 9: Phase 3 Cloud Function logs not in expected table

Cloud Functions 2nd gen runs on Cloud Run — logs appear in `run_googleapis_com_*`, not `cloudfunctions_googleapis_com_*`. Replaced with `INFORMATION_SCHEMA.JOBS` query.

## Issue 10-11: Dashboard SA permission issues

Needed `roles/bigquery.resourceViewer` for `INFORMATION_SCHEMA.JOBS` and `roles/bigquery.dataViewer` on `github_archive` dataset.

## Issue 13: Terraform tries to disable logging API on destroy

**Fix**: Added `disable_on_destroy = false` — logging is a shared project-level service.

## Issue 14: Null provider lock file mismatch

Run `terraform init -upgrade` after adding `null_resource` to pick up the `hashicorp/null` provider.

## Issue 15: Stale deleted SA blocks dataset IAM update

Deleted/recreated SAs leave stale IAM entries. Use `REVOKE` SQL or project-level IAM instead of dataset-level IAM.

## Issue 16: pip "Running as root" warning

**Fix**: `pip install --root-user-action=ignore`

## Issue 17: Stale terraform state after multi-layer destroy

After destroy, verify state is empty: `terraform state list`. Run destroy again or `terraform state rm` if entries remain.

---

# 20. Terraform Destroy Test Project

**Source:** `terraform_destroy_test_project.md`

**Date:** 2026-03-13

## Destroy Order

Phase 3 (reverse layers) → Phase 2 → Phase 1

## Key Errors

### Error 1: Missing `region` variable (Phase 3 Layer 02)
Not all layers need the same variables. Check `variables.tf` before destroy.

### Error 2: Missing `deployer_sa_key_path` variable (Phase 2)
Variables used by `null_resource`/`local-exec` are still required during destroy.

### Error 3: Landing bucket not empty (Phase 1)
`force_destroy` was false for test environment. Must manually empty bucket first.

**Lesson**: Consider `force_destroy = var.environment != "prod" ? true : var.force_destroy`

## Total Resources Destroyed

| Phase | Resources |
|-------|-----------|
| Phase 3 L03 | 7 |
| Phase 3 L02 | 4 |
| Phase 3 L01 | 15 |
| Phase 2 | 25 |
| Phase 1 | 20 |
| **Total** | **71** |

---

# 21. Terraform Request Timeout

**Source:** `terraform_request_timeout.md`

## Problem

Terraform deploy script failed during `terraform init`/`terraform plan` with DNS resolution errors:
```
dial tcp: lookup iam.googleapis.com: no such host
```

Terraform's default timeout was too short for slow DNS.

## Fix

1. Added `request_timeout = "120s"` to all `provider "google"` blocks (8 files)
2. Removed `/dev/null` redirect from `terraform init` so errors are visible

## Notes

- Terraform has no built-in retry logic for API calls
- The right approach for transient failures is re-running the deploy script (terraform is idempotent)
- `request_timeout` doesn't add retries — it just waits longer before giving up

---

# 22. How IAM Permissions Work

**Source:** `HOW_PERMISSIONS_WORK.md`

## Key Concepts

### IAM Policies Live on Resources

```
Resource: beaming-glyph-489707-b8 (project)
└── IAM Policy: Defines who can do what
    ├── Role: roles/storage.admin
    │   └── Member: serviceAccount:test-terraform-deployer@...
    ├── Role: roles/bigquery.admin
    │   └── Member: serviceAccount:test-terraform-deployer@...
    └── ... (more roles)
```

### Service Accounts Are Identities, Not Permission Containers

| Aspect | Service Account | IAM Policy |
|--------|----------------|------------|
| **What is it?** | An identity that can authenticate | Rules about who can do what |
| **Where does it live?** | Global (exists outside projects) | On resources (projects, buckets, etc.) |
| **What does it contain?** | Keys, email, display name | Bindings (role + member) |
| **Can it have permissions?** | No, permissions come from IAM policies | Yes, it grants permissions |

### Permission Check Flow

```
Action: Create GCS bucket
Actor: test-terraform-deployer@... (authenticated via key)
Resource: projects/beaming-glyph-489707-b8

GCP Permission Check:
1. What permission is needed? storage.buckets.create
2. Which roles grant this permission? roles/storage.admin (and others)
3. Does the SA have this role on the project?
   → Check project IAM policy
   → Found: roles/storage.admin includes test-terraform-deployer
4. Result: ALLOWED
```

### Authentication via Key File

```bash
export GOOGLE_APPLICATION_CREDENTIALS=test-terraform-deployer-key.json
terraform apply

# What happens:
# 1. Terraform reads the key file
# 2. Authenticates as test-terraform-deployer@...
# 3. Makes API calls to GCP
# 4. GCP checks: "Does this SA have permission for this action?"
# 5. Looks up project IAM policy
# 6. Allows or denies the action
```

**The SA doesn't "have" permissions - the project's IAM policy grants them when the SA acts!**

---

# 23. GCR vs GAR Permissions

**Source:** `CLOUDBUILD_PERMISSIONS_ISSUE.md`

## Key Distinction

GCR (Google Container Registry) and GAR (Google Artifact Registry) use **different** permission models:

- **GCR** uses Cloud Storage permissions (`roles/storage.admin`) because GCR stores images in GCS buckets
- **GAR** uses Artifact Registry permissions (`roles/artifactregistry.writer`)

The error `Permission 'artifactregistry.repositories.uploadArtifacts' denied` can appear even when targeting `gcr.io` because Google is migrating GCR to use Artifact Registry under the hood.

## Solutions

| Option | Approach | Best For |
|--------|----------|----------|
| **1** | Grant `roles/storage.admin` to build SA | Existing GCR projects |
| **2** | Enable Cloud Build Service Agent | Quick fix |
| **3** | Migrate to Artifact Registry (GAR) | New projects (recommended) |

```bash
# Migrate from GCR to GAR:
# Old: gcr.io/$PROJECT_ID/image:tag
# New: us-central1-docker.pkg.dev/$PROJECT_ID/repo/image:tag
```

---

# 24. Missing Permissions During Deployment

**Source:** `MISSING_PERMISSIONS_LOG.md`

## Critical Permissions Discovered

### 1. `roles/iam.serviceAccountUser`
- **Error**: `Permission 'iam.serviceaccounts.actAs' denied`
- **Required For**: Impersonating service accounts when creating Cloud Run Jobs
- **Why**: When Terraform creates a Cloud Run Job that uses a service account, it needs permission to "act as" that SA

### 3. API Propagation Timing
After enabling APIs, wait **2-3 minutes** for them to propagate across GCP before running Terraform.

## Pre-flight Validation

Always check APIs and permissions BEFORE running `terraform apply`:
1. All required APIs are enabled
2. All required IAM roles are granted
3. Service account key exists and can authenticate
4. Terraform is installed

---

# 25. Data Pipeline Issues and Fixes

**Source:** `docs/issues_and_fixes.md`

## Issue 1: Memory Issues with Large Files

67MB compressed → 472MB uncompressed causes OOM when loading entire file at once.

**Fix**: Chunked processing with batch sizes of 1,000-10,000 rows:
```python
for chunk_df in processor.read_jsonl_chunks(file_path, chunk_size=10000):
    process_and_insert(chunk_df)
```

**Prevention**: Never accumulate entire file in memory. Use generator-based reading.

## Issue 2: Step-by-Step Debugging Methodology

Break complex e2e tests into incremental steps:
```python
# /tmp/step1.py - Test imports
# /tmp/step2.py - Test storage connection
# /tmp/step3.py - Test file reading
# /tmp/step4.py - Test data processing
# /tmp/step5.py - Test BigQuery insertion
# /tmp/step6.py - Test query results
```

## Issue 3: BigQuery Python Dependencies

`query_job.to_dataframe()` requires both `pandas` AND `db-dtypes`:
```bash
pip install pandas db-dtypes
```

## Issue 5: GCS Emulator Upload API

The correct endpoint for fake-gcs-server media uploads:
```
POST /upload/storage/v1/b/{bucket}/o?uploadType=media&name={object-path}
```

Common mistakes:
- Using `PUT` instead of `POST`
- Wrong endpoint path (direct object path vs upload API)
- Verify with `GET`, not `HEAD`

## Issue 9: BigQuery Bulk Load vs Streaming Insert

| Method | Cost | Best For |
|--------|------|----------|
| `insert_rows_json()` (streaming) | **$0.05/GB** | Real-time data |
| `load_table_from_dataframe()` (bulk) | **FREE** | Batch ETL |

**Emulator Bug**: Bulk load throws false `400 BadRequest: unspecified job configuration query` error but data IS loaded. Known bug ([issue #224](https://github.com/goccy/bigquery-emulator/issues/224)).

**Workaround**: Catch the error and verify with COUNT query.

---

# 26. Cost Optimization and Free Tier Limits

**Source:** `design/learnings.md`

## Cloud Storage Lifecycle

| Retention Days | Max Storage | Free Tier (5 GB) |
|----------------|-------------|------------------|
| 1 day | ~840 MB | Within limit |
| 6 days | ~5 GB | At limit |
| 7 days | ~6 GB | $0.02/GB overage |
| 30 days | ~25 GB | ~$0.40/month |
| 90 days | ~75 GB | ~$1.40/month |

**Decision**: 6-day lifecycle to stay within free tier (~35 MB/hour × 24 hours × 6 days ≈ 5 GB).

## Google Cloud Free Tier Limits (2025)

| Service | Free Tier Limit |
|---------|-----------------|
| **Cloud Storage** | 5 GB/month (US regions only) |
| **Cloud Run** | 360K GB-sec memory, 180K vCPU-sec/month |
| **Cloud Scheduler** | 3 jobs/month |

## Cloud Run Cost Calculation

```
Per execution: 512 MiB × ~90s = 45 GB-seconds, 1 vCPU × ~90s = 90 vCPU-seconds
Monthly (720 executions): 32,400 GB-seconds (9% of free tier), 64,800 vCPU-seconds (36%)
```

## Schema Design Decision: Flattened vs Nested

**Current**: Flattened schema (15-20 columns) — simpler queries, better performance.
**Future consideration**: BigQuery STRUCT/ARRAY fields to preserve full GitHub data (50+ fields).

**Trade-offs**: Nested = more data preserved but larger storage, slower queries, more complex schema management.

---

# 27. Why Editor Role is Problematic

**Source:** `WHY_EDITOR_ROLE.md`

## What Editor Role Grants

`roles/editor` is a **primitive role** that grants:
- Read access to all existing resources
- Create/update/delete access to most resources
- Thousands of permissions across almost all GCP services
- Does NOT grant IAM or billing modifications (requires Owner)

## Why It's Problematic

1. **Redundancy**: Specific admin roles already provide needed access
2. **Unclear permissions**: Hard to audit what the SA is supposed to manage
3. **Security risk**: Compromised key gets broad access to unintended services
4. **Violates least privilege**: Grants access to Cloud SQL, AI Platform, etc. that aren't needed

## The Hidden Dependency

When Editor role was granted, specific admin roles for Storage, BigQuery, Cloud Run, and Cloud Functions were **not explicitly granted** — Editor was silently providing those permissions. Removing Editor without adding the specific admin roles would break deployments.

**Fix**: Remove Editor + add the missing specific roles:
```bash
# Remove broad role
gcloud projects remove-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:SA_EMAIL" --role="roles/editor"

# Add specific roles
for role in roles/storage.admin roles/bigquery.admin roles/run.admin \
  roles/cloudfunctions.admin roles/iam.serviceAccountAdmin; do
  gcloud projects add-iam-policy-binding PROJECT_ID \
    --member="serviceAccount:SA_EMAIL" --role="$role"
done
```

| Environment | Editor Role | Recommendation |
|-------------|-------------|----------------|
| **Test/Dev** | Acceptable | OK for simplicity |
| **Staging** | Not Recommended | Use specific roles |
| **Production** | Never | Always use specific roles |

---

# Summary of Identified Inaccuracies

| # | File | Issue | Detail |
|---|------|-------|--------|
| 1 | `github_actions_ci_issues.md` | PowerShell claim wrong | Ubuntu GitHub runners DO have `pwsh` pre-installed; issue was using `powershell` (Windows) instead of `pwsh` |
