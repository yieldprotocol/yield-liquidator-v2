#!/bin/bash

set -xeuo pipefail

# defaulut configuration values
export REGION=${REGION:-us-west-2}
export AWSACCOUNT=${AWSACCOUNT:-116961472995}
export INSTANCE=${INSTANCE:-kovan}

export REPO_NAME=yield-v2-liquidator

echo "Building docker image"
docker build .. -t $REPO_NAME:latest

# create docker repo
echo "Uploading docker image"
aws ecr list-images --repository-name $REPO_NAME --region $REGION || aws ecr create-repository --repository-name $REPO_NAME --region $REGION
ECR_REPO_URI=$AWSACCOUNT.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME

REMOTE_IMAGE=$ECR_REPO_URI:latest
docker tag $REPO_NAME:latest $REMOTE_IMAGE

aws ecr get-login-password  --region $REGION | docker login --username AWS --password-stdin $ECR_REPO_URI
docker push $REMOTE_IMAGE

echo "Creating Fargate task"
export CONFIG_KEY=$(aws secretsmanager list-secrets | jq -r ".SecretList[] | select (.Name==\"$INSTANCE/config.json\") | .ARN")
export ARGS_KEY=$(aws secretsmanager list-secrets | jq -r ".SecretList[] | select (.Name==\"$INSTANCE/args\") | .ARN")
export PK_KEY=$(aws secretsmanager list-secrets | jq -r ".SecretList[] | select (.Name==\"$INSTANCE/pk\") | .ARN")
cat liquidator-task.json | envsubst > /tmp/liquidator-task.json

aws ecs register-task-definition --region $REGION --cli-input-json file:///tmp/liquidator-task.json

# echo "Running task"
# aws ecs run-task --region $REGION \
#   --cluster "yield_cluster" \
#   --launch-type FARGATE \
#   --network-configuration "awsvpcConfiguration={subnets=[subnet-07eba54f8844e6159],securityGroups=[sg-0a4c1fa1da8808a7c],assignPublicIp=ENABLED}"
#   --task-definition liquidator-$INSTANCE:8