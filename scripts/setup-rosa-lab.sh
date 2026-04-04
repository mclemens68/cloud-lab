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
POST_LOGIN_POLL_SECONDS=30
POST_LOGIN_MAX_WAIT_MINUTES=20

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
# Retrieve admin credentials
# ---------------------------------------------------
log "Retrieving admin credentials..."

if ! OUTPUT="$(rosa describe cluster --cluster "$CLUSTER_NAME" 2>/dev/null)"; then
  log "ERROR: Unable to refresh ROSA cluster description before admin login"
  exit 1
fi

API_URL="$(echo "$OUTPUT" | awk -F': ' '/^API URL:/ {print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
if [[ -z "${API_URL:-}" ]]; then
  log "ERROR: API URL not found in ROSA cluster description"
  exit 1
fi
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
# Login and wait for cluster convergence
# ---------------------------------------------------
log "Attempting oc login..."

if [[ -z "${PASSWORD:-}" ]]; then
  log "ERROR: Could not extract password from $ADMIN_OUT"
  exit 1
fi

LOGIN_MAX_WAITS=$(( LOGIN_MAX_WAIT_MINUTES * 60 / LOGIN_RETRY_SECONDS ))
LOGIN_COUNT=0

while true; do
  if oc login "$API_URL" -u cluster-admin -p "$PASSWORD" >/dev/null 2>&1; then
    log "cluster-admin login succeeded"

    CURRENT_CONTEXT="$(oc config current-context 2>/dev/null || true)"
    if [[ -n "${CURRENT_CONTEXT:-}" ]]; then
      log "Detected current kubeconfig context: $CURRENT_CONTEXT"

      if [[ "$CURRENT_CONTEXT" == "$WORKSPACE" ]]; then
        log "Current context already matches workspace '$WORKSPACE'; no rename needed"
      else
        if oc config get-contexts -o name 2>/dev/null | grep -Fx "$WORKSPACE" >/dev/null 2>&1; then
          log "Deleting stale kubeconfig context: $WORKSPACE"
          if ! oc config delete-context "$WORKSPACE" >/dev/null 2>&1; then
            log "WARNING: Failed to delete stale kubeconfig context: $WORKSPACE"
          fi
        fi

        log "Renaming kubeconfig context '$CURRENT_CONTEXT' to '$WORKSPACE'"
        if ! oc config rename-context "$CURRENT_CONTEXT" "$WORKSPACE" >/dev/null 2>&1; then
          log "WARNING: Failed to rename kubeconfig context '$CURRENT_CONTEXT' to '$WORKSPACE'"
        fi
      fi

      log "Switching to kubeconfig context: $WORKSPACE"
      if ! oc config use-context "$WORKSPACE" >/dev/null 2>&1; then
        log "WARNING: Failed to switch to kubeconfig context: $WORKSPACE"
      fi
    else
      log "WARNING: Could not determine current kubeconfig context after login; skipping context rename"
    fi

    log "Waiting for post-login cluster convergence (nodes + key operators)..."
    POST_LOGIN_MAX_WAITS=$(( POST_LOGIN_MAX_WAIT_MINUTES * 60 / POST_LOGIN_POLL_SECONDS ))
    POST_LOGIN_COUNT=0

    while true; do
      NODES_OUTPUT="$(oc get nodes --no-headers 2>/dev/null || true)"
      TOTAL_NODES="$(printf '%s\n' "$NODES_OUTPUT" | sed '/^[[:space:]]*$/d' | wc -l | awk '{print $1}')"
      READY_NODES="$(printf '%s\n' "$NODES_OUTPUT" | awk '$2 ~ /(^|,)Ready($|,)/ {c++} END {print c+0}')"

      CO_OUTPUT="$(oc get co --no-headers 2>/dev/null || true)"
      OPERATORS_HEALTHY="true"

      for OPERATOR in dns ingress image-registry storage network; do
        OP_LINE="$(printf '%s\n' "$CO_OUTPUT" | awk -v op="$OPERATOR" '$1 == op {print; exit}')"
        if [[ -z "${OP_LINE:-}" ]]; then
          OPERATORS_HEALTHY="false"
          log "Operator $OPERATOR status: unavailable"
          continue
        fi

        OP_AVAILABLE="$(printf '%s\n' "$OP_LINE" | awk '{print $3}')"
        OP_DEGRADED="$(printf '%s\n' "$OP_LINE" | awk '{print $5}')"
        log "Operator $OPERATOR status: Available=$OP_AVAILABLE Degraded=$OP_DEGRADED"

        if [[ "$OP_AVAILABLE" != "True" || "$OP_DEGRADED" != "False" ]]; then
          OPERATORS_HEALTHY="false"
        fi
      done

      log "Post-login convergence check: ready_nodes=$READY_NODES total_nodes=$TOTAL_NODES operators_healthy=$OPERATORS_HEALTHY"

      if [[ "$READY_NODES" -ge 2 && "$OPERATORS_HEALTHY" == "true" ]]; then
        log "Post-login convergence complete"
        log "Running basic cluster checks..."
        oc get nodes -o wide || true
        oc get co || true
        oc get pods -A || true
        break
      fi

      POST_LOGIN_COUNT=$((POST_LOGIN_COUNT + 1))
      if [[ "$POST_LOGIN_COUNT" -ge "$POST_LOGIN_MAX_WAITS" ]]; then
        log "ERROR: Timed out after ${POST_LOGIN_MAX_WAIT_MINUTES} minutes waiting for cluster convergence"
        log "Diagnostics: oc get nodes -o wide"
        oc get nodes -o wide || true
        log "Diagnostics: oc get co"
        oc get co || true
        log "Diagnostics: oc get pods -A"
        oc get pods -A || true
        exit 1
      fi

      log "Cluster not converged yet; retrying in ${POST_LOGIN_POLL_SECONDS}s..."
      sleep "$POST_LOGIN_POLL_SECONDS"
    done

    break
  fi

  LOGIN_COUNT=$((LOGIN_COUNT + 1))
  if [[ "$LOGIN_COUNT" -ge "$LOGIN_MAX_WAITS" ]]; then
    log "ERROR: oc login failed after waiting ${LOGIN_MAX_WAIT_MINUTES} minutes"
    exit 1
  fi

  log "cluster-admin login not active yet; retrying in ${LOGIN_RETRY_SECONDS}s..."
  sleep "$LOGIN_RETRY_SECONDS"
done

log "Setup completed successfully"