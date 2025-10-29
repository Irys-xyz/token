#!/bin/bash

# LayerZero Cross-Chain Token Bridge Script
# Usage: ./bridge.sh <source_oft> <dest_eid> <dest_oft> <amount>
# Or set environment variables and run: ./bridge.sh

set -e

# Load environment if .env exists
if [ -f .env ]; then
    source .env
fi

# Function to detect if this is a mainnet operation
is_mainnet() {
    local rpc_url="$1"
    local dest_eid="$2"

    # Supported mainnet EIDs (LayerZero V2)
    # Only Ethereum, BSC, and Base are supported
    case "$dest_eid" in
        30101) return 0 ;; # Ethereum Mainnet
        30102) return 0 ;; # BSC Mainnet
        30184) return 0 ;; # Base Mainnet
        *) ;;
    esac

    # Supported testnet EIDs
    # Allow these to proceed with automatic execution
    case "$dest_eid" in
        40161) return 1 ;; # Ethereum Sepolia
        40102) return 1 ;; # BSC Testnet
        40245) return 1 ;; # Base Sepolia
        *) ;;
    esac

    # Check RPC URL patterns for mainnet
    if echo "$rpc_url" | grep -qi "mainnet\|ethereum\.org" | grep -qvi "testnet\|sepolia\|goerli\|holesky"; then
        return 0
    fi

    # BSC mainnet detection
    if echo "$rpc_url" | grep -qi "bsc\.com\|bnbchain\.org" | grep -qvi "testnet"; then
        return 0
    fi

    # Base mainnet detection
    if echo "$rpc_url" | grep -qi "base\.org" | grep -qvi "sepolia"; then
        return 0
    fi

    # Check for absence of testnet keywords
    if ! echo "$rpc_url" | grep -qi "testnet\|sepolia\|goerli\|holesky"; then
        # If no clear testnet indicator and looks like a major chain, be cautious
        if echo "$rpc_url" | grep -qi "infura\|alchemy\|quicknode"; then
            return 0
        fi
    fi

    return 1
}

# Parse command-line arguments or use environment variables
SOURCE_OFT="${1:-${SOURCE_OFT}}"
DESTINATION_EID="${2:-${DESTINATION_EID}}"
DESTINATION_OFT="${3:-${DESTINATION_OFT}}"
BRIDGE_AMOUNT="${4:-${BRIDGE_AMOUNT}}"

# Validate required parameters
if [ -z "$SOURCE_OFT" ] || [ -z "$DESTINATION_EID" ] || [ -z "$DESTINATION_OFT" ] || [ -z "$BRIDGE_AMOUNT" ]; then
    echo "Error: Missing required parameters"
    echo ""
    echo "Usage: $0 <source_oft> <dest_eid> <dest_oft> <amount>"
    echo ""
    echo "Or set environment variables:"
    echo "  SOURCE_OFT           - Source chain OFT contract address"
    echo "  DESTINATION_EID      - Destination chain endpoint ID"
    echo "  DESTINATION_OFT      - Destination chain OFT contract address"
    echo "  BRIDGE_AMOUNT        - Amount to bridge in wei (e.g., 1000000000000000000 for 1 token)"
    echo "  SOURCE_RPC_URL       - Source chain RPC URL"
    echo "  PRIVATE_KEY          - Deployer private key"
    echo ""
    echo "Example:"
    echo "  $0 0x95Ae64c9d98D5825b5261Dde30Bd482684032bC0 40102 0x0929dDd19F9EF7e15E206015C9987573e489e928 1000000000000000000"
    exit 1
fi

# Validate RPC URL
if [ -z "$SOURCE_RPC_URL" ]; then
    echo "Error: SOURCE_RPC_URL environment variable is required"
    exit 1
fi

# Validate private key
if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: PRIVATE_KEY environment variable is required"
    exit 1
fi

# Display configuration
echo "=========================================="
echo "LayerZero Cross-Chain Token Bridge"
echo "=========================================="
echo "Source OFT:      $SOURCE_OFT"
echo "Destination EID: $DESTINATION_EID"
echo "Destination OFT: $DESTINATION_OFT"
echo "Amount:          $BRIDGE_AMOUNT wei"
echo "=========================================="
echo ""

# Check if this is a mainnet operation
if is_mainnet "$SOURCE_RPC_URL" "$DESTINATION_EID"; then
    echo "  MAINNET DETECTED "
    echo ""
    echo "For safety, mainnet operations require manual execution."
    echo "Please review the configuration above carefully, then execute:"
    echo ""
    echo "=========================================="
    echo "MANUAL EXECUTION COMMANDS"
    echo "=========================================="
    echo ""
    echo "# Set environment variables:"
    echo "export SOURCE_OFT=\"$SOURCE_OFT\""
    echo "export DESTINATION_EID=\"$DESTINATION_EID\""
    echo "export DESTINATION_OFT=\"$DESTINATION_OFT\""
    echo "export BRIDGE_AMOUNT=\"$BRIDGE_AMOUNT\""
    echo ""
    echo "# Execute the bridge transaction:"
    echo "forge script script/BridgeTokens.s.sol:BridgeTokensScript \\"
    echo "    --rpc-url \"$SOURCE_RPC_URL\" \\"
    echo "    --broadcast \\"
    echo "    --legacy"
    echo ""
    echo "=========================================="
    echo ""
    echo "  WARNING: This will bridge real tokens on mainnet!"
    echo "  Double-check all addresses and amounts before executing."
    echo ""
    exit 0
fi

# Testnet - proceed with automatic execution
echo "✓ Testnet detected - proceeding with automatic execution"
echo ""

# Export variables for forge script
export SOURCE_OFT
export DESTINATION_EID
export DESTINATION_OFT
export BRIDGE_AMOUNT

# Run the bridge script
echo "Executing bridge transaction..."
forge script script/BridgeTokens.s.sol:BridgeTokensScript \
    --rpc-url "$SOURCE_RPC_URL" \
    --broadcast \
    --legacy

echo ""
echo "=========================================="
echo "Bridge script completed!"
echo "=========================================="
