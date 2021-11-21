#!/bin/bash

set -xeuo pipefail

# defaulut configuration values
REGION=${REGION:-us-west-2}
AWSACCOUNT=${AWSACCOUNT:-116961472995}
INSTANCE=${INSTANCE:-kovan}

echo "Creating secrets"
V_CONFIG=$(cat ../.config/$INSTANCE/config.json)
V_ARGS=$(cat ../.config/$INSTANCE/args)
V_PK=$(cat ../.config/$INSTANCE/pk)

aws secretsmanager create-secret --region $REGION \
    --name $INSTANCE/config.json --secret-string "$V_CONFIG"

aws secretsmanager create-secret --region $REGION \
    --name $INSTANCE/args --secret-string "$V_ARGS"

aws secretsmanager create-secret --region $REGION \
    --name $INSTANCE/pk --secret-string "$V_PK"
