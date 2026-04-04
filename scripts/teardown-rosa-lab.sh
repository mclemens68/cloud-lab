#!/bin/bash
set -euo pipefail

GITHUB="/opt/github"
LOG_FILE=""
ADMIN_OUT=""
WORKSPACE=""
CLUSTER_NAME=""
TF_DIR="$GITHUB/cloud-lab/terraform"
REGION="us-east-2"

POLL_SECONDS=60
SETTLE_SECONDS=180
MAX_WAIT_MINUTES=45
ORPHAN_WORKER_TERMINATE_AFTER_CYCLES=5
VPC_ID=""

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
  read -r -p "Use defaults for teardown? [Y/n]: " answer
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

  read -r -p "Proceed with teardown of cluster '$CLUSTER_NAME' in workspace '$WORKSPACE'? [y/N]: " confirm
  case "$(printf '%s' "${confirm:-N}" | tr '[:upper:]' '[:lower:]')" in
    y|yes)
      ;;
    *)
      log "Teardown cancelled by user"
      exit 1
      ;;
  esac
}

CURRENT_CLUSTER_DNS=""
CURRENT_CLUSTER_ID=""
PRESERVE_ROSA_ZONE=""
PRESERVE_HYPERSHIFT_ZONE=""

normalize_zone_name() {
  local zone_name="$1"
  if [[ -z "${zone_name:-}" ]]; then
    echo ""
  elif [[ "$zone_name" == *. ]]; then
    echo "$zone_name"
  else
    echo "$zone_name."
  fi
}

capture_current_rosa_zone_context() {
  local cluster_desc dns_value cluster_id

  log "Capturing current ROSA DNS/zone context before teardown"

  if ! cluster_desc="$(rosa describe cluster --cluster "$CLUSTER_NAME" 2>/dev/null)"; then
    log "Cluster '$CLUSTER_NAME' not found in RHCS at capture time; no current zones will be preserved"
    return
  fi

  dns_value="$(echo "$cluster_desc" | awk -F': ' '/^DNS:/ {print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  cluster_id="$(echo "$cluster_desc" | awk -F': ' '/^ID:/ {print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  if [[ -n "${dns_value:-}" ]]; then
    CURRENT_CLUSTER_DNS="$dns_value"
    PRESERVE_ROSA_ZONE="$(normalize_zone_name "rosa.${dns_value}")"
  fi

  if [[ -n "${cluster_id:-}" ]]; then
    CURRENT_CLUSTER_ID="$cluster_id"
  fi

  PRESERVE_HYPERSHIFT_ZONE="$(normalize_zone_name "${CLUSTER_NAME}.hypershift.local")"

  log "Current cluster context: id=${CURRENT_CLUSTER_ID:-unknown} dns=${CURRENT_CLUSTER_DNS:-unknown}"
  if [[ -n "${PRESERVE_ROSA_ZONE:-}" ]]; then
    log "Preserving current ROSA zone name: $PRESERVE_ROSA_ZONE"
  fi
  if [[ -n "${PRESERVE_HYPERSHIFT_ZONE:-}" ]]; then
    log "Preserving current hypershift zone name (VPC-aware): $PRESERVE_HYPERSHIFT_ZONE"
  fi
}

delete_non_default_rrsets_in_zone() {
  local zone_id="$1"
  local rr_count change_batch

  rr_count="$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --query 'length(ResourceRecordSets[?Type!=`NS` && Type!=`SOA`])' \
    --output text \
    --no-cli-pager 2>/dev/null || echo "0")"

  if [[ "${rr_count:-0}" == "0" ]]; then
    log "No non-default records to delete for hosted zone $zone_id"
    return 0
  fi

  change_batch="$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --query '{Changes: ResourceRecordSets[?Type!=`NS` && Type!=`SOA`].{Action:`DELETE`,ResourceRecordSet:@}}' \
    --output json \
    --no-cli-pager 2>/dev/null || true)"

  if [[ -z "${change_batch:-}" || "$change_batch" == "{}" ]]; then
    log "Could not build change batch for hosted zone $zone_id; skipping record deletion"
    return 1
  fi

  if aws route53 change-resource-record-sets \
    --hosted-zone-id "$zone_id" \
    --change-batch "$change_batch" \
    --no-cli-pager >/dev/null 2>&1; then
    log "Deleted non-default records for hosted zone $zone_id"
    return 0
  fi

  log "WARNING: Failed deleting non-default records for hosted zone $zone_id"
  return 1
}

get_private_zone_vpc_ids() {
  local zone_id="$1"
  aws route53 get-hosted-zone \
    --id "$zone_id" \
    --query 'VPCs[].VPCId' \
    --output text \
    --no-cli-pager 2>/dev/null || true
}

delete_hosted_zone_safely() {
  local zone_id="$1"
  local zone_name="$2"

  log "Preparing hosted zone deletion: id=$zone_id name=$zone_name"
  delete_non_default_rrsets_in_zone "$zone_id" || true

  if aws route53 delete-hosted-zone --id "$zone_id" --no-cli-pager >/dev/null 2>&1; then
    log "Deleted hosted zone: id=$zone_id name=$zone_name"
  else
    log "WARNING: Could not delete hosted zone: id=$zone_id name=$zone_name (remaining records or associations likely)"
  fi
}

log_remaining_vpc_instances() {
  local vpc_id="$1"
  local row instance_id name_tag state private_ip launch_time

  while IFS= read -r row; do
    [[ -z "${row:-}" ]] && continue
    IFS=$'\t' read -r instance_id name_tag state private_ip launch_time <<< "$row"
    [[ -z "${instance_id:-}" || "$instance_id" == "None" ]] && continue
    [[ -z "${name_tag:-}" || "$name_tag" == "None" ]] && name_tag="-"
    [[ -z "${private_ip:-}" || "$private_ip" == "None" ]] && private_ip="-"
    [[ -z "${launch_time:-}" || "$launch_time" == "None" ]] && launch_time="-"
    log "Remaining instance: id=$instance_id name=$name_tag state=$state private_ip=$private_ip launch_time=$launch_time"
  done < <(
    aws ec2 describe-instances \
      --region "$REGION" \
      --filters Name=vpc-id,Values="$vpc_id" Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
      --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value,State.Name,PrivateIpAddress,LaunchTime]' \
      --output text \
      --no-cli-pager 2>/dev/null || true
  )
}

