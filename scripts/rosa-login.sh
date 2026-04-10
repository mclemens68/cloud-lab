#!/bin/bash
set -euo pipefail

log() {
  echo "[$(date)] $*"
}

usage() {
  echo "Usage: ./$(basename "$0") <cluster>"
  echo "Example: ./$(basename "$0") rosa-lab"
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

for cmd in rosa oc; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "ERROR: Required command '$cmd' is not installed or not in PATH"
    exit 1
  fi
done

CLUSTER="$1"
ADMIN_OUT="./${CLUSTER}-admin.out"

create_credentials() {
  log "Creating new ROSA admin credentials for cluster '$CLUSTER'"
  rosa delete admin --cluster "$CLUSTER" --yes >/dev/null 2>&1 || true
  rosa create admin --cluster "$CLUSTER" >"$ADMIN_OUT" 2>&1
  log "Saved credentials to $ADMIN_OUT"
}

if [[ ! -f "$ADMIN_OUT" ]]; then
  log "Credentials file not found: $ADMIN_OUT"

  if [[ ! -t 0 ]]; then
    log "ERROR: Non-interactive shell and no credential file present"
    exit 1
  fi

  read -r -p "Create new credentials now? [y/N]: " create_answer
  case "$(printf '%s' "${create_answer:-N}" | tr '[:upper:]' '[:lower:]')" in
    y|yes)
      create_credentials
      ;;
    *)
      log "Login cancelled by user"
      exit 1
      ;;
  esac
else
  log "Using existing credentials file: $ADMIN_OUT"
fi

LOGIN_LINE="$(awk '/^[[:space:]]*oc login / {print; exit}' "$ADMIN_OUT")"
if [[ -z "${LOGIN_LINE:-}" ]]; then
  log "ERROR: Could not find an 'oc login' command in $ADMIN_OUT"
  exit 1
fi

API_URL=""
USERNAME="cluster-admin"
PASSWORD=""

read -r -a TOKENS <<<"$LOGIN_LINE"
for ((i=0; i<${#TOKENS[@]}; i++)); do
  token="${TOKENS[$i]}"
  next=""
  if (( i + 1 < ${#TOKENS[@]} )); then
    next="${TOKENS[$((i + 1))]}"
  fi

  case "$token" in
    http://*|https://*)
      API_URL="$token"
      ;;
    --server)
      API_URL="$next"
      ;;
    --server=*)
      API_URL="${token#--server=}"
      ;;
    -u|--username)
      USERNAME="$next"
      ;;
    --username=*)
      USERNAME="${token#--username=}"
      ;;
    -p|--password)
      PASSWORD="$next"
      ;;
    --password=*)
      PASSWORD="${token#--password=}"
      ;;
  esac
done

if [[ -z "${API_URL:-}" ]]; then
  API_URL="$(awk -F': ' '/^API URL:/ {print $2; exit}' "$ADMIN_OUT" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
fi

if [[ -z "${API_URL:-}" ]]; then
  log "ERROR: Could not parse API URL from $ADMIN_OUT"
  exit 1
fi

if [[ -z "${PASSWORD:-}" ]]; then
  PASSWORD="$(awk '/^[[:space:]]*oc login /{
    for (i=1; i<=NF; i++) {
      if ($i == "--password") {
        print $(i+1)
        exit
      }
    }
  }' "$ADMIN_OUT")"
fi

if [[ -z "${PASSWORD:-}" ]]; then
  log "ERROR: Could not parse password from $ADMIN_OUT"
  exit 1
fi

log "Attempting oc login to $API_URL as $USERNAME"
if ! oc login "$API_URL" -u "$USERNAME" -p "$PASSWORD" >/dev/null 2>&1; then
  log "ERROR: oc login failed"
  exit 1
fi

log "oc login succeeded"

CURRENT_CONTEXT="$(oc config current-context 2>/dev/null || true)"
if [[ -z "${CURRENT_CONTEXT:-}" ]]; then
  log "WARNING: Could not determine current kubeconfig context after login"
  exit 0
fi

log "Detected current kubeconfig context: $CURRENT_CONTEXT"

if [[ "$CURRENT_CONTEXT" == "$CLUSTER" ]]; then
  log "Current context already matches cluster '$CLUSTER'"
else
  if oc config get-contexts -o name 2>/dev/null | grep -Fx "$CLUSTER" >/dev/null 2>&1; then
    log "Deleting stale kubeconfig context: $CLUSTER"
    if ! oc config delete-context "$CLUSTER" >/dev/null 2>&1; then
      log "WARNING: Failed to delete stale kubeconfig context: $CLUSTER"
    fi
  fi

  log "Renaming kubeconfig context '$CURRENT_CONTEXT' to '$CLUSTER'"
  if ! oc config rename-context "$CURRENT_CONTEXT" "$CLUSTER" >/dev/null 2>&1; then
    log "WARNING: Failed to rename kubeconfig context '$CURRENT_CONTEXT' to '$CLUSTER'"
  fi
fi

log "Switching to kubeconfig context: $CLUSTER"
if ! oc config use-context "$CLUSTER" >/dev/null 2>&1; then
  log "WARNING: Failed to switch to kubeconfig context: $CLUSTER"
fi

log "Current kubeconfig context: $(oc config current-context 2>/dev/null || echo unknown)"
log "ROSA login completed"