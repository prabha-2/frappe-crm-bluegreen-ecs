#!/bin/bash
set -euo pipefail
CLUSTER=frappe-crm-cluster

tg() {
  aws elbv2 describe-target-groups --names "frappe-crm-$1-tg" \
    --query 'TargetGroups[0].TargetGroupArn' --output text
}
scale() {
  aws ecs update-service --cluster "$CLUSTER" --service "frappe-crm-$1" --desired-count "$2" > /dev/null
}
switch_to() {
  aws elbv2 modify-listener --listener-arn "$LISTENER" \
    --default-actions "Type=forward,TargetGroupArn=$1" > /dev/null
}

# 1. Which colour is live? The other one is idle.
ALB_ARN=$(aws elbv2 describe-load-balancers --names frappe-crm-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)
ALB_DNS=$(aws elbv2 describe-load-balancers --names frappe-crm-alb --query 'LoadBalancers[0].DNSName' --output text)
LISTENER=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[0].ListenerArn' --output text)
LIVE_TG=$(aws elbv2 describe-listeners --listener-arns "$LISTENER" --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text)

if [ "$LIVE_TG" = "$(tg blue)" ]; then LIVE=blue; IDLE=green; else LIVE=green; IDLE=blue; fi
IDLE_TG=$(tg "$IDLE")
echo "Live: $LIVE | Idle: $IDLE (deploying here)"

# 2. Start the idle colour with the newest image
aws ecs update-service --cluster "$CLUSTER" --service "frappe-crm-$IDLE" \
  --desired-count 1 --force-new-deployment > /dev/null

# 3. Health gate: wait up to 30 minutes for the idle colour to be healthy
STATE=none
for i in $(seq 1 60); do
  STATE=$(aws elbv2 describe-target-health --target-group-arn "$IDLE_TG" \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text)
  echo "[$i/60] $IDLE is: $STATE"
  [ "$STATE" = "healthy" ] && break
  sleep 30
done
if [ "$STATE" != "healthy" ]; then
  echo "ROLLBACK 1: $IDLE never became healthy. $LIVE stays live."
  scale "$IDLE" 0
  exit 1
fi

# 4. Flip traffic to the idle colour
switch_to "$IDLE_TG"
echo "Flipped: $IDLE is now live."

# 5. Check the live URL. If it fails, flip back.
OK=0
for i in 1 2 3 4 5; do
  curl -sf --max-time 10 "http://$ALB_DNS/api/method/ping" > /dev/null && OK=$((OK+1))
  sleep 5
done
echo "Live URL check passed $OK of 5"
if [ "$OK" -lt 4 ]; then
  echo "ROLLBACK 2: flipping back to $LIVE."
  switch_to "$LIVE_TG"
  scale "$IDLE" 0
  exit 1
fi

# 6. Success: old colour is now idle, scale it down to save cost
scale "$LIVE" 0
echo "Done. $IDLE is live."