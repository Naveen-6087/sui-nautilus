# Nautilus Intent Executor Deployment Guide

This guide walks you through deploying the Intent Executor enclave to AWS Nitro Enclaves.

## Prerequisites

1. **AWS Account** with EC2 and Nitro Enclave access
2. **AWS CLI v2** installed and configured
3. **Docker Desktop** with WSL integration enabled
4. **Sui CLI** installed
5. **WSL2 with Ubuntu** (already installed on your system)

## Step 1: Configure AWS SSO

```powershell
# In PowerShell
aws configure sso

# Enter your SSO details:
# - SSO session name: sui-hackmoney (or any name)
# - SSO start URL: https://your-sso-url.awsapps.com/start
# - SSO region: ap-south-2 (or your region)
# - SSO registration scopes: sso:account:access (press Enter)
```

A browser window will open for authentication. After logging in, select your account and role.

```powershell
# Export credentials for use in scripts
aws configure export-credentials --profile <your-profile-name> --format env > aws-creds.ps1

# Or for bash/WSL
aws configure export-credentials --profile <your-profile-name> --format env > ~/aws-creds.sh
source ~/aws-creds.sh
```

## Step 2: Set Up EC2 Key Pair

```powershell
# List existing key pairs
aws ec2 describe-key-pairs --region us-east-1 --query 'KeyPairs[*].KeyName'

# Create new key pair if needed
aws ec2 create-key-pair --key-name suihack-key --region us-east-1 --query 'KeyMaterial' --output text > ~/.ssh/suihack-key.pem

# Set permissions (in WSL)
wsl chmod 400 ~/.ssh/suihack-key.pem

# Export key pair name
$env:KEY_PAIR = "suihack-key"
```

## Step 3: Enable Docker WSL Integration

1. Open **Docker Desktop**
2. Go to **Settings** → **Resources** → **WSL Integration**
3. Enable integration with your Ubuntu distribution
4. Click **Apply & Restart**

Verify in WSL:
```bash
wsl -e bash -c "docker --version"
```

## Step 4: Build Enclave Locally

The enclave must be built on Linux. Use WSL:

```bash
# In WSL
cd /mnt/c/Users/hemav/OneDrive/Desktop/suihack/nautilus-ref/nautilus

# Build the enclave image
make ENCLAVE_APP=intent-executor

# View PCR values (these are registered on-chain)
cat out/nitro.pcrs
```

## Step 5: Deploy Move Contracts

```bash
# Switch to testnet
sui client switch --env testnet

# Get some SUI from faucet
sui client faucet

# Deploy enclave package
cd move/enclave
sui move build
sui client publish

# Note the ENCLAVE_PACKAGE_ID from output

# Deploy intent-executor package
cd ../intent-executor
sui move build
sui client publish

# Note these from output:
# - APP_PACKAGE_ID
# - CAP_OBJECT_ID (type: Cap<INTENT_EXECUTOR>)
# - ENCLAVE_CONFIG_ID (type: EnclaveConfig<INTENT_EXECUTOR>)
```

## Step 6: Launch EC2 with Nitro Enclave

```bash
# Set environment variables
export KEY_PAIR=suihack-key
export REGION=us-east-1

# Run the deployment script
./configure_enclave.sh intent-executor

# Follow the prompts:
# - Instance base name: intent-executor
# - Use secret: n (for now)
```

Save the EC2 public IP from the output.

## Step 7: Copy Code to EC2

```bash
rsync -avz -e "ssh -i ~/.ssh/suihack-key.pem" \
  /mnt/c/Users/hemav/OneDrive/Desktop/suihack/nautilus-ref/nautilus/ \
  ec2-user@<PUBLIC_IP>:~/nautilus/
```

## Step 8: Build and Run on EC2

```bash
# SSH into EC2
ssh -i ~/.ssh/suihack-key.pem ec2-user@<PUBLIC_IP>

# Build and run enclave
cd nautilus
make ENCLAVE_APP=intent-executor
make run

# Expose port 3000
sh expose_enclave.sh
```

## Step 9: Register Enclave On-Chain

From your local machine:

```bash
# Set environment variables
export ENCLAVE_PACKAGE_ID=0x...
export APP_PACKAGE_ID=0x...
export CAP_OBJECT_ID=0x...
export ENCLAVE_CONFIG_ID=0x...
export PCR0=... # from out/nitro.pcrs
export PCR1=...
export PCR2=...
export ENCLAVE_URL=http://<PUBLIC_IP>:3000

# Update PCRs on-chain
sui client call \
    --function update_pcrs \
    --module enclave \
    --package $ENCLAVE_PACKAGE_ID \
    --type-args "${APP_PACKAGE_ID}::intent_executor::INTENT_EXECUTOR" \
    --args $ENCLAVE_CONFIG_ID $CAP_OBJECT_ID 0x$PCR0 0x$PCR1 0x$PCR2 \
    --gas-budget 10000000

# Register enclave
./register_enclave.sh $ENCLAVE_PACKAGE_ID $APP_PACKAGE_ID $ENCLAVE_CONFIG_ID $ENCLAVE_URL intent_executor INTENT_EXECUTOR

# Note the ENCLAVE_OBJECT_ID from output
```

## Step 10: Test the Enclave

```bash
# Health check
curl -X GET http://<PUBLIC_IP>:3000/health_check

# Get price
curl -X POST http://<PUBLIC_IP>:3000/get_price \
  -H 'Content-Type: application/json' \
  -d '{"payload": {"pair": "SUI_USDC"}}'
```

## Step 11: Stop EC2 (Important!)

AWS charges ~$0.19/hour for Nitro Enclave instances.

```bash
aws ec2 stop-instances --instance-ids <instance-id>
```

To restart later:
```bash
aws ec2 start-instances --instance-ids <instance-id>
```

## Environment Variables Summary

Save these in a `.env.deployed` file:

```
ENCLAVE_PACKAGE_ID=0x...
APP_PACKAGE_ID=0x...
CAP_OBJECT_ID=0x...
ENCLAVE_CONFIG_ID=0x...
ENCLAVE_OBJECT_ID=0x...
ENCLAVE_URL=http://<PUBLIC_IP>:3000
PCR0=...
PCR1=...
PCR2=...
```

## Troubleshooting

### Docker not found in WSL
Enable WSL integration in Docker Desktop settings.

### AWS credentials expired
```bash
aws sso login --profile <your-profile>
aws configure export-credentials --profile <your-profile> --format env > ~/aws-creds.sh
source ~/aws-creds.sh
```

### Enclave not responding
```bash
# SSH into EC2 and check status
nitro-cli describe-enclaves

# Restart enclave
nitro-cli terminate-enclave --all
make run
sh expose_enclave.sh
```

### PCR mismatch
Rebuild the enclave and update PCRs on-chain:
```bash
make ENCLAVE_APP=intent-executor
# Then call update_pcrs again
```
