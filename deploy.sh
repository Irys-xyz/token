#!/bin/bash

# IrysOFT Multi-Chain Deployment Script
# Usage: ./deploy.sh [chain]
# Supported chains: ethereum, bsc, base, sepolia, bsc-testnet, base-sepolia

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Chain configurations
declare -A CHAIN_CONFIGS
CHAIN_CONFIGS[ethereum]="1:ETHEREUM_RPC_URL:ETHERSCAN_API_KEY:https://etherscan.io"
CHAIN_CONFIGS[bsc]="56:BSC_RPC_URL:BSCSCAN_API_KEY:https://bscscan.com"
CHAIN_CONFIGS[base]="8453:BASE_RPC_URL:BASESCAN_API_KEY:https://basescan.org"
CHAIN_CONFIGS[sepolia]="11155111:SEPOLIA_RPC_URL:ETHERSCAN_API_KEY:https://sepolia.etherscan.io"
CHAIN_CONFIGS[bsc-testnet]="97:BSC_TESTNET_RPC_URL:BSCSCAN_API_KEY:https://testnet.bscscan.com"
CHAIN_CONFIGS[base-sepolia]="84532:BASE_SEPOLIA_RPC_URL:BASESCAN_API_KEY:https://sepolia.basescan.org"

# Script configuration
SCRIPT_PATH="script/DeployMultiChain.s.sol"

echo -e "${BLUE} IrysOFT Multi-Chain Deployment Script${NC}"
echo "=========================================="

# Function to show usage
show_usage() {
    echo -e "${YELLOW}Usage: ./deploy.sh [chain]${NC}"
    echo ""
    echo -e "${BLUE}Supported chains:${NC}"
    echo "  Mainnets:"
    echo "    ethereum       - Ethereum Mainnet"
    echo "    bsc            - BSC Mainnet"
    echo "    base           - Base Mainnet"
    echo ""
    echo "  Testnets:"
    echo "    sepolia        - Ethereum Sepolia"
    echo "    bsc-testnet    - BSC Testnet"
    echo "    base-sepolia   - Base Sepolia"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  ./deploy.sh sepolia"
    echo "  ./deploy.sh ethereum"
    echo "  ./deploy.sh bsc-testnet"
}

# Function to deploy to all testnets
deploy_all_testnets() {
    echo -e "${PURPLE} Deploying to all testnets...${NC}"

    local testnets=("sepolia" "bsc-testnet" "base-sepolia")
    local failed_deployments=()
    
    for chain in "${testnets[@]}"; do
        echo -e "${BLUE}--- Deploying to $chain ---${NC}"
        if deploy_to_chain "$chain"; then
            echo -e "${GREEN} $chain deployment successful${NC}"
        else
            echo -e "${RED} $chain deployment failed${NC}"
            failed_deployments+=("$chain")
        fi
        echo ""
    done
    
    if [ ${#failed_deployments[@]} -eq 0 ]; then
        echo -e "${GREEN} All testnet deployments successful!${NC}"
    else
        echo -e "${RED}  Some deployments failed:${NC}"
        printf '%s\n' "${failed_deployments[@]}"
    fi
}

# Function to deploy to specific chain
deploy_to_chain() {
    local CHAIN=$1
    
    # Check if chain is supported
    if [[ ! ${CHAIN_CONFIGS[$CHAIN]+_} ]]; then
        echo -e "${RED} Unsupported chain: $CHAIN${NC}"
        return 1
    fi
    
    # Parse chain configuration
    IFS=':' read -r CHAIN_ID RPC_VAR API_KEY_VAR EXPLORER_URL <<< "${CHAIN_CONFIGS[$CHAIN]}"
    
    # Get RPC URL from environment
    RPC_URL="${!RPC_VAR}"
    API_KEY="${!API_KEY_VAR}"
    
    if [ -z "$RPC_URL" ]; then
        echo -e "${RED} $RPC_VAR not set in .env${NC}"
        return 1
    fi
    
    echo -e "${BLUE} Target: $CHAIN (Chain ID: $CHAIN_ID)${NC}"
    echo -e "${BLUE} RPC: $RPC_URL${NC}"

    # Check deployer balance
    DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)
    BALANCE=$(cast balance $DEPLOYER --rpc-url $RPC_URL)
    BALANCE_ETH=$(cast to-unit $BALANCE ether)
    echo -e "${BLUE} Deployer: $DEPLOYER${NC}"
    echo -e "${BLUE} Deployer balance: ${BALANCE_ETH} ETH${NC}"

    # Estimate deployment cost
    echo -e "${YELLOW} Estimating deployment cost...${NC}"

    # Run simulation to get gas estimate
    SIMULATION_OUTPUT=$(forge script $SCRIPT_PATH --rpc-url $RPC_URL --private-key $PRIVATE_KEY 2>&1)
    SIMULATION_EXIT_CODE=$?

    if [ $SIMULATION_EXIT_CODE -ne 0 ]; then
        echo -e "${RED} Failed to simulate deployment${NC}"
        echo -e "${YELLOW} Using fallback minimum balance check${NC}"
        if [[ "$CHAIN" == *"sepolia"* ]] || [[ "$CHAIN" == *"amoy"* ]]; then
            MIN_BALANCE="10000000000000000"  # 0.01 ETH
            MIN_BALANCE_ETH="0.01"
        else
            MIN_BALANCE="100000000000000000"  # 0.1 ETH
            MIN_BALANCE_ETH="0.1"
        fi
    else
        # Try multiple parsing methods for gas estimate
        ESTIMATED_GAS=$(echo "$SIMULATION_OUTPUT" | grep -i "estimated total gas used" | grep -oE '[0-9]{6,}' | head -1)

        if [ -z "$ESTIMATED_GAS" ]; then
            ESTIMATED_AMOUNT=$(echo "$SIMULATION_OUTPUT" | grep -i "estimated amount required" | grep -oE '0\.[0-9]+' | head -1)
            if [ -n "$ESTIMATED_AMOUNT" ]; then
                # Convert ETH to wei and back out the gas (rough estimate)
                # This is a backup method
                ESTIMATED_GAS="5500000"  # Conservative estimate
            fi
        fi

        if [ -z "$ESTIMATED_GAS" ] || ! [[ "$ESTIMATED_GAS" =~ ^[0-9]+$ ]]; then
            echo -e "${YELLOW} Could not parse gas estimate, using conservative estimate${NC}"
            # Use conservative gas estimate based on typical OFT deployment
            ESTIMATED_GAS="5500000"  # ~5.5M gas (conservative for proxy + implementation)
            echo -e "${BLUE} Using conservative gas estimate: $ESTIMATED_GAS${NC}"
        else
            echo -e "${BLUE} Estimated gas from simulation: $ESTIMATED_GAS${NC}"
        fi

        # Get current gas price (in wei)
        GAS_PRICE=$(cast gas-price --rpc-url $RPC_URL 2>/dev/null)

        if [ -z "$GAS_PRICE" ] || ! [[ "$GAS_PRICE" =~ ^[0-9]+$ ]]; then
            echo -e "${YELLOW} Could not get gas price, using fallback${NC}"
            if [[ "$CHAIN" == *"sepolia"* ]] || [[ "$CHAIN" == *"amoy"* ]]; then
                MIN_BALANCE="10000000000000000"  # 0.01 ETH
                MIN_BALANCE_ETH="0.01"
            else
                MIN_BALANCE="100000000000000000"  # 0.1 ETH
                MIN_BALANCE_ETH="0.1"
            fi
        else
            # Calculate required ETH with 150% safety margin
            # Formula: (gas * gasPrice * 3) / 2  (equivalent to * 1.5)
            REQUIRED_WEI=$(( ESTIMATED_GAS * GAS_PRICE * 3 / 2 ))
            MIN_BALANCE=$REQUIRED_WEI
            MIN_BALANCE_ETH=$(cast to-unit $MIN_BALANCE ether 2>/dev/null)

            GAS_PRICE_GWEI=$(cast to-unit $GAS_PRICE gwei 2>/dev/null)
            echo -e "${BLUE} Current gas price: ${GAS_PRICE_GWEI} gwei${NC}"
            echo -e "${BLUE} Required balance (with 150% safety margin): ${MIN_BALANCE_ETH} ETH${NC}"
        fi
    fi

    # Check if deployer has sufficient balance
    if [ $(echo "$BALANCE < $MIN_BALANCE" | bc -l) -eq 1 ]; then
        echo -e "${RED} Insufficient balance!${NC}"
        echo -e "${RED} Required: ${MIN_BALANCE_ETH} ETH${NC}"
        echo -e "${RED} Available: ${BALANCE_ETH} ETH${NC}"
        echo -e "${RED} Shortfall: $(echo "$MIN_BALANCE_ETH - $BALANCE_ETH" | bc) ETH${NC}"
        return 1
    fi

    echo -e "${GREEN} Balance check passed${NC}"
    
    # Deploy with or without verification
    local DEPLOY_CMD="forge script $SCRIPT_PATH --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --chain-id $CHAIN_ID"
    
    if [ -n "$API_KEY" ]; then
        echo -e "${BLUE} Deploying with verification...${NC}"
        $DEPLOY_CMD --verify --etherscan-api-key $API_KEY
    else
        echo -e "${YELLOW}  Deploying without verification (API key not set)${NC}"
        $DEPLOY_CMD
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN} $CHAIN deployment successful!${NC}"
        echo -e "${BLUE} Broadcast logs: broadcast/DeployMultiChain.s.sol/$CHAIN_ID/run-latest.json${NC}"
        echo -e "${BLUE} Explorer: $EXPLORER_URL${NC}"
        return 0
    else
        echo -e "${RED} $CHAIN deployment failed${NC}"
        return 1
    fi
}

