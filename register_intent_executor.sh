#!/bin/bash
# Register Intent Executor Enclave On-Chain
# This script updates PCRs and registers the enclave with its public key

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step() {
    echo -e "${BLUE}==>${NC} ${GREEN}$1${NC}"
}

# Load environment
if [ -f ".env.deployed" ]; then
    source .env.deployed
fi

# Check required variables
REQUIRED_VARS="ENCLAVE_PACKAGE_ID APP_PACKAGE_ID CAP_OBJECT_ID ENCLAVE_CONFIG_ID PCR0 PCR1 PCR2"
for var in $REQUIRED_VARS; do
    if [ -z "${!var}" ]; then
        echo "Error: $var not set. Run deploy_intent_executor.sh first or set manually."
        exit 1
    fi
done

MODULE_NAME=${MODULE_NAME:-"intent_executor"}
OTW_NAME=${OTW_NAME:-"INTENT_EXECUTOR"}
ENCLAVE_URL=${1:-"http://localhost:3000"}

print_step "Updating PCRs on-chain..."
echo "PCR0: $PCR0"
echo "PCR1: $PCR1"
echo "PCR2: $PCR2"

sui client call \
    --function update_pcrs \
    --module enclave \
    --package "$ENCLAVE_PACKAGE_ID" \
    --type-args "${APP_PACKAGE_ID}::${MODULE_NAME}::${OTW_NAME}" \
    --args "$ENCLAVE_CONFIG_ID" "$CAP_OBJECT_ID" "0x$PCR0" "0x$PCR1" "0x$PCR2" \
    --gas-budget 10000000

print_step "Updating enclave name..."
sui client call \
    --function update_name \
    --module enclave \
    --package "$ENCLAVE_PACKAGE_ID" \
    --type-args "${APP_PACKAGE_ID}::${MODULE_NAME}::${OTW_NAME}" \
    --args "$ENCLAVE_CONFIG_ID" "$CAP_OBJECT_ID" "Intent Executor Enclave $(date +%Y-%m-%d)" \
    --gas-budget 10000000

print_step "Registering enclave from: $ENCLAVE_URL"

# Get attestation from enclave
ATTESTATION=$(curl -s -H 'Content-Type: application/json' -X GET "$ENCLAVE_URL/get_attestation")
echo "Attestation received"

# Extract attestation document
ATTESTATION_DOC=$(echo "$ATTESTATION" | jq -r '.attestation')

if [ "$ATTESTATION_DOC" == "null" ] || [ -z "$ATTESTATION_DOC" ]; then
    echo "Error: Failed to get attestation document"
    exit 1
fi

# Register enclave using the attestation
print_step "Calling register_enclave..."
RESULT=$(sui client call \
    --function register_enclave \
    --module enclave \
    --package "$ENCLAVE_PACKAGE_ID" \
    --type-args "${APP_PACKAGE_ID}::${MODULE_NAME}::${OTW_NAME}" \
    --args "$ENCLAVE_CONFIG_ID" "$ATTESTATION_DOC" \
    --gas-budget 50000000 \
    --json)

# Extract enclave object ID
ENCLAVE_OBJECT_ID=$(echo "$RESULT" | jq -r '.objectChanges[] | select(.objectType | contains("Enclave")) | .objectId')

echo ""
echo -e "${GREEN}✓ Enclave registered successfully!${NC}"
echo ""
echo "ENCLAVE_OBJECT_ID=$ENCLAVE_OBJECT_ID"
echo ""

# Append to env file
echo "ENCLAVE_OBJECT_ID=$ENCLAVE_OBJECT_ID" >> .env.deployed
echo "ENCLAVE_URL=$ENCLAVE_URL" >> .env.deployed

echo "Saved to .env.deployed"
