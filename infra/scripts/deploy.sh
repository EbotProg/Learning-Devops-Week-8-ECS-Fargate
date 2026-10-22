#!/usr/bin/env bash
# Manual blue/green deployment of the task definition revision Terraform last registered.
# Same thing the pipeline does, by hand. Run from the infra/ folder.
#
# Usage: ./scripts/deploy.sh frontend|backend
set -euo pipefail

SVC="${1:?usage: ./scripts/deploy.sh frontend|backend}"
REGION="eu-north-1"

case "$SVC" in
  frontend) PORT=3000 ;;
  backend)  PORT=1337 ;;
  *) echo "service must be frontend or backend"; exit 1 ;;
esac

APP=$(terraform output -raw codedeploy_app)
DG=$(terraform output -raw "${SVC}_deployment_group")
TD=$(terraform output -raw "${SVC}_task_definition")

echo "App:             $APP"
echo "Deployment group: $DG"
echo "Task definition:  $TD"

cat > deployment.json <<EOF
{
  "applicationName": "$APP",
  "deploymentGroupName": "$DG",
  "revision": {
    "revisionType": "AppSpecContent",
    "appSpecContent": {
      "content": "{\"version\":0.0,\"Resources\":[{\"TargetService\":{\"Type\":\"AWS::ECS::Service\",\"Properties\":{\"TaskDefinition\":\"$TD\",\"LoadBalancerInfo\":{\"ContainerName\":\"$SVC\",\"ContainerPort\":$PORT}}}}]}"
    }
  }
}
EOF

ID=$(aws deploy create-deployment --region "$REGION" \
  --cli-input-json file://deployment.json \
  --query deploymentId --output text)
rm -f deployment.json

echo
echo "Deployment: $ID"
echo "Console:    https://$REGION.console.aws.amazon.com/codesuite/codedeploy/deployments/$ID?region=$REGION"
echo

while true; do
  STATUS=$(aws deploy get-deployment --region "$REGION" --deployment-id "$ID" \
    --query deploymentInfo.status --output text)
  echo "$(date +%T)  $STATUS"
  case "$STATUS" in
    Succeeded|Failed|Stopped) break ;;
  esac
  sleep 15
done
