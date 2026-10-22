#!/usr/bin/env bash
# Manual blue/green deployment: point a service at the task definition revision
# Terraform last registered. Same thing the pipeline does, by hand.
# Run from the infra/ folder.
#
# Usage: ./scripts/deploy.sh frontend|backend
set -euo pipefail

SVC="${1:?usage: ./scripts/deploy.sh frontend|backend}"
REGION="eu-north-1"

case "$SVC" in
  frontend|backend) ;;
  *) echo "service must be frontend or backend"; exit 1 ;;
esac

CLUSTER=$(terraform output -raw cluster_name)
SERVICE=$(terraform output -raw "${SVC}_service")
TD=$(terraform output -raw "${SVC}_task_definition")

echo "Service:         $SERVICE"
echo "Task definition: $TD"

aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" \
  --task-definition "$TD" --query 'service.serviceName' --output text >/dev/null

sleep 5
ARN=$(aws ecs list-service-deployments --region "$REGION" --cluster "$CLUSTER" --service "$SERVICE" \
  --query 'sort_by(serviceDeployments,&createdAt)[-1].serviceDeploymentArn' --output text)

echo
echo "Deployment: $ARN"
echo "Roll back while it's in BAKE_TIME:"
echo "  aws ecs stop-service-deployment --region $REGION --service-deployment-arn $ARN --stop-type ROLLBACK"
echo

while true; do
  read -r STATUS STAGE < <(aws ecs describe-service-deployments --region "$REGION" \
    --service-deployment-arns "$ARN" \
    --query 'serviceDeployments[0].[status,lifecycleStage]' --output text)
  echo "$(date +%T)  $STATUS  $STAGE"
  case "$STATUS" in
    SUCCESSFUL|STOPPED|ROLLBACK_SUCCESSFUL|ROLLBACK_FAILED) break ;;
  esac
  sleep 15
done
