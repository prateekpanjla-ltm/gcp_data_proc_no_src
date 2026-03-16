# DevOps Strategy and Practices

## 1. Executive Summary

This project's DevOps philosophy is built on the principles of Infrastructure as Code (IaC), automation, and proactive validation. The entire infrastructure is managed declaratively using a layered Terraform approach, enabling consistent and repeatable environments. A comprehensive CI/CD pipeline in GitHub Actions automates the build, test, and deployment process, while a robust testing strategy ensures each component's reliability. This document details the core principles, tooling, and key operational patterns learned and implemented throughout the project lifecycle.

## 2. Core Principles

### 2.1. Infrastructure as Code (IaC)

*   **Primary Tool**: **Terraform** is the exclusive tool for managing all cloud resources. This ensures that infrastructure is version-controlled, auditable, and can be deployed consistently across different environments.
*   **State Management**: The Terraform state is stored in a **GCS remote backend**. This is critical for enabling CI/CD and collaborative development, preventing state conflicts that occur with local backends (Learning #6).
*   **Imperative Alternative**: For reference and quick provisioning, imperative `gcloud` scripts like `create_phase3_gcloud.sh` exist, but Terraform remains the source of truth for automated deployments.

### 2.2. Layered Deployment Strategy

To manage resources with different lifecycles, the Terraform configuration is split into three distinct layers, orchestrated by deployment scripts.

| Layer | Name | Purpose & Examples | Lifecycle |
|---|---|---|---|
| **01** | `static` | Foundational, long-lived resources that rarely change. | Deployed once per environment. |
| | | *Service Accounts, IAM Bindings, GCS Buckets, BigQuery Datasets/Tables.* | |
| **02** | `first-time` | Project-level configurations and API enablement. | Deployed once per project. |
| | | *`google_project_service` resources (enabling `run.googleapis.com`, etc.).* | |
| **03** | `operational` | Application-specific resources that change frequently with code deployments. | Deployed on every CI/CD run. |
| | | *Cloud Run services, Cloud Functions, Eventarc triggers.* | |

This separation prevents accidental destruction of stateful resources (like BigQuery tables) during routine application updates.

### 2.3. Environment Separation

The pipeline is designed to support multiple environments (e.g., `dev`, `test`, `prod`). The target environment is controlled by a Terraform variable (`var.environment`), which dynamically prefixes resource names (e.g., `dev-github-archive-processor`). This ensures strict isolation between environments.

### 2.4. Security and Least Privilege

*   **Dedicated Service Accounts**: Each pipeline component (Phase 1 Job, Phase 2 Service, Phase 3 Function, Phase 4 Dashboard) runs with its own dedicated, user-managed Service Account (Service Identity).
*   **Minimal Permissions**: Each Service Account is granted only the specific IAM roles required for its function (e.g., `roles/storage.objectViewer` to read, `roles/bigquery.dataEditor` to write).
*   **Avoiding Primitive Roles**: The overly permissive `roles/editor` role is explicitly avoided in favor of fine-grained roles to minimize the blast radius of a potential key compromise (Learning #27).
*   **Proactive Validation**: Scripts like `test-phase1-permissions.sh` use the Policy Troubleshooter API to verify that a deployer service account has the necessary permissions *before* a deployment is attempted.

## 3. Tooling and Technologies

| Category | Tool/Technology | Purpose |
|---|---|---|
| **IaC** | Terraform | Declarative infrastructure management. |
| **CI/CD** | GitHub Actions | Automated build, test, and deployment workflows. |
| **Containerization** | Docker | Packaging applications (Phase 2 Processor, Phase 4 Dashboard). |
| **Builds** | Cloud Build | Building container images and deploying Cloud Functions source. |
| **Scripting** | Bash | Orchestrating deployments and running test suites. |
| **Testing** | `gcloud policy-troubleshoot` | Pre-flight IAM validation. |
| | `curl`, `gsutil`, `gcloud pubsub` | Post-deployment integration testing. |

## 4. CI/CD Pipeline (GitHub Actions)

The CI/CD pipeline, defined in `.github/workflows/`, automates the deployment of the operational layer.

### Key Workflow Features:

*   **Trigger**: The workflow is triggered on push events to specific branches (e.g., `main`, `develop`).
*   **Concurrency Control**: To prevent race conditions and state file corruption from rapid pushes, a concurrency group is used. This ensures only one deployment per branch runs at a time, canceling any in-progress runs.
    ```yaml
    concurrency:
      group: gh-archive-deploy-${{ github.ref }}
      cancel-in-progress: true
    ```
*   **Secrets Management**: The GCP Service Account key for the deployer is stored as a Base64-encoded secret in GitHub Actions and decoded at runtime.
*   **Executable Permissions**: A common CI issue where scripts lose their executable bit is handled by explicitly running `chmod +x` in the workflow (Learning #6).

### Pipeline Stages:

1.  **Setup**: Authenticates to GCP using the deployer service account key. Installs `gcloud`, `terraform`, and other dependencies.
2.  **Build Image (if applicable)**: For Cloud Run services (Phase 2, 4), it invokes `gcloud builds submit` to build the Docker container using a `cloudbuild.yaml` file and push it to Artifact Registry. The Terraform configuration explicitly `depends_on` this step to prevent deploying a service before its image exists (Learning #16).
3.  **Terraform Init**: Initializes Terraform with the GCS backend.
4.  **Terraform Plan**: Generates an execution plan for review.
5.  **Terraform Apply**: Applies the changes to deploy the new version of the service.

## 5. Testing Strategy

A multi-faceted testing strategy is employed to ensure pipeline reliability.

### 5.1. Pre-Flight IAM Validation

Before any `terraform apply` command, a script like `test-phase1-permissions.sh` can be run. It uses `gcloud policy-troubleshoot iam` to programmatically check if the deployer service account has every specific permission needed for the upcoming deployment, preventing IAM-related failures during the run.

### 5.2. Post-Deployment Integration Testing

The `test_cloud_run.sh` script for Phase 2 is a prime example of a comprehensive post-deployment test suite. It validates the running service from multiple angles:
*   **Health/Readiness Checks**: Hits the `/health` and `/ready` endpoints.
*   **Direct Invocation**: Manually calls the `/process` endpoint with an authenticated OIDC token, simulating a direct request.
*   **Eventarc Trigger Simulation**: Publishes a fake GCS event payload to the trigger's underlying Pub/Sub topic to test the full event-driven flow.
*   **End-to-End Trigger**: Uploads a new file to the landing bucket to trigger the entire process naturally.

## 6. Key DevOps Patterns and Learnings

### 6.1. Handling IAM Eventual Consistency

*   **The Problem**: IAM policy changes can take up to 60 seconds to propagate. A Terraform `apply` might succeed in creating an IAM binding, but the permission is not yet enforceable, causing subsequent steps (like a Cloud Build) to fail with a `403 Permission Denied` error.
*   **The Pattern**: A `wait_for_iam_propagation` `null_resource` is used. It runs a `local-exec` provisioner that polls the `testIamPermissions` API in a loop. This API checks against the **enforcement layer**, not the control plane, guaranteeing the permission is active before proceeding (Learning #9).

### 6.2. Explicit Service Agent Initialization

*   **The Problem**: Google-managed service agents (e.g., for Eventarc, Cloud Storage) are not created when an API is enabled, but rather on first use. This can cause a race condition where Terraform tries to grant a role to a service account that doesn't exist yet.
*   **The Pattern**: Before running `terraform apply`, explicitly activate the necessary service agents using commands like `gcloud beta services identity create --service=eventarc.googleapis.com`. This ensures the service accounts exist before IAM bindings are attached (Learning #7).

### 6.3. Managing Eventarc Trigger Dependencies

*   **The Problem**: For an Eventarc trigger to call an authenticated Cloud Run service, a complex chain of IAM permissions is required, involving the Pub/Sub Service Agent, the Eventarc Invoker SA, and the Cloud Run Service Identity.
*   **The Pattern**: The `gcloud` deployment script (`create_phase3_gcloud.sh`) and Terraform configurations explicitly grant these roles:
    1.  **Pub/Sub SA** gets `roles/iam.serviceAccountTokenCreator` on the **Invoker SA**.
    2.  **Invoker SA** gets `roles/run.invoker` on the **Cloud Run Service**.
    This pattern is crucial for securing event-driven architectures (Learning #14, #18).

### 6.4. Idempotency and Error Handling

*   **Idempotent Design**: The Phase 2 processor is designed to be idempotent. Re-processing the same input file safely overwrites the output chunks in the staging bucket. This makes retries from Eventarc safe.
*   **Known Risks**: The Phase 3 loader is noted as **not** being inherently idempotent. A failure after the BigQuery load but before the GCS delete could lead to duplicate data on retry. This is a documented and accepted risk for the current design (Phase 3 Design Doc).
*   **Configuration**: Critical behaviors, like whether Phase 3 deletes files (`DELETE_AFTER_LOAD`), are controlled by environment variables set via Terraform, allowing for different behaviors per environment.

