#!/bin/bash

set -xeuo pipefail

# defaulut configuration values
export REGION=${REGION:-us-west-2}
export AWSACCOUNT=${AWSACCOUNT:-116961472995}
export INSTANCE=${INSTANCE:-kovan}

cat ecs-task-role-trust-policy.json | envsubst > /tmp/ecs-task-role-trust-policy.json
aws iam create-role --region $REGION --role-name liquidator-task-role-$INSTANCE --assume-role-policy-document file:///tmp/ecs-task-role-trust-policy.json
aws iam create-role --region $REGION --role-name liquidator-task-execution-role-$INSTANCE --assume-role-policy-document file:///tmp/ecs-task-role-trust-policy.json

cat task-execution-role.json | envsubst > /tmp/task-execution-role.json
aws iam put-role-policy --region $REGION --role-name liquidator-task-execution-role-$INSTANCE --policy-name liquidator-iam-policy-task-execution-role-$INSTANCE --policy-document file:///tmp/task-execution-role.json

