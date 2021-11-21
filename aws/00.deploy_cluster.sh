#!/bin/bash

set -xeuo pipefail

# defaulut configuration values
export REGION=${REGION:-us-west-2}
export AWSACCOUNT=${AWSACCOUNT:-116961472995}
export INSTANCE=${INSTANCE:-kovan}

aws logs create-log-group --log-group-name yield --region $REGION
aws ecs create-cluster --cluster-name "yield_cluster" --region $REGION