#!/bin/sh

set -eu

export RUST_BACKTRACE=1
export RUST_LOG="liquidator,yield_liquidator=info"

echo $L_CONFIG > /tmp/config.json
echo $L_PK > /tmp/pk

exec /usr/bin/liquidator $L_ARGS -c /tmp/config.json -p /tmp/pk