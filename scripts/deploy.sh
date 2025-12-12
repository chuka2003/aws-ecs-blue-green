#!/usr/bin/env bash
set -euo pipefail

########################################
# Arguments
########################################
AWS_REGION="${1:-}"
CLUSTER="${2:-}"
SERVICE="${3:-}"
IMAGE="${4:-}"
CONTAINER_NAME="${5:-}"
LISTENER_ARN="${6:-}"
SHIFT_STEPS="${7:-10}"
SHIFT_INTERVAL="${8:-15}"

########################################
# Logging helpers
########################################
log()  { echo "[INFO ] $*"; }
warn() { echo "[WARN ] $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }

if [[ -z "$AWS_REGION" || -z "$CLUSTER" || -z "$SERVICE" || -z "$LISTENER_ARN" ]]; then
  err "Missing required arguments. Usage:"
  err "deploy.sh <aws-region> <cluster> <service> <image> <container-name> <listener-arn> <shift-steps> <shift-interval-seconds>"
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  err "aws CLI is not installed or not in PATH."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required but not installed. Please ensure jq is available on the runner."
  exit 1
fi

log "Region:           $AWS_REGION"
log "Cluster:          $CLUSTER"
log "Service:          $SERVICE"
log "Image override:   ${IMAGE:-<none>}"
log "Container name:   ${CONTAINER_NAME:-<none>}"
log "Listener ARN:     $LISTENER_ARN"
log "Shift steps:      $SHIFT_STEPS"
log "Shift interval:   $SHIFT_INTERVAL seconds"

########################################
# 1. Discover current service and task definition
########################################
log "Describing ECS service..."

SERVICE_JSON=$(aws ecs describe-services \
  --region "$AWS_REGION" \
  --cluster "$CLUSTER" \
  --services "$SERVICE")

FAILURE_COUNT=$(echo "$SERVICE_JSON" | jq -r '.failures | length')
if [[ "$FAILURE_COUNT" -gt 0 ]]; then
  err "Failed to describe ECS service. Response:"
  echo "$SERVICE_JSON"
  exit 1
fi

CURRENT_TASK_DEF_ARN=$(echo "$SERVICE_JSON" | jq -r '.services[0].taskDefinition')
log "Current task definition: $CURRENT_TASK_DEF_ARN"

########################################
# 2. Create new task definition revision (if image override is provided)
########################################
NEW_TASK_DEF_ARN="$CURRENT_TASK_DEF_ARN"

if [[ -n "${IMAGE:-}" && -n "${CONTAINER_NAME:-}" ]]; then
  log "Image and container name provided. Creating new task definition revision with updated image..."

  # Get existing task definition JSON
  TD_JSON=$(aws ecs describe-task-definition \
    --region "$AWS_REGION" \
    --task-definition "$CURRENT_TASK_DEF_ARN")

  FAMILY=$(echo "$TD_JSON" | jq -r '.taskDefinition.family')
  REQUIRES_COMPATIBILITIES=$(echo "$TD_JSON" | jq -c '.taskDefinition.requiresCompatibilities')
  NETWORK_MODE=$(echo "$TD_JSON" | jq -r '.taskDefinition.networkMode')
  CPU=$(echo "$TD_JSON" | jq -r '.taskDefinition.cpu')
  MEMORY=$(echo "$TD_JSON" | jq -r '.taskDefinition.memory')
  EXECUTION_ROLE_ARN=$(echo "$TD_JSON" | jq -r '.taskDefinition.executionRoleArn // empty')
  TASK_ROLE_ARN=$(echo "$TD_JSON" | jq -r '.taskDefinition.taskRoleArn // empty')
  VOLUMES=$(echo "$TD_JSON" | jq -c '.taskDefinition.volumes')
  PLACEMENT_CONSTRAINTS=$(echo "$TD_JSON" | jq -c '.taskDefinition.placementConstraints')

  # Update container image
  CONTAINERS_UPDATED=$(echo "$TD_JSON" \
    | jq --arg cname "$CONTAINER_NAME" --arg img "$IMAGE" '
        .taskDefinition.containerDefinitions
        | map(if .name == $cname then .image = $img else . end)
      ')

  if [[ "$(echo "$CONTAINERS_UPDATED" | jq 'map(select(.image == $IMAGE))' --arg IMAGE "$IMAGE" | jq 'length')" -eq 0 ]]; then
    warn "No container named '$CONTAINER_NAME' found in task definition. Using original image(s)."
  fi

  # Register new revision
  REGISTER_ARGS=(
    ecs register-task-definition
    --region "$AWS_REGION"
    --family "$FAMILY"
    --network-mode "$NETWORK_MODE"
    --requires-compatibilities "$REQUIRES_COMPATIBILITIES"
    --cpu "$CPU"
    --memory "$MEMORY"
    --container-definitions "$CONTAINERS_UPDATED"
    --volumes "$VOLUMES"
    --placement-constraints "$PLACEMENT_CONSTRAINTS"
  )

  if [[ -n "$EXECUTION_ROLE_ARN" ]]; then
    REGISTER_ARGS+=(--execution-role-arn "$EXECUTION_ROLE_ARN")
  fi
  if [[ -n "$TASK_ROLE_ARN" ]]; then
    REGISTER_ARGS+=(--task-role-arn "$TASK_ROLE_ARN")
  fi

  log "Registering new task definition..."
  REGISTER_JSON=$(aws "${REGISTER_ARGS[@]}")
  NEW_TASK_DEF_ARN=$(echo "$REGISTER_JSON" | jq -r '.taskDefinition.taskDefinitionArn')

  log "New task definition registered: $NEW_TASK_DEF_ARN"
else
  log "No image override/container name provided. Reusing current task definition."
fi

########################################
# 3. Update ECS service to use new task def
########################################
if [[ "$NEW_TASK_DEF_ARN" != "$CURRENT_TASK_DEF_ARN" ]]; then
  log "Updating ECS service to use new task definition..."

  aws ecs update-service \
    --region "$AWS_REGION" \
    --cluster "$CLUSTER" \
    --service "$SERVICE" \
    --task-definition "$NEW_TASK_DEF_ARN" >/dev/null

  log "Waiting for ECS service to stabilize..."
  aws ecs wait services-stable \
    --region "$AWS_REGION" \
    --cluster "$CLUSTER" \
    --services "$SERVICE"

  log "Service is stable on new task definition."
else
  log "Task definition unchanged. Skipping service update."
fi

########################################
# 4. Blue-Green traffic shifting on ALB listener
#
# This section assumes:
#   - There are TWO target groups attached to the listener (blue & green).
#   - Their ARNs are provided via env vars:
#       BLUE_TG_ARN, GREEN_TG_ARN
#   - 'blue' currently has 100% traffic, 'green' has 0%.
#
# The script will gradually shift from blue -> green over SHIFT_STEPS.
########################################

if [[ -z "${BLUE_TG_ARN:-}" || -z "${GREEN_TG_ARN:-}" ]]; then
  warn "BLUE_TG_ARN or GREEN_TG_ARN not set. Skipping ALB blue-green traffic shifting."
  exit 0
fi

log "Starting traffic shift from BLUE ($BLUE_TG_ARN) to GREEN ($GREEN_TG_ARN)..."

# Optional sanity check: describe listener (ensure it exists and is accessible)
aws elbv2 describe-listeners \
  --region "$AWS_REGION" \
  --listener-arns "$LISTENER_ARN" >/dev/null

log "Listener retrieved. Beginning weighted shifts..."

# Shift in N steps
for (( step=1; step<=SHIFT_STEPS; step++ )); do
  NEW_WEIGHT=$(( (step * 100) / SHIFT_STEPS ))
  OLD_WEIGHT=$(( 100 - NEW_WEIGHT ))

  log "Step $step/$SHIFT_STEPS: GREEN=$NEW_WEIGHT%, BLUE=$OLD_WEIGHT%"

  aws elbv2 modify-listener \
    --region "$AWS_REGION" \
    --listener-arn "$LISTENER_ARN" \
    --default-actions "Type=forward,ForwardConfig={TargetGroups=[{TargetGroupArn=\"$GREEN_TG_ARN\",Weight=$NEW_WEIGHT},{TargetGroupArn=\"$BLUE_TG_ARN\",Weight=$OLD_WEIGHT}]}"

  if [[ "$step" -lt "$SHIFT_STEPS" ]]; then
    log "Sleeping ${SHIFT_INTERVAL}s before next shift..."
    sleep "$SHIFT_INTERVAL"
  fi
done

log "Traffic shift complete: 100% to GREEN ($GREEN_TG_ARN)."
log "Blue-Green deployment finished successfully."
