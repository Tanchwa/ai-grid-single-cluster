#!/bin/bash

# Small hacky steps for setting up the cluster to work on AWS properly
#
set -euo pipefail

for NODE in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  IP=$(kubectl get node $NODE -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
  RESULT=$(aws ec2 describe-instances \
    --filters "Name=private-ip-address,Values=$IP" \
    --query 'Reservations[0].Instances[0].[InstanceId,Placement.AvailabilityZone]' \
    --output text --region ap-southeast-2 --profile work)
  INSTANCE_ID=$(echo $RESULT | awk '{print $1}')
  AZ=$(echo $RESULT | awk '{print $2}')
  echo "Patching $NODE -> aws:///$AZ/$INSTANCE_ID"
  kubectl patch node $NODE -p "{\"spec\":{\"providerID\":\"aws:///$AZ/$INSTANCE_ID\"}}"
done


#put back in monitoring namespace if using prometheus operator
for NAMESPACE in monitoring longhorn-system gpu-operator node-feature-discovery; do
  kubectl label namespace $NAMESPACE pod-security.kubernetes.io/enforce=privileged --overwrite
done
