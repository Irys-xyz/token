#!/bin/bash

# LayerZero Peer Setup Script
# Sets up bidirectional peer connections between two chains
# Usage: ./setup-peers.sh <chain_a_oft> <chain_a_eid> <chain_b_oft> <chain_b_eid>
# Or set environment variables and run: ./setup-peers.sh

set -e

# Load environment if .env exists
if [ -f .env ]; then
    source .env
fi

# Function to detect if this is a mainnet operation
is_mainnet() {
    local eid="$1"
    local rpc_url="$2"

    # Supported mainnet EIDs (LayerZero V2)
    # Only Ethereum, BSC, and Base are supported
    case "$eid" in
        30101) return 0 ;; # Ethereum Mainnet
        30102) return 0 ;; # BSC Mainnet
        30184) return 0 ;; # Base Mainnet
        *) ;;
    esac

    # Supported testnet EIDs
    # Allow these to proceed with automatic execution
    case "$eid" in
        40161) return 1 ;; # Ethereum Sepolia
        40102) return 1 ;; # BSC Testnet
        40245) return 1 ;; # Base Sepolia
        *) ;;
    esac

    # Check RPC URL patterns for mainnet
    if [ -n "$rpc_url" ]; then
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
    fi

    return 1
}

# Function to convert address to bytes32
address_to_bytes32() {
    local addr="$1"
    # Remove 0x prefix if present
    addr="${addr#0x}"
    # Left-pad with zeros to 64 characters (32 bytes)
    printf "0x%064s" "$addr" | tr ' ' '0'
}

# Parse command-line arguments or use environment variables
CHAIN_A_OFT="${1:-${CHAIN_A_OFT}}"
CHAIN_A_EID="${2:-${CHAIN_A_EID}}"
CHAIN_B_OFT="${3:-${CHAIN_B_OFT}}"
CHAIN_B_EID="${4:-${CHAIN_B_EID}}"

# Validate required parameters
if [ -z "$CHAIN_A_OFT" ] || [ -z "$CHAIN_A_EID" ] || [ -z "$CHAIN_B_OFT" ] || [ -z "$CHAIN_B_EID" ]; then
    echo "Error: Missing required parameters"
    echo ""
    echo "Usage: $0 <chain_a_oft> <chain_a_eid> <chain_b_oft> <chain_b_eid>"
    echo ""
    echo "Or set environment variables:"
    echo "  CHAIN_A_OFT       - Chain A OFT contract address"
    echo "  CHAIN_A_EID       - Chain A endpoint ID"
    echo "  CHAIN_B_OFT       - Chain B OFT contract address"
    echo "  CHAIN_B_EID       - Chain B endpoint ID"
    echo "  CHAIN_A_RPC_URL   - Chain A RPC URL"
    echo "  CHAIN_B_RPC_URL   - Chain B RPC URL"
    echo "  PRIVATE_KEY       - Deployer private key (must be owner of both contracts)"
    echo ""
    echo "Example:"
    echo "  $0 0x95Ae64c9d98D5825b5261Dde30Bd482684032bC0 40161 0x0929dDd19F9EF7e15E206015C9987573e489e928 40102"
    exit 1
fi

# Validate RPC URLs
if [ -z "$CHAIN_A_RPC_URL" ]; then
    echo "Error: CHAIN_A_RPC_URL environment variable is required"
    exit 1
fi

if [ -z "$CHAIN_B_RPC_URL" ]; then
    echo "Error: CHAIN_B_RPC_URL environment variable is required"
    exit 1
fi

# Validate private key
if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: PRIVATE_KEY environment variable is required"
    exit 1
fi

# Convert addresses to bytes32
CHAIN_A_PEER=$(address_to_bytes32 "$CHAIN_A_OFT")
CHAIN_B_PEER=$(address_to_bytes32 "$CHAIN_B_OFT")

echo "==================================="
echo "LayerZero Peer Setup"
echo "==================================="
echo "Chain A OFT: $CHAIN_A_OFT (EID: $CHAIN_A_EID)"
echo "Chain B OFT: $CHAIN_B_OFT (EID: $CHAIN_B_EID)"
echo "==================================="
echo ""

# Check if either chain is mainnet
if is_mainnet "$CHAIN_A_EID" "$CHAIN_A_RPC_URL" || is_mainnet "$CHAIN_B_EID" "$CHAIN_B_RPC_URL"; then
    echo "  MAINNET DETECTED "
    echo ""
    echo "For safety, mainnet operations require manual execution."
    echo "Please review the configuration above carefully, then execute:"
    echo ""
    echo "==================================="
    echo "MANUAL EXECUTION COMMANDS"
    echo "==================================="
    echo ""
    echo "# Set peer on Chain A (pointing to Chain B):"
    echo "cast send $CHAIN_A_OFT \\"
    echo "  \"setPeer(uint32,bytes32)\" \\"
    echo "  $CHAIN_B_EID \\"
    echo "  $CHAIN_B_PEER \\"
    echo "  --private-key \$PRIVATE_KEY \\"
    echo "  --rpc-url \"$CHAIN_A_RPC_URL\""
    echo ""
    echo "# Set peer on Chain B (pointing to Chain A):"
    echo "cast send $CHAIN_B_OFT \\"
    echo "  \"setPeer(uint32,bytes32)\" \\"
    echo "  $CHAIN_A_EID \\"
    echo "  $CHAIN_A_PEER \\"
    echo "  --private-key \$PRIVATE_KEY \\"
    echo "  --rpc-url \"$CHAIN_B_RPC_URL\""
    echo ""
    echo "# Verify peers:"
    echo "cast call $CHAIN_A_OFT \"peers(uint32)(bytes32)\" $CHAIN_B_EID --rpc-url \"$CHAIN_A_RPC_URL\""
    echo "cast call $CHAIN_B_OFT \"peers(uint32)(bytes32)\" $CHAIN_A_EID --rpc-url \"$CHAIN_B_RPC_URL\""
    echo ""
    echo "==================================="
    echo ""
    echo "  WARNING: This will configure peer connections on mainnet!"
    echo "  Double-check all addresses and endpoint IDs before executing."
    echo ""
    exit 0
fi

# Testnet - proceed with automatic execution
echo "✓ Testnet detected - proceeding with automatic execution"
echo ""

# Set peer on Chain A (pointing to Chain B)
echo "Setting peer on Chain A -> Chain B..."
cast send $CHAIN_A_OFT \
  "setPeer(uint32,bytes32)" \
  $CHAIN_B_EID \
  $CHAIN_B_PEER \
  --private-key $PRIVATE_KEY \
  --rpc-url $CHAIN_A_RPC_URL

echo ""
echo "Setting peer on Chain B -> Chain A..."
cast send $CHAIN_B_OFT \
  "setPeer(uint32,bytes32)" \
  $CHAIN_A_EID \
  $CHAIN_A_PEER \
  --private-key $PRIVATE_KEY \
  --rpc-url $CHAIN_B_RPC_URL

echo ""
echo "==================================="
echo "Peer setup complete!"
echo "==================================="
echo ""
echo "Verify peers:"
echo "# Check Chain A peer for Chain B:"
echo "cast call $CHAIN_A_OFT \"peers(uint32)(bytes32)\" $CHAIN_B_EID --rpc-url \"$CHAIN_A_RPC_URL\""
echo ""
echo "# Check Chain B peer for Chain A:"
echo "cast call $CHAIN_B_OFT \"peers(uint32)(bytes32)\" $CHAIN_A_EID --rpc-url \"$CHAIN_B_RPC_URL\""
