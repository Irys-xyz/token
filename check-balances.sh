#!/bin/bash

# Cross-Chain Balance Check Script
# Usage: ./check-balances.sh <chain_a_oft> <chain_a_name> <chain_b_oft> <chain_b_name> [address] [expected_total]
# Or set environment variables and run: ./check-balances.sh

set -e

# Load environment if .env exists
if [ -f .env ]; then
    source .env
fi

# Parse command-line arguments or use environment variables
CHAIN_A_OFT="${1:-${CHAIN_A_OFT}}"
CHAIN_A_NAME="${2:-${CHAIN_A_NAME:-Chain A}}"
CHAIN_B_OFT="${3:-${CHAIN_B_OFT}}"
CHAIN_B_NAME="${4:-${CHAIN_B_NAME:-Chain B}}"
CHECK_ADDRESS="${5:-${CHECK_ADDRESS}}"
EXPECTED_TOTAL="${6:-${EXPECTED_TOTAL:-2000000000}}" # Default 2 billion

# Validate required parameters
if [ -z "$CHAIN_A_OFT" ] || [ -z "$CHAIN_B_OFT" ]; then
    echo "Error: Missing required parameters"
    echo ""
    echo "Usage: $0 <chain_a_oft> <chain_a_name> <chain_b_oft> <chain_b_name> [address] [expected_total]"
    echo ""
    echo "Or set environment variables:"
    echo "  CHAIN_A_OFT       - Chain A OFT contract address"
    echo "  CHAIN_A_NAME      - Chain A name (e.g., 'Sepolia', 'BSC Testnet')"
    echo "  CHAIN_B_OFT       - Chain B OFT contract address"
    echo "  CHAIN_B_NAME      - Chain B name (e.g., 'Base Sepolia')"
    echo "  CHAIN_A_RPC_URL   - Chain A RPC URL"
    echo "  CHAIN_B_RPC_URL   - Chain B RPC URL"
    echo "  CHECK_ADDRESS     - (Optional) Address to check balance for"
    echo "  EXPECTED_TOTAL    - (Optional) Expected total supply across chains (default: 2000000000)"
    echo ""
    echo "Example:"
    echo "  $0 0x95Ae64c9d98D5825b5261Dde30Bd482684032bC0 'Sepolia' 0x0929dDd19F9EF7e15E206015C9987573e489e928 'BSC Testnet'"
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

echo "========================================"
echo "Cross-Chain Balance Check"
echo "========================================"
echo ""

# Check Chain A
echo "$CHAIN_A_NAME:"
CHAIN_A_SUPPLY=$(cast call $CHAIN_A_OFT "totalSupply()(uint256)" --rpc-url $CHAIN_A_RPC_URL | grep -oE '[0-9]+' | head -1)
echo "  Total Supply: $CHAIN_A_SUPPLY"

if [ -n "$CHECK_ADDRESS" ]; then
    CHAIN_A_BALANCE=$(cast call $CHAIN_A_OFT "balanceOf(address)(uint256)" $CHECK_ADDRESS --rpc-url $CHAIN_A_RPC_URL | grep -oE '[0-9]+' | head -1)
    echo "  Balance ($CHECK_ADDRESS): $CHAIN_A_BALANCE"
fi
echo ""

# Check Chain B
echo "$CHAIN_B_NAME:"
CHAIN_B_SUPPLY=$(cast call $CHAIN_B_OFT "totalSupply()(uint256)" --rpc-url $CHAIN_B_RPC_URL | grep -oE '[0-9]+' | head -1)
echo "  Total Supply: $CHAIN_B_SUPPLY"

if [ -n "$CHECK_ADDRESS" ]; then
    CHAIN_B_BALANCE=$(cast call $CHAIN_B_OFT "balanceOf(address)(uint256)" $CHECK_ADDRESS --rpc-url $CHAIN_B_RPC_URL | grep -oE '[0-9]+' | head -1)
    echo "  Balance ($CHECK_ADDRESS): $CHAIN_B_BALANCE"
fi
echo ""

echo "========================================"
echo "Analysis:"
echo "========================================"

python3 << EOF
chain_a_supply = int("$CHAIN_A_SUPPLY") / 10**18
chain_b_supply = int("$CHAIN_B_SUPPLY") / 10**18
total = chain_a_supply + chain_b_supply
expected = int("$EXPECTED_TOTAL")

print(f"$CHAIN_A_NAME Total: {chain_a_supply:,.0f} IRYS")
print(f"$CHAIN_B_NAME Total: {chain_b_supply:,.0f} IRYS")
print(f"Combined Total: {total:,.0f} IRYS")
print(f"Expected: {expected:,.0f} IRYS")
print("")

if abs(total - expected) < 10:
    print(" SUCCESS! Total supplies match expected!")
else:
    diff = expected - total
    if diff > 0:
        print(f"⏳ Waiting for LayerZero relay...")
        print(f"   {abs(diff):,.0f} tokens pending delivery")
    else:
        print(f"  WARNING: Total supply exceeds expected by {abs(diff):,.0f} tokens!")

# Show individual balances if address was provided
if "$CHECK_ADDRESS":
    print("")
    chain_a_balance = int("${CHAIN_A_BALANCE:-0}") / 10**18
    chain_b_balance = int("${CHAIN_B_BALANCE:-0}") / 10**18
    total_balance = chain_a_balance + chain_b_balance

    print(f"Address Balance ($CHECK_ADDRESS):")
    print(f"  $CHAIN_A_NAME: {chain_a_balance:,.0f} IRYS")
    print(f"  $CHAIN_B_NAME: {chain_b_balance:,.0f} IRYS")
    print(f"  Total: {total_balance:,.0f} IRYS")
EOF
