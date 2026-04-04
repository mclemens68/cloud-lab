#!/bin/bash
set -euo pipefail

GITHUB="/opt/github"
LOG_FILE=""
ADMIN_OUT=""
WORKSPACE=""
CLUSTER_NAME=""
TF_DIR="$GITHUB/cloud-lab/terraform"

POLL_SECONDS=30
MAX_WAIT_MINUTES=60
LOGIN_RETRY_SECONDS=20
LOGIN_MAX_WAIT_MINUTES=10

log() {
  echo "[$(date)] $*"
}

print_usage() {
  echo "Usage: ./$(basename "$0") [workspace] [cluster_name]"
  echo "Defaults:"
  echo "  workspace    = rosa-lab"
  echo "  cluster_name = rosa-lab"
}

select_workspace_and_cluster() {
  local use_defaults answer input_workspace input_cluster confirm

  if [[ $# -gt 0 ]]; then
    WORKSPACE="${1:-rosa-lab}"
    CLUSTER_NAME="${2:-rosa-lab}"
    return
  fi

  if [[ ! -t 0 ]]; then
    WORKSPACE="${1:-rosa-lab}"
    CLUSTER_NAME="${2:-rosa-lab}"
    return
  fi

  print_usage
  read -r -p "Use defaults for setup? [Y/n]: " answer
  use_defaults="${answer:-Y}"

  case "$(printf '%s' "$use_defaults" | tr '[:upper:]' '[:lower:]')" in
    y|yes)
      WORKSPACE="rosa-lab"
      CLUSTER_NAME="rosa-lab"
      ;;
    n|no)
      read -r -p "Enter terraform workspace [rosa-lab]: " input_workspace
      read -r -p "Enter cluster name [rosa-lab]: " input_cluster
      WORKSPACE="${input_workspace:-rosa-lab}"
      CLUSTER_NAME="${input_cluster:-rosa-lab}"
      ;;
    *)
      log "Unrecognized response, using defaults"
      WORKSPACE="rosa-lab"
      CLUSTER_NAME="rosa-lab"
      ;;
  esac

  read -r -p "Proceed with setup of cluster '$CLUSTER_NAME' in workspace '$WORKSPACE'? [y/N]: " confirm
  case "$(printf '%s' "${confirm:-N}" | tr '[:upper:]' '[:lower:]')" in
    y|yes)
      ;;
    *)
      log "Setup cancelled by user"
      exit 1
      ;;
  esac
}

for cmd in terraform rosa oc; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "ERROR: Required command '$cmd' is not installed or not in PATH"
    exit 1
  fi
done

select_workspace_and_cluster "$@"

LOG_FILE="$GITHUB/cloud-lab/scripts/setup-${WORKSPACE}.log"
ADMIN_OUT="$GITHUB/cloud-lab/scripts/${CLUSTER_NAME}-admin.out"
exec > >(tee "$LOG_FILE") 2>&1

log "Script: $(basename "$0")"
log "Log file: $LOG_FILE"
log "Admin output file: $ADMIN_OUT"

cd "$TF_DIR"

log "Script started"
log "Terraform dir: $TF_DIR"
log "Workspace: $WORKSPACE"
log "Cluster: $CLUSTER_NAME"
log "Using workspace/cluster pair: $WORKSPACE / $CLUSTER_NAME"

log "Selecting terraform workspace..."
if ! terraform workspace select "$WORKSPACE" >/dev/null 2>&1; then
  log "ERROR: Terraform workspace '$WORKSPACE' does not exist. Run 'terraform workspace list' and create/select it before running setup."
  exit 1
fi

log "Running terraform apply"
terraform apply -auto-approve -no-color

log "Terraform apply complete"

# ---------------------------------------------------
# Wait for cluster to become ready
# ---------------------------------------------------
log "Waiting for ROSA cluster to reach 'ready' state..."

MAX_WAITS=$(( MAX_WAIT_MINUTES * 60 / POLL_SECONDS ))
COUNT=0

while true; do
  if ! OUTPUT="$(rosa describe cluster --cluster "$CLUSTER_NAME" 2>/dev/null)"; then
    log "Cluster not yet visible via rosa CLI — waiting..."
    COUNT=$((COUNT + 1))
    if [[ "$COUNT" -ge "$MAX_WAITS" ]]; then
      log "ERROR: Timed out waiting for cluster to become visible"
      exit 1
    fi
    sleep "$POLL_SECONDS"
    continue
  fi

  STATE="$(echo "$OUTPUT" | awk -F': ' '/^State:/ {print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  log "Cluster state: $STATE"

  if [[ "$(printf '%s' "$STATE" | tr '[:upper:]' '[:lower:]')" == "ready" ]]; then
    log "Cluster is ready"
    break
  fi

  COUNT=$((COUNT + 1))
  if [[ "$COUNT" -ge "$MAX_WAITS" ]]; then
    log "ERROR: Timed out waiting for cluster to become ready"
    exit 1
  fi

  sleep "$POLL_SECONDS"
done

# ---------------------------------------------------
# Optional: get admin credentials
# ---------------------------------------------------
log "Retrieving admin credentials..."

API_URL="$(echo "$OUTPUT" | awk -F': ' '/^API URL:/ {print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
log "Rotating cluster-admin credentials..."
rosa delete admin --cluster "$CLUSTER_NAME" --yes >/dev/null 2>&1 || true
rosa create admin --cluster "$CLUSTER_NAME" >"$ADMIN_OUT" 2>&1
cat "$ADMIN_OUT"

PASSWORD="$(awk '/^[[:space:]]*oc login /{
  for (i=1; i<=NF; i++) {
    if ($i == "--password") {
      print $(i+1)
      exit
    }
  }
}' "$ADMIN_OUT")"

# ---------------------------------------------------
# Optional: login + basic health checks
# ---------------------------------------------------
if [[ -n "${API_URL:-}" ]]; then
  log "Attempting oc login..."

  if [[ -n "${PASSWORD:-}" ]]; then
    LOGIN_MAX_WAITS=$(( LOGIN_MAX_WAIT_MINUTES * 60 / LOGIN_RETRY_SECONDS ))
    LOGIN_COUNT=0

    while true; do
      if oc login "$API_URL" -u cluster-admin -p "$PASSWORD" >/dev/null 2>&1; then
        log "Running basic cluster checks..."

        oc get nodes -o wide || true
        oc get co || true
        oc get pods -A || true
        break
      fi

      LOGIN_COUNT=$((LOGIN_COUNT + 1))
      if [[ "$LOGIN_COUNT" -ge "$LOGIN_MAX_WAITS" ]]; then
        log "oc login failed after waiting ${LOGIN_MAX_WAIT_MINUTES} minutes — skipping cluster checks"
        break
      fi

      log "cluster-admin login not active yet; retrying in ${LOGIN_RETRY_SECONDS}s..."
      sleep "$LOGIN_RETRY_SECONDS"
    done
  else
    log "Could not extract password — skipping oc login"
  fi
else
  log "API URL not found — skipping oc login"
fi

log "Setup completed successfully"