#!/bin/bash
# =============================================================================
# Cleanup Stale Service Accounts
# =============================================================================
# Identifies SAs with no recent activity and prompts for deletion.
# Safe to run from Cloud Shell or any authenticated gcloud session.
#
# Usage:
#   ./cleanup-stale-sas.sh PROJECT_ID [DAYS]
#
# Arguments:
#   PROJECT_ID  - GCP project ID
#   DAYS        - Number of days to consider "stale" (default: 7)
#
# Example:
#   ./cleanup-stale-sas.sh beaming-glyph-489707-b8 7
# =============================================================================

set -e

PROJECT_ID="${1:?Usage: $0 PROJECT_ID [DAYS]}"
DAYS="${2:-7}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Stale Service Account Cleanup${NC}"
echo -e "${BLUE}  Project: ${PROJECT_ID}${NC}"
echo -e "${BLUE}  Stale threshold: ${DAYS} days${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# ─── Step 1: Get all SAs in the project ───────────────────────────────────────
echo -e "${YELLOW}Step 1: Listing all service accounts...${NC}"
ALL_SAS=$(gcloud iam service-accounts list \
  --project="$PROJECT_ID" \
  --format="value(email)" 2>/dev/null)

TOTAL=$(echo "$ALL_SAS" | wc -l)
echo "  Found ${TOTAL} service accounts"
echo ""

# ─── Step 2: Filter out protected SAs ─────────────────────────────────────────
echo -e "${YELLOW}Step 2: Filtering out protected accounts...${NC}"

CANDIDATE_SAS=""
SKIPPED=0

while IFS= read -r sa; do
  # Skip Google-managed defaults
  if echo "$sa" | grep -qE "(-compute@developer|@appspot\.|@cloudservices\.|service-[0-9]+@gcp-sa-|@cloudbuild\.gserviceaccount)"; then
    echo -e "  ${GREEN}PROTECTED (Google-managed):${NC} $sa"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Skip terraform deployer accounts (delete these manually)
  if echo "$sa" | grep -qiE "(terraform-deployer|tf-deployer)"; then
    echo -e "  ${GREEN}PROTECTED (deployer):${NC} $sa"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  CANDIDATE_SAS="${CANDIDATE_SAS}${sa}\n"
done <<< "$ALL_SAS"

CANDIDATE_SAS=$(echo -e "$CANDIDATE_SAS" | sed '/^$/d')
CANDIDATE_COUNT=$(echo "$CANDIDATE_SAS" | sed '/^$/d' | wc -l)
echo ""
echo "  Skipped: ${SKIPPED} protected accounts"
echo "  Candidates to check: ${CANDIDATE_COUNT}"
echo ""

if [ "$CANDIDATE_COUNT" -eq 0 ]; then
  echo -e "${GREEN}No candidate SAs to check. All accounts are protected.${NC}"
  exit 0
fi

# ─── Step 3: Find active SAs from audit logs ──────────────────────────────────
echo -e "${YELLOW}Step 3: Checking audit logs for activity in last ${DAYS} days...${NC}"

SINCE=$(date -u -d "${DAYS} days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-${DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2026-03-12T00:00:00Z")

ACTIVE_SAS=$(gcloud logging read \
  "protoPayload.authenticationInfo.principalEmail:\".iam.gserviceaccount.com\" AND timestamp>=\"${SINCE}\"" \
  --project="$PROJECT_ID" \
  --format="value(protoPayload.authenticationInfo.principalEmail)" \
  --limit=1000 2>/dev/null | sort -u)

ACTIVE_COUNT=$(echo "$ACTIVE_SAS" | sed '/^$/d' | wc -l)
echo "  Found ${ACTIVE_COUNT} active accounts in audit logs"
echo ""

# ─── Step 4: Identify stale SAs ──────────────────────────────────────────────
echo -e "${YELLOW}Step 4: Identifying stale accounts...${NC}"
echo ""

STALE_SAS=""
STALE_COUNT=0

while IFS= read -r sa; do
  [ -z "$sa" ] && continue

  if echo "$ACTIVE_SAS" | grep -q "$sa"; then
    echo -e "  ${GREEN}ACTIVE:${NC} $sa"
  else
    echo -e "  ${RED}STALE:${NC}  $sa"
    STALE_SAS="${STALE_SAS}${sa}\n"
    STALE_COUNT=$((STALE_COUNT + 1))
  fi
done <<< "$CANDIDATE_SAS"

echo ""

if [ "$STALE_COUNT" -eq 0 ]; then
  echo -e "${GREEN}No stale service accounts found. All candidate accounts were active.${NC}"
  exit 0
fi

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  Found ${STALE_COUNT} stale service account(s)${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""

# ─── Step 5: Prompt for deletion ──────────────────────────────────────────────
STALE_SAS=$(echo -e "$STALE_SAS" | sed '/^$/d')
DELETED=0

while IFS= read -r sa; do
  [ -z "$sa" ] && continue

  echo -e "${BLUE}────────────────────────────────────────${NC}"
  echo -e "  SA:      ${RED}${sa}${NC}"

  # Get display name
  DISPLAY=$(gcloud iam service-accounts describe "$sa" \
    --project="$PROJECT_ID" \
    --format="value(displayName)" 2>/dev/null || echo "(unknown)")
  echo -e "  Name:    ${DISPLAY}"

  # Check if disabled
  DISABLED=$(gcloud iam service-accounts describe "$sa" \
    --project="$PROJECT_ID" \
    --format="value(disabled)" 2>/dev/null || echo "unknown")
  echo -e "  Disabled: ${DISABLED}"

  # Show IAM roles
  ROLES=$(gcloud projects get-iam-policy "$PROJECT_ID" \
    --flatten="bindings[].members" \
    --filter="bindings.members:${sa}" \
    --format="value(bindings.role)" 2>/dev/null | head -5)
  if [ -n "$ROLES" ]; then
    echo -e "  Roles:"
    echo "$ROLES" | while read -r role; do
      echo -e "    - ${role}"
    done
  else
    echo -e "  Roles:   (none at project level)"
  fi

  echo ""
  echo -ne "  ${YELLOW}Delete this service account? [y/N]: ${NC}"
  read -r CONFIRM

  if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
    echo -e "  ${RED}Deleting ${sa}...${NC}"
    if gcloud iam service-accounts delete "$sa" \
      --project="$PROJECT_ID" --quiet 2>/dev/null; then
      echo -e "  ${GREEN}Deleted successfully.${NC}"
      DELETED=$((DELETED + 1))
    else
      echo -e "  ${RED}Failed to delete. Check permissions.${NC}"
    fi
  else
    echo -e "  ${BLUE}Skipped.${NC}"
  fi
  echo ""

done <<< "$STALE_SAS"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "  Total SAs:     ${TOTAL}"
echo -e "  Protected:     ${SKIPPED}"
echo -e "  Active:        $((CANDIDATE_COUNT - STALE_COUNT))"
echo -e "  Stale found:   ${STALE_COUNT}"
echo -e "  Deleted:       ${DELETED}"
echo -e "  Remaining:     $((STALE_COUNT - DELETED))"
echo ""