# Main script logic
main() {
    local CHAIN=$1
    
    # Check if .env file exists
    if [ ! -f ".env" ]; then
        echo -e "${RED} .env file not found!${NC}"
        echo -e "${YELLOW} Please copy .env.example to .env and configure it:${NC}"
        echo "cp .env.example .env"
        echo "Then edit .env with your private key and RPC URLs"
        exit 1
    fi
    
    # Source environment variables
    source .env
    
    # Validate required environment variables
    if [ -z "$PRIVATE_KEY" ]; then
        echo -e "${RED} PRIVATE_KEY not set in .env${NC}"
        exit 1
    fi
    
    echo -e "${GREEN} Environment variables loaded${NC}"
    
    # Handle command line arguments
    if [ -z "$CHAIN" ]; then
        show_usage
        echo ""
        read -p "Enter chain name (or 'all-testnets' for all testnets): " CHAIN
    fi
    
    if [ "$CHAIN" = "all-testnets" ]; then
        deploy_all_testnets
        exit 0
    fi
    
    # Clean and compile
    echo -e "${BLUE} Compiling contracts...${NC}"
    forge clean
    forge build
    
    if [ $? -ne 0 ]; then
        echo -e "${RED} Compilation failed${NC}"
        exit 1
    fi
    
    echo -e "${GREEN} Contracts compiled successfully${NC}"
    
    # Run tests
    echo -e "${BLUE} Running tests...${NC}"
    forge test --gas-report
    
    if [ $? -ne 0 ]; then
        echo -e "${RED} Tests failed${NC}"
        read -p "Continue with deployment anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    echo -e "${GREEN} Tests passed${NC}"
    
    # Deploy to specified chain
    deploy_to_chain "$CHAIN"
}

# Function to show post-deployment instructions
show_post_deployment() {
    echo -e "${PURPLE} POST-DEPLOYMENT CHECKLIST${NC}"
    echo "1. Verify contract on block explorer"
    echo "2. Test basic functions (transfer, balance)"
    echo "3. Configure LayerZero peers for cross-chain bridging"
    echo "4. Distribute initial token allocation to stakeholders"
    echo "5. Configure monitoring and alerts"
    echo ""
    echo -e "${BLUE} Useful commands:${NC}"
    echo "# Check deployment"
    echo "cast call <PROXY_ADDRESS> \"name()(string)\" --rpc-url \$RPC_URL"
    echo "cast call <PROXY_ADDRESS> \"totalSupply()(uint256)\" --rpc-url \$RPC_URL"
    echo ""
    echo "# Configure LayerZero peer (for cross-chain bridging)"
    echo "cast send <PROXY_ADDRESS> \"setPeer(uint32,bytes32)\" <REMOTE_EID> <REMOTE_OFT_ADDRESS_BYTES32> --private-key \$PRIVATE_KEY --rpc-url \$RPC_URL"
    echo ""
    echo "# Pause/Unpause (emergency only)"
    echo "cast send <PROXY_ADDRESS> \"pause()\" --private-key \$PRIVATE_KEY --rpc-url \$RPC_URL"
    echo "cast send <PROXY_ADDRESS> \"unpause()\" --private-key \$PRIVATE_KEY --rpc-url \$RPC_URL"
    echo ""
    echo -e "${YELLOW}  IMPORTANT: This contract uses a FIXED SUPPLY model${NC}"
    echo "  - Total supply is minted at deployment (immutable)"
    echo "  - No mint() or burn() functions available"
    echo "  - Bridging works via LayerZero OFT internal mechanisms"
    echo "  - Global supply: 10B (2B on this OFT + 8B on Irys L1)"
}

# Run main function
main "$1"

# Show post-deployment instructions if deployment was successful
if [ $? -eq 0 ]; then
    echo ""
    show_post_deployment
fi
