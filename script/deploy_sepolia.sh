#!/bin/bash

# Deploy IrysOFT to Sepolia Testnet
# Usage: ./script/deploy_sepolia.sh

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}   IrysOFT Sepolia Deployment Script  ${NC}"
echo -e "${GREEN}======================================${NC}\n"

# Load environment variables
if [ -f .env ]; then
    source .env
    echo -e "${GREEN}✓ Loaded .env file${NC}"
else
    echo -e "${RED}✗ .env file not found${NC}"
    echo "Please create a .env file with the following variables:"
    echo "  PRIVATE_KEY=your_private_key"
    echo "  SEPOLIA_RPC_URL=your_sepolia_rpc_url"
    echo "  ETHERSCAN_API_KEY=your_etherscan_api_key (optional)"
    echo "  TOKEN_NAME=Irys Token (optional)"
    echo "  TOKEN_SYMBOL=IRYS (optional)"
    echo "  MAX_SUPPLY=2000000000000000000000000000 (optional, default 2B tokens)"
    exit 1
fi

# Check required environment variables
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}✗ PRIVATE_KEY not set in .env${NC}"
    exit 1
fi

if [ -z "$SEPOLIA_RPC_URL" ]; then
    echo -e "${RED}✗ SEPOLIA_RPC_URL not set in .env${NC}"
    exit 1
fi

# Set default values if not provided
TOKEN_NAME=${TOKEN_NAME:-"Irys Token"}
TOKEN_SYMBOL=${TOKEN_SYMBOL:-"IRYS"}
MAX_SUPPLY=${MAX_SUPPLY:-"2000000000000000000000000000"}  # 2 billion tokens with 18 decimals

echo -e "${YELLOW}Configuration:${NC}"
echo "  Network: Sepolia (Chain ID: 11155111)"
echo "  RPC URL: $SEPOLIA_RPC_URL"
echo "  Token Name: $TOKEN_NAME"
echo "  Token Symbol: $TOKEN_SYMBOL"
echo "  Max Supply: $MAX_SUPPLY"
echo ""

# Check if forge is installed
if ! command -v forge &> /dev/null; then
    echo -e "${RED}✗ Forge not found. Please install Foundry first.${NC}"
    echo "Visit: https://book.getfoundry.sh/getting-started/installation"
    exit 1
fi

echo -e "${YELLOW}Building contracts...${NC}"
forge build

echo -e "\n${YELLOW}Deploying to Sepolia...${NC}\n"

# Deploy using forge script
if [ -n "$ETHERSCAN_API_KEY" ]; then
    echo "Deploying with Etherscan verification..."
    forge script script/DeployMultiChain.s.sol:DeployMultiChainScript \
        --rpc-url "$SEPOLIA_RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        --broadcast \
        --verify \
        --etherscan-api-key "$ETHERSCAN_API_KEY" \
        -vvv
else
    echo "Deploying without Etherscan verification (no API key provided)..."
    forge script script/DeployMultiChain.s.sol:DeployMultiChainScript \
        --rpc-url "$SEPOLIA_RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        --broadcast \
        -vvv
fi

echo -e "\n${GREEN}======================================${NC}"
echo -e "${GREEN}   Deployment Complete!              ${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo "Check deployments.txt for contract addresses and explorer links."
echo ""

# Display deployment info if file exists
if [ -f deployments.txt ]; then
    echo -e "${YELLOW}Latest deployment info:${NC}"
    tail -n 7 deployments.txt
fi
