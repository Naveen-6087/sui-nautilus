#!/bin/bash
# Intent Executor Enclave Deployment Script
# This script handles the complete deployment of the intent-executor enclave

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_step() {
    echo -e "${BLUE}==>${NC} ${GREEN}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    print_step "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not found. Please install AWS CLI v2."
        exit 1
    fi
    
    # Check AWS CLI version
    AWS_VERSION=$(aws --version | grep -oP 'aws-cli/\K[0-9]+')
    if [ "$AWS_VERSION" -lt 2 ]; then
        print_error "AWS CLI v2 required. Found v$AWS_VERSION"
        exit 1
    fi
    
    # Check Sui CLI
    if ! command -v sui &> /dev/null; then
        print_error "Sui CLI not found. Please install Sui CLI."
        exit 1
    fi
    
    # Check Make
    if ! command -v make &> /dev/null; then
        print_error "Make not found. Please install make."
        exit 1
    fi
    
    # Check Rust
    if ! command -v cargo &> /dev/null; then
        print_error "Cargo not found. Please install Rust."
        exit 1
    fi
    
    echo -e "${GREEN}✓ All prerequisites met${NC}"
}

# Configure AWS credentials
configure_aws() {
    print_step "Configuring AWS credentials..."
    
    # Check if credentials are set
    if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
        print_warning "AWS credentials not set. Running aws configure sso..."
        
        # Get AWS profile
        read -p "Enter your AWS SSO profile name (e.g., AdministratorAccess-094557288217): " AWS_PROFILE
        
        # Login to SSO
        aws sso login --profile "$AWS_PROFILE"
        
        # Export credentials
        aws configure export-credentials --profile "$AWS_PROFILE" --format env > /tmp/aws-creds.sh
        source /tmp/aws-creds.sh
        rm /tmp/aws-creds.sh
    fi
    
    # Verify identity
    print_step "Verifying AWS identity..."
    aws sts get-caller-identity
    
    echo -e "${GREEN}✓ AWS configured${NC}"
}

# Set up EC2 key pair
setup_keypair() {
    print_step "Setting up EC2 key pair..."
    
    if [ -z "$KEY_PAIR" ]; then
        # List existing key pairs
        echo "Existing key pairs:"
        aws ec2 describe-key-pairs --region us-east-1 --query 'KeyPairs[*].KeyName' --output table
        
        read -p "Enter key pair name to use (or 'new' to create one): " KEY_PAIR_INPUT
        
        if [ "$KEY_PAIR_INPUT" = "new" ]; then
            read -p "Enter name for new key pair: " NEW_KEY_NAME
            aws ec2 create-key-pair \
                --key-name "$NEW_KEY_NAME" \
                --query 'KeyMaterial' \
                --output text \
                --region us-east-1 > ~/.ssh/"$NEW_KEY_NAME".pem
            chmod 400 ~/.ssh/"$NEW_KEY_NAME".pem
            export KEY_PAIR="$NEW_KEY_NAME"
            echo -e "${GREEN}✓ Created key pair: $KEY_PAIR${NC}"
        else
            export KEY_PAIR="$KEY_PAIR_INPUT"
        fi
    fi
    
    echo -e "${GREEN}✓ Using key pair: $KEY_PAIR${NC}"
}

# Build enclave locally (for PCR values)
build_enclave() {
    print_step "Building enclave image locally..."
    
    cd "$PROJECT_ROOT"
    make ENCLAVE_APP=intent-executor
    
    # Show PCR values
    echo -e "${GREEN}PCR Values:${NC}"
    cat out/nitro.pcrs
    
    # Export PCR values
    export PCR0=$(awk '/PCR0/{print $1}' out/nitro.pcrs)
    export PCR1=$(awk '/PCR1/{print $1}' out/nitro.pcrs)
    export PCR2=$(awk '/PCR2/{print $1}' out/nitro.pcrs)
    
    echo -e "${GREEN}✓ Enclave built successfully${NC}"
}

# Deploy Move contracts
deploy_contracts() {
    print_step "Deploying Move contracts..."
    
    cd "$PROJECT_ROOT/move"
    
    # Switch to testnet
    sui client switch --env testnet 2>/dev/null || true
    
    # Request faucet
    print_step "Requesting testnet SUI..."
    sui client faucet || true
    sleep 5
    
    # Deploy enclave package
    print_step "Deploying enclave package..."
    cd enclave
    sui move build
    ENCLAVE_PUBLISH=$(sui client publish --gas-budget 100000000 --json 2>/dev/null)
    ENCLAVE_PACKAGE_ID=$(echo "$ENCLAVE_PUBLISH" | jq -r '.objectChanges[] | select(.type == "published") | .packageId')
    echo "ENCLAVE_PACKAGE_ID=$ENCLAVE_PACKAGE_ID"
    
    # Deploy intent-executor package
    print_step "Deploying intent-executor package..."
    cd ../intent-executor
    sui move build
    APP_PUBLISH=$(sui client publish --gas-budget 100000000 --json 2>/dev/null)
    APP_PACKAGE_ID=$(echo "$APP_PUBLISH" | jq -r '.objectChanges[] | select(.type == "published") | .packageId')
    CAP_OBJECT_ID=$(echo "$APP_PUBLISH" | jq -r '.objectChanges[] | select(.objectType | contains("Cap")) | .objectId')
    ENCLAVE_CONFIG_ID=$(echo "$APP_PUBLISH" | jq -r '.objectChanges[] | select(.objectType | contains("EnclaveConfig")) | .objectId')
    
    echo "APP_PACKAGE_ID=$APP_PACKAGE_ID"
    echo "CAP_OBJECT_ID=$CAP_OBJECT_ID"
    echo "ENCLAVE_CONFIG_ID=$ENCLAVE_CONFIG_ID"
    
    # Save to env file
    cat > "$PROJECT_ROOT/.env.deployed" << EOF
ENCLAVE_PACKAGE_ID=$ENCLAVE_PACKAGE_ID
APP_PACKAGE_ID=$APP_PACKAGE_ID
CAP_OBJECT_ID=$CAP_OBJECT_ID
ENCLAVE_CONFIG_ID=$ENCLAVE_CONFIG_ID
PCR0=$PCR0
PCR1=$PCR1
PCR2=$PCR2
MODULE_NAME=intent_executor
OTW_NAME=INTENT_EXECUTOR
EOF
    
    echo -e "${GREEN}✓ Contracts deployed. Saved to .env.deployed${NC}"
}

# Launch EC2 instance
launch_ec2() {
    print_step "Launching EC2 instance with Nitro Enclave..."
    
    cd "$PROJECT_ROOT"
    
    # Run the configure script
    sh configure_enclave.sh intent-executor
}

# Main menu
main() {
    echo ""
    echo "======================================"
    echo "  Intent Executor Enclave Deployer"
    echo "======================================"
    echo ""
    
    PS3="Select an option: "
    options=(
        "Full deployment (all steps)"
        "1. Check prerequisites"
        "2. Configure AWS"
        "3. Setup EC2 key pair"
        "4. Build enclave locally"
        "5. Deploy Move contracts"
        "6. Launch EC2 instance"
        "Exit"
    )
    
    select opt in "${options[@]}"; do
        case $REPLY in
            1) 
                check_prerequisites
                configure_aws
                setup_keypair
                build_enclave
                deploy_contracts
                launch_ec2
                break
                ;;
            2) check_prerequisites ;;
            3) configure_aws ;;
            4) setup_keypair ;;
            5) build_enclave ;;
            6) deploy_contracts ;;
            7) launch_ec2 ;;
            8) exit 0 ;;
            *) echo "Invalid option" ;;
        esac
    done
}

# Run main if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
