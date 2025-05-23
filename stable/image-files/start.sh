#!/bin/bash

# Fail fast
set -Eeuo pipefail

export DISPLAY=:0

# Clear previous lockfile
rm -f /tmp/.X0-lock

# Start VNC server
Xvnc -SecurityTypes None -AlwaysShared=1 -geometry 1920x1080 :0 &

# Start noVNC server
./noVNC/utils/novnc_proxy --vnc localhost:5900 &

# Start openbox
openbox &

# Start either TWS or IB Gateway
if [[ -z ${GATEWAY_OR_TWS:-} ]]; then
    # Start TWS by default if not specified
    GATEWAY_OR_TWS=tws
    command=
elif [[ ${GATEWAY_OR_TWS@L} = "gateway" ]]; then
    command='-g'
elif [[ ${GATEWAY_OR_TWS@L} = "tws" ]]; then
    command=
else
    printf "GATEWAY_OR_TWS must be either 'gateway' or 'tws': got '%s'\n" "$GATEWAY_OR_TWS"
    exit 1
fi

# Forward correct port with socat
if [[ ${GATEWAY_OR_TWS@L} = "gateway" ]]; then
    if [[ ${IBC_TradingMode:-live} = "live" ]]; then
        # IBGateway Live
        port=4001
    else
        # IBGateway Paper
        port=4002
    fi
elif [[ ${IBC_TradingMode:-live} = "live" ]]; then
    # TWS Live
    port=7496
else
    # TWS Paper
    port=7497
fi

printf "Listening for incoming API connections on %s\n" $port
socat -d -d TCP-LISTEN:8888,fork TCP:127.0.0.1:${port} &

# Hacky way to get the major version for IB Gateway/TWS
TWS_MAJOR_VERSION=$(ls ~/Jts/ibgateway/.)

# Override /opt/ibc/config.ini with environment variables
./replace.sh ~/ibc/config.ini

# --on2fatimeout was previously supplied by gatewaystart.sh/twsstart.sh,
# so we need to supply it here. The rest of the arguments can be read from
# the config.ini file.

# Try to get credentials from env vars or AWS Secrets Manager
username="${USERNAME:-}"
password="${PASSWORD:-}"
if [[ -z "$username" || -z "$password" ]]; then
    # Install AWS CLI if not available
    if ! command -v aws >/dev/null 2>&1; then
        echo "Installing AWS CLI..."
        apt-get update && apt-get install -y awscli
    fi
    # Configure AWS credentials if provided
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" && 
          -n "${AWS_SECRET_ACCESS_KEY:-}" &&
          -n "${AWS_REGION:-}" &&
          -n "${AWS_SECRET_ID:-}" ]]; then
        export AWS_ACCESS_KEY_ID
        export AWS_SECRET_ACCESS_KEY
    fi
    # Try to fetch from Secrets Manager
    echo "Attempting to fetch credentials from AWS Secrets Manager..."
    secret_json=$(aws secretsmanager get-secret-value \
        --secret-id "${AWS_SECRET_ID}" \
        --region "${AWS_REGION}" \
        --query SecretString \
        --output text 2>/dev/null || echo '')
    
    if [[ -n "$secret_json" ]]; then
        [[ -z "$username" ]] && username=$(echo "$secret_json" | grep -o '"username":"[^"]*' | cut -d'"' -f4)
        [[ -z "$password" ]] && password=$(echo "$secret_json" | grep -o '"password":"[^"]*' | cut -d'"' -f4)
    fi
fi

exec /opt/ibc/scripts/ibcstart.sh "${TWS_MAJOR_VERSION}" $command \
    "--user=${username}" \
    "--pw=${password}" \
    "--on2fatimeout=${TWOFA_TIMEOUT_ACTION:-restart}" \
    "--tws-settings-path=${TWS_SETTINGS_PATH:-}"