cleanup_orphaned_rosa_workers() {
  local vpc_id="$1"
  local row instance_id name_tag api_name red_hat_managed state
  local matched_count

  matched_count=0
  log "Checking for orphaned ROSA worker instances in VPC $vpc_id"

  while IFS= read -r row; do
    [[ -z "${row:-}" ]] && continue
    IFS=$'\t' read -r instance_id name_tag api_name red_hat_managed state <<< "$row"
    [[ -z "${instance_id:-}" || "$instance_id" == "None" ]] && continue

    [[ -z "${name_tag:-}" || "$name_tag" == "None" ]] && name_tag=""
    [[ -z "${api_name:-}" || "$api_name" == "None" ]] && api_name=""
    [[ -z "${red_hat_managed:-}" || "$red_hat_managed" == "None" ]] && red_hat_managed=""

    if [[ "$name_tag" == "${CLUSTER_NAME}-workers-"* ]] || [[ "$api_name" == "$CLUSTER_NAME" && "$red_hat_managed" == "true" ]]; then
      log "Terminating orphaned ROSA worker instance: id=$instance_id name=${name_tag:--} state=${state:-unknown} api.openshift.com/name=${api_name:--} red-hat-managed=${red_hat_managed:--}"
      aws ec2 terminate-instances \
        --region "$REGION" \
        --instance-ids "$instance_id" \
        --no-cli-pager >/dev/null 2>&1 || true
      matched_count=$((matched_count + 1))
    fi
  done < <(
    aws ec2 describe-instances \
      --region "$REGION" \
      --filters Name=vpc-id,Values="$vpc_id" Name=instance-state-name,Values=pending,running,stopping,stopped \
      --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value,Tags[?Key==`api.openshift.com/name`]|[0].Value,Tags[?Key==`red-hat-managed`]|[0].Value,State.Name]' \
      --output text \
      --no-cli-pager 2>/dev/null || true
  )

  if [[ "$matched_count" == "0" ]]; then
    log "No clearly matched orphaned ROSA worker instances found to terminate"
  else
    log "Requested termination for $matched_count orphaned ROSA worker instance(s)"
  fi
}

cleanup_stale_rosa_route53_zones() {
  local current_vpc_id="${1:-}"
  local final_cleanup="${2:-false}"
  local zone_id_raw zone_id zone_name_raw zone_name private_flag
  local is_rosa_pattern is_hypershift_pattern zone_type vpc_ids associated_vpc

  log "Starting stale Route 53 ROSA zone cleanup for cluster '$CLUSTER_NAME'"

  while IFS=$'\t' read -r zone_id_raw zone_name_raw private_flag; do
    [[ -z "${zone_id_raw:-}" ]] && continue

    zone_id="${zone_id_raw#/hostedzone/}"
    zone_name="$(normalize_zone_name "$zone_name_raw")"

    is_rosa_pattern="false"
    is_hypershift_pattern="false"

    if [[ "$zone_name" == rosa.${CLUSTER_NAME}.*.openshiftapps.com. ]]; then
      is_rosa_pattern="true"
    fi

    if [[ "$zone_name" == "${CLUSTER_NAME}.hypershift.local." ]]; then
      is_hypershift_pattern="true"
    fi

    if [[ "$is_rosa_pattern" != "true" && "$is_hypershift_pattern" != "true" ]]; then
      continue
    fi

    zone_type="public"
    if [[ "$private_flag" == "True" ]]; then
      zone_type="private"
    fi

    log "Route53 candidate: id=$zone_id name=$zone_name type=$zone_type"

    if [[ "$final_cleanup" != "true" ]]; then
      if [[ -n "${PRESERVE_ROSA_ZONE:-}" && "$zone_name" == "$PRESERVE_ROSA_ZONE" ]]; then
        log "Preserving hosted zone id=$zone_id name=$zone_name (initial cleanup pass keeps current cluster DNS zone)"
        continue
      fi
      if [[ -n "${PRESERVE_HYPERSHIFT_ZONE:-}" && "$zone_name" == "$PRESERVE_HYPERSHIFT_ZONE" ]]; then
        log "Preserving hosted zone id=$zone_id name=$zone_name (initial cleanup pass keeps current hypershift zone)"
        continue
      fi
    fi

    if [[ "$is_hypershift_pattern" == "true" ]]; then
      if [[ "$private_flag" == "True" ]]; then
        vpc_ids="$(get_private_zone_vpc_ids "$zone_id")"
        log "Hypershift zone VPC associations for id=$zone_id: ${vpc_ids:-none}"
        if [[ -n "${current_vpc_id:-}" ]]; then
          for associated_vpc in $vpc_ids; do
            if [[ "$associated_vpc" == "$current_vpc_id" ]]; then
              log "Preserving hosted zone id=$zone_id name=$zone_name (associated with current teardown VPC $current_vpc_id)"
              continue 2
            fi
          done
        fi
      fi
    fi

    log "Deleting stale hosted zone id=$zone_id name=$zone_name"
    delete_hosted_zone_safely "$zone_id" "$zone_name"
  done < <(
    aws route53 list-hosted-zones \
      --query 'HostedZones[].[Id,Name,Config.PrivateZone]' \
      --output text \
      --no-cli-pager 2>/dev/null || true
  )

  log "Completed stale Route 53 ROSA zone cleanup for cluster '$CLUSTER_NAME'"
}

dump_vpc_dependencies() {
  local vpc_id="$1"

  if [[ -z "${vpc_id:-}" ]]; then
    log "No VPC ID provided for diagnostics"
    return
  fi

  log "Dumping diagnostics for VPC $vpc_id in $REGION..."

  log "--- Instances ---"
  aws ec2 describe-instances \
    --region "$REGION" \
    --filters Name=vpc-id,Values="$vpc_id" Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
    --query 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Type:InstanceType,SubnetId:SubnetId}' \
    --no-cli-pager || true

  log "--- ENIs ---"
  aws ec2 describe-network-interfaces \
    --region "$REGION" \
    --filters Name=vpc-id,Values="$vpc_id" \
    --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Status:Status,Desc:Description,Subnet:SubnetId,PrivateIp:PrivateIpAddress,Groups:Groups[*].GroupId}' \
    --no-cli-pager || true

  log "--- ELBv2 Load Balancers ---"
  aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --query "LoadBalancers[?VpcId=='$vpc_id']" \
    --no-cli-pager || true

  log "--- Target Groups ---"
  aws elbv2 describe-target-groups \
    --region "$REGION" \
    --query "TargetGroups[?VpcId=='$vpc_id']" \
    --no-cli-pager || true

  log "--- VPC Endpoints ---"
  aws ec2 describe-vpc-endpoints \
    --region "$REGION" \
    --filters Name=vpc-id,Values="$vpc_id" \
    --no-cli-pager || true

  log "--- NAT Gateways ---"
  aws ec2 describe-nat-gateways \
    --region "$REGION" \
    --filter Name=vpc-id,Values="$vpc_id" \
    --query 'NatGateways[?State!=`deleted`]' \
    --no-cli-pager || true

  log "--- Security Groups ---"
  aws ec2 describe-security-groups \
    --region "$REGION" \
    --filters Name=vpc-id,Values="$vpc_id" \
    --query 'SecurityGroups[?GroupName!=`default`]' \
    --no-cli-pager || true

  log "--- Subnets ---"
  aws ec2 describe-subnets \
    --region "$REGION" \
    --filters Name=vpc-id,Values="$vpc_id" \
    --no-cli-pager || true

  log "--- Internet Gateways ---"
  aws ec2 describe-internet-gateways \
    --region "$REGION" \
    --filters Name=attachment.vpc-id,Values="$vpc_id" \
    --no-cli-pager || true

  log "--- Elastic IPs attached to ENIs in VPC ---"
  EIP_ENI_IDS=()
  while IFS= read -r item; do
    [[ -n "$item" ]] && EIP_ENI_IDS+=("$item")
  done < <(
    aws ec2 describe-network-interfaces \
      --region "$REGION" \
      --filters Name=vpc-id,Values="$vpc_id" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' \
      --output text \
      --no-cli-pager | tr '\t' '\n' | sed '/^$/d'
  )
  if [[ ${#EIP_ENI_IDS[@]} -gt 0 ]]; then
    aws ec2 describe-addresses \
      --region "$REGION" \
      --filters Name=network-interface-id,Values="$(IFS=,; echo "${EIP_ENI_IDS[*]}")" \
      --no-cli-pager || true
  else
    log "No ENIs found in VPC for EIP attachment lookup"
  fi
}

pre_destroy_lb_check() {
  local output api_url password lb_lines all_lb_lines user_lb_lines namespaces namespace_list delete_cmds
  local route_lines user_route_lines
  local login_retry_seconds login_max_wait_minutes login_max_waits login_count

  log "Pre-check: rotating cluster-admin credentials and logging into OpenShift"

  login_retry_seconds=20
  login_max_wait_minutes=10

  rosa delete admin --cluster "$CLUSTER_NAME" --yes >/dev/null 2>&1 || true
  if ! rosa create admin --cluster "$CLUSTER_NAME" >"$ADMIN_OUT" 2>&1; then
    log "WARNING: Could not create fresh cluster-admin credentials; skipping OpenShift pre-check"
    return
  fi

  if ! output="$(rosa describe cluster --cluster "$CLUSTER_NAME" 2>/dev/null)"; then
    log "Could not describe ROSA cluster '$CLUSTER_NAME'; skipping OpenShift pre-check"
    return
  fi

  api_url="$(echo "$output" | awk -F': ' '/^API URL:/ {print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -z "${api_url:-}" ]]; then
    log "Could not determine API URL for cluster '$CLUSTER_NAME'; skipping OpenShift pre-check"
    return
  fi

  password="$(awk '/^[[:space:]]*oc login /{
    for (i=1; i<=NF; i++) {
      if ($i == "--password") {
        print $(i+1)
        exit
      }
    }
  }' "$ADMIN_OUT")"

  if [[ -z "${password:-}" ]]; then
    log "WARNING: Could not parse fresh cluster-admin password from $ADMIN_OUT; skipping OpenShift pre-check"
    return
  fi

  login_max_waits=$(( login_max_wait_minutes * 60 / login_retry_seconds ))
  login_count=0

  while true; do
    if oc login "$api_url" -u cluster-admin -p "$password" >/dev/null 2>&1; then
      break
    fi

    login_count=$((login_count + 1))
    if [[ "$login_count" -ge "$login_max_waits" ]]; then
      log "WARNING: oc login failed after waiting ${login_max_wait_minutes} minutes; skipping OpenShift pre-check"
      return
    fi

    log "cluster-admin login not active yet; retrying in ${login_retry_seconds}s..."
    sleep "$login_retry_seconds"
  done

  all_lb_lines="$(oc get svc -A --no-headers \
    -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,TYPE:.spec.type' 2>/dev/null \
    | awk '$3 == "LoadBalancer" {print $1 "/" $2}' || true)"

  if [[ -z "${all_lb_lines:-}" ]]; then
    log "No OpenShift LoadBalancer services found"

    route_lines="$(oc get route -A --no-headers 2>/dev/null | awk '{print $1 "/" $2}' || true)"
    user_route_lines="$(echo "$route_lines" | grep -Ev '^(openshift-|kube-)' || true)"
    if [[ -n "${user_route_lines:-}" ]]; then
      log "WARNING: Detected non-system Routes still present:"
      echo "$user_route_lines"
      log "WARNING: These Routes do not block teardown, but may indicate published user apps still exist"
    else
      log "No non-system Routes found"
    fi

    return
  fi

  user_lb_lines="$(echo "$all_lb_lines" | grep -Ev '^(openshift-|kube-)' || true)"
  lb_lines="$user_lb_lines"

  if [[ -n "${lb_lines:-}" ]]; then
    namespaces="$(echo "$lb_lines" | awk -F'/' '{print $1}' | sort -u)"
    namespace_list="$(echo "$namespaces" | sed 's/^/  - /')"
    delete_cmds="$(echo "$namespaces" | awk '{print "  oc delete namespace " $1}')"

    log "Detected LoadBalancer services:"
    echo "$lb_lines"

    log "Delete the offending namespace(s) before continuing:"
    echo "$namespace_list"
    log "Suggested commands:"
    echo "$delete_cmds"

    exit 1
  fi

  log "Only system LoadBalancer services detected (openshift/kube namespaces); continuing teardown"

  route_lines="$(oc get route -A --no-headers 2>/dev/null | awk '{print $1 "/" $2}' || true)"
  user_route_lines="$(echo "$route_lines" | grep -Ev '^(openshift-|kube-)' || true)"
  if [[ -n "${user_route_lines:-}" ]]; then
    log "WARNING: Detected non-system Routes still present:"
    echo "$user_route_lines"
    log "WARNING: These Routes do not block teardown, but may indicate published user apps still exist"
  else
    log "No non-system Routes found"
  fi
}

cd "$TF_DIR"

for cmd in terraform rosa oc aws; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "ERROR: Required command '$cmd' is not installed or not in PATH"
    exit 1
  fi
done

select_workspace_and_cluster "$@"

LOG_FILE="$GITHUB/cloud-lab/scripts/teardown-${WORKSPACE}.log"
ADMIN_OUT="$GITHUB/cloud-lab/scripts/${CLUSTER_NAME}-admin.out"
exec > >(tee "$LOG_FILE") 2>&1

log "Script: $(basename "$0")"
log "Log file: $LOG_FILE"
log "Admin output file: $ADMIN_OUT"
log "Script started"
log "Terraform dir: $TF_DIR"
log "Workspace: $WORKSPACE"
log "Cluster: $CLUSTER_NAME"
log "Using workspace/cluster pair: $WORKSPACE / $CLUSTER_NAME"
log "Region: $REGION"

log "Selecting terraform workspace..."
if ! terraform workspace select "$WORKSPACE" >/dev/null 2>&1; then
  log "ERROR: Terraform workspace '$WORKSPACE' does not exist. Run 'terraform workspace list' and create/select it before running teardown."
  exit 1
fi

capture_current_rosa_zone_context

pre_destroy_lb_check

log "Phase 1: destroy ROSA resources only..."
if ! terraform destroy -auto-approve -no-color -target='module.rosa'; then
  log "WARNING: Phase 1 targeted destroy returned non-zero; continuing with RHCS/AWS cleanup flow"
fi

log "Waiting for ROSA cluster '$CLUSTER_NAME' to disappear from RHCS..."
MAX_RHCS_WAITS=$(( MAX_WAIT_MINUTES * 60 / POLL_SECONDS ))
RHCS_WAIT_COUNT=0
while rosa describe cluster --cluster "$CLUSTER_NAME" >/dev/null 2>&1; do
  log "Cluster still present in RHCS; waiting ${POLL_SECONDS}s..."
  RHCS_WAIT_COUNT=$((RHCS_WAIT_COUNT + 1))
  if [[ "$RHCS_WAIT_COUNT" -ge "$MAX_RHCS_WAITS" ]]; then
    log "ERROR: Timed out waiting for ROSA cluster '$CLUSTER_NAME' to disappear from RHCS"
    exit 1
  fi
  sleep "$POLL_SECONDS"
done

log "Cluster no longer found in RHCS"
log "Waiting ${SETTLE_SECONDS}s for AWS-side cleanup to settle..."
sleep "$SETTLE_SECONDS"

log "Discovering VPC ID from Terraform state..."
VPC_STATE_ADDR="$(terraform state list 2>/dev/null | grep '^aws_vpc\.vpcs' | head -n1 || true)"

if [[ -z "${VPC_STATE_ADDR:-}" ]]; then
  log "ERROR: No aws_vpc.vpcs resource found in Terraform state"
  log "Terraform state list output:"
  terraform state list || true
  exit 1
fi

log "Discovered VPC state address: $VPC_STATE_ADDR"

VPC_ID="$(terraform state show "$VPC_STATE_ADDR" 2>/dev/null | awk '/^[[:space:]]*id[[:space:]]*=/ {gsub(/"/,"",$3); print $3; exit}')"

if [[ -z "${VPC_ID:-}" ]]; then
  log "ERROR: Could not parse VPC ID from Terraform state address: $VPC_STATE_ADDR"
  log "Terraform state show output for $VPC_STATE_ADDR:"
  terraform state show "$VPC_STATE_ADDR" || true
  exit 1
fi

log "Discovered VPC_ID=$VPC_ID"

if [[ -n "${VPC_ID:-}" ]]; then
  log "Found VPC_ID=$VPC_ID"

  log "Looking up Terraform-managed baseline security group..."
  TF_SG_STATE_ADDR="$(terraform state list 2>/dev/null | grep '^aws_security_group\.base' | head -n1 || true)"
  TF_SG_ID=""
  if [[ -n "${TF_SG_STATE_ADDR:-}" ]]; then
    TF_SG_ID="$(terraform state show "$TF_SG_STATE_ADDR" 2>/dev/null | awk '/^[[:space:]]*id[[:space:]]*=/ {gsub(/"/,"",$3); print $3; exit}' || true)"
  fi
  if [[ -n "${TF_SG_ID:-}" ]]; then
    log "Terraform-managed SG=$TF_SG_ID (will be excluded from wait-loop SG count)"
    SG_QUERY="length(SecurityGroups[?GroupName!=\`default\` && GroupId!=\`${TF_SG_ID}\`])"
  else
    log "No Terraform-managed SG found in state"
    SG_QUERY='length(SecurityGroups[?GroupName!=`default`])'
  fi

  log "Deleting any ELBv2 load balancers in VPC..."
  LB_ARNS=()
  while IFS= read -r item; do
    [[ -n "$item" ]] && LB_ARNS+=("$item")
  done < <(
    aws elbv2 describe-load-balancers \
      --region "$REGION" \
      --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" \
      --output text \
      --no-cli-pager | tr '\t' '\n' | sed '/^$/d'
  )

  for LB_ARN in "${LB_ARNS[@]:-}"; do
    log "Deleting load balancer: $LB_ARN"
    aws elbv2 delete-load-balancer \
      --region "$REGION" \
      --load-balancer-arn "$LB_ARN" \
      --no-cli-pager || true
  done

  sleep 30

  log "Deleting any ELBv2 target groups in VPC..."
  TG_ARNS=()
  while IFS= read -r item; do
    [[ -n "$item" ]] && TG_ARNS+=("$item")
  done < <(
    aws elbv2 describe-target-groups \
      --region "$REGION" \
      --query "TargetGroups[?VpcId=='$VPC_ID'].TargetGroupArn" \
      --output text \
      --no-cli-pager | tr '\t' '\n' | sed '/^$/d'
  )

  for TG_ARN in "${TG_ARNS[@]:-}"; do
    log "Deleting target group: $TG_ARN"
    aws elbv2 delete-target-group \
      --region "$REGION" \
      --target-group-arn "$TG_ARN" \
      --no-cli-pager || true
  done

  log "Deleting any VPC endpoints in VPC..."
  VPCE_IDS=()
  while IFS= read -r item; do
    [[ -n "$item" ]] && VPCE_IDS+=("$item")
  done < <(
    aws ec2 describe-vpc-endpoints \
      --region "$REGION" \
      --filters Name=vpc-id,Values="$VPC_ID" \
      --query 'VpcEndpoints[].VpcEndpointId' \
      --output text \
      --no-cli-pager | tr '\t' '\n' | sed '/^$/d'
  )

  if [[ ${#VPCE_IDS[@]} -gt 0 ]]; then
    aws ec2 delete-vpc-endpoints \
      --region "$REGION" \
      --vpc-endpoint-ids "${VPCE_IDS[@]}" \
      --no-cli-pager || true
  fi

  log "Deleting any NAT gateways in VPC..."
  NAT_IDS=()
  while IFS= read -r item; do
    [[ -n "$item" ]] && NAT_IDS+=("$item")
  done < <(
    aws ec2 describe-nat-gateways \
      --region "$REGION" \
      --filter Name=vpc-id,Values="$VPC_ID" \
      --query 'NatGateways[?State!=`deleted`].NatGatewayId' \
      --output text \
      --no-cli-pager | tr '\t' '\n' | sed '/^$/d'
  )

  for NAT_ID in "${NAT_IDS[@]:-}"; do
    [[ -z "$NAT_ID" ]] && continue
    log "Deleting NAT gateway: $NAT_ID"
    aws ec2 delete-nat-gateway \
      --region "$REGION" \
      --nat-gateway-id "$NAT_ID" \
      --no-cli-pager || true
  done

  log "Waiting for VPC dependencies to clear..."
  MAX_WAITS=$(( MAX_WAIT_MINUTES * 60 / POLL_SECONDS ))
  COUNT=0

  while true; do
    INSTANCE_COUNT="$(aws ec2 describe-instances \
      --region "$REGION" \
      --filters Name=vpc-id,Values="$VPC_ID" Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down \
      --query 'length(Reservations[].Instances[])' \
      --output text \
      --no-cli-pager)"

    ENI_COUNT="$(aws ec2 describe-network-interfaces \
      --region "$REGION" \
      --filters Name=vpc-id,Values="$VPC_ID" \
      --query 'length(NetworkInterfaces)' \
      --output text \
      --no-cli-pager)"

    VPCE_COUNT="$(aws ec2 describe-vpc-endpoints \
      --region "$REGION" \
      --filters Name=vpc-id,Values="$VPC_ID" \
      --query 'length(VpcEndpoints)' \
      --output text \
      --no-cli-pager)"

    LB_COUNT="$(aws elbv2 describe-load-balancers \
      --region "$REGION" \
      --query "length(LoadBalancers[?VpcId=='$VPC_ID'])" \
      --output text \
      --no-cli-pager)"

    TG_COUNT="$(aws elbv2 describe-target-groups \
      --region "$REGION" \
      --query "length(TargetGroups[?VpcId=='$VPC_ID'])" \
      --output text \
      --no-cli-pager)"

    NAT_COUNT="$(aws ec2 describe-nat-gateways \
      --region "$REGION" \
      --filter Name=vpc-id,Values="$VPC_ID" \
      --query 'length(NatGateways[?State!=`deleted`])' \
      --output text \
      --no-cli-pager)"

    SG_COUNT="$(aws ec2 describe-security-groups \
      --region "$REGION" \
      --filters Name=vpc-id,Values="$VPC_ID" \
      --query "$SG_QUERY" \
      --output text \
      --no-cli-pager)"

    log "Dependency check: instances=$INSTANCE_COUNT enis=$ENI_COUNT vpces=$VPCE_COUNT lbs=$LB_COUNT tgs=$TG_COUNT nat=$NAT_COUNT sgs=$SG_COUNT"

    if [[ "$INSTANCE_COUNT" == "0" && "$ENI_COUNT" == "0" && "$VPCE_COUNT" == "0" && "$LB_COUNT" == "0" && "$TG_COUNT" == "0" && "$NAT_COUNT" == "0" ]]; then
      break
    fi

    if [[ "$INSTANCE_COUNT" != "0" ]]; then
      log "Instances still present in teardown VPC; listing details"
      log_remaining_vpc_instances "$VPC_ID"
    fi

    COUNT=$((COUNT + 1))
    if [[ "$INSTANCE_COUNT" != "0" && "$COUNT" -ge "$ORPHAN_WORKER_TERMINATE_AFTER_CYCLES" ]]; then
      log "Instance threshold reached after $COUNT polling cycle(s); attempting conservative orphaned ROSA worker cleanup"
      log_remaining_vpc_instances "$VPC_ID"
      cleanup_orphaned_rosa_workers "$VPC_ID"
    fi

    if [[ "$COUNT" -ge "$MAX_WAITS" ]]; then
      log "Timed out waiting for dependencies to clear. Dumping diagnostics."

      dump_vpc_dependencies "$VPC_ID"

      break
    fi

    sleep "$POLL_SECONDS"
  done

  log "Attempting cleanup of any remaining non-default security groups in VPC $VPC_ID..."
  if [[ -n "${TF_SG_ID:-}" ]]; then
    SG_IDS=()
    while IFS= read -r item; do
      [[ -n "$item" ]] && SG_IDS+=("$item")
    done < <(
      aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters Name=vpc-id,Values="$VPC_ID" \
        --query "SecurityGroups[?GroupName!=\`default\` && GroupId!=\`${TF_SG_ID}\`].GroupId" \
        --output text \
        --no-cli-pager | tr '\t' '\n' | sed '/^$/d'
    )
  else
    SG_IDS=()
    while IFS= read -r item; do
      [[ -n "$item" ]] && SG_IDS+=("$item")
    done < <(
      aws ec2 describe-security-groups \
        --region "$REGION" \
        --filters Name=vpc-id,Values="$VPC_ID" \
        --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
        --output text \
        --no-cli-pager | tr '\t' '\n' | sed '/^$/d'
    )
  fi

  # First pass: revoke all ingress/egress rules to break cross-references
  for SG_ID in "${SG_IDS[@]:-}"; do
    [[ -z "$SG_ID" ]] && continue
    log "Revoking rules for security group: $SG_ID"
    ingress="$(aws ec2 describe-security-groups \
      --region "$REGION" \
      --group-ids "$SG_ID" \
      --query 'SecurityGroups[0].IpPermissions' \
      --output json \
      --no-cli-pager 2>/dev/null || echo '[]')"
    if [[ "$ingress" != "[]" && "$ingress" != "null" ]]; then
      aws ec2 revoke-security-group-ingress \
        --region "$REGION" \
        --group-id "$SG_ID" \
        --ip-permissions "$ingress" \
        --no-cli-pager 2>/dev/null || true
    fi
    egress="$(aws ec2 describe-security-groups \
      --region "$REGION" \
      --group-ids "$SG_ID" \
      --query 'SecurityGroups[0].IpPermissionsEgress' \
      --output json \
      --no-cli-pager 2>/dev/null || echo '[]')"
    if [[ "$egress" != "[]" && "$egress" != "null" ]]; then
      aws ec2 revoke-security-group-egress \
        --region "$REGION" \
        --group-id "$SG_ID" \
        --ip-permissions "$egress" \
        --no-cli-pager 2>/dev/null || true
    fi
  done

  # Second pass: delete the security groups
  for SG_ID in "${SG_IDS[@]:-}"; do
    [[ -z "$SG_ID" ]] && continue
    log "Deleting security group: $SG_ID"
    aws ec2 delete-security-group \
      --region "$REGION" \
      --group-id "$SG_ID" \
      --no-cli-pager || true
  done

  log "Initial Route53 cleanup pass: removing stale old ROSA zones while preserving current cluster zones"
  cleanup_stale_rosa_route53_zones "$VPC_ID" false
fi

log "Phase 2: destroy remaining Terraform-managed infrastructure..."
if terraform destroy -auto-approve -no-color; then
  log "Final Route53 cleanup pass: removing remaining ROSA zones including the just-torn-down cluster zones"
  cleanup_stale_rosa_route53_zones "" true
  log "Teardown completed successfully"
else
  log "ERROR: Phase 2 terraform destroy failed."
  if [[ -n "${VPC_ID:-}" ]]; then
    dump_vpc_dependencies "$VPC_ID"
  fi
  exit 1
fi