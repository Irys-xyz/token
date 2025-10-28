// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IrysOFT } from "../contracts/IrysOFT.sol";

contract DeployMultiChainScript is Script {
    
    // LayerZero V2 Endpoints (Universal address for most chains)
    address constant UNIVERSAL_ENDPOINT_V2 = 0x1a44076050125825900e736c501f859c50fE728c;

    // Specific endpoints for testnets where Universal endpoint not available
    address constant SEPOLIA_ENDPOINT_V2 = 0x6EDCE65403992e310A62460808c4b910D972f10f;
    address constant BSC_TESTNET_ENDPOINT_V2 = 0x6EDCE65403992e310A62460808c4b910D972f10f;
    
    // Chain configurations
    struct ChainConfig {
        string name;
        uint256 chainId;
        address endpoint;
        string explorerUrl;
    }
    
    function getChainConfig() internal view returns (ChainConfig memory) {
        uint256 chainId = block.chainid;

        // Mainnets (all use Universal V2 Endpoint)
        if (chainId == 1) {
            return ChainConfig("Ethereum", 1, UNIVERSAL_ENDPOINT_V2, "https://etherscan.io");
        } else if (chainId == 56) {
            return ChainConfig("BSC", 56, UNIVERSAL_ENDPOINT_V2, "https://bscscan.com");
        } else if (chainId == 8453) {
            return ChainConfig("Base", 8453, UNIVERSAL_ENDPOINT_V2, "https://basescan.org");
        }
        // Testnets
        else if (chainId == 11155111) {
            return ChainConfig("Sepolia", 11155111, SEPOLIA_ENDPOINT_V2, "https://sepolia.etherscan.io");
        } else if (chainId == 97) {
            return ChainConfig("BSC Testnet", 97, BSC_TESTNET_ENDPOINT_V2, "https://testnet.bscscan.com");
        } else if (chainId == 84532) {
            return ChainConfig("Base Sepolia", 84532, UNIVERSAL_ENDPOINT_V2, "https://sepolia.basescan.org");
        } else {
            revert("Unsupported chain");
        }
    }
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        ChainConfig memory config = getChainConfig();
        
        console.log("===========================================");
        console.log("Deploying IrysOFT to:", config.name);
        console.log("Chain ID:", config.chainId);
        console.log("Deployer address:", deployer);
        console.log("LayerZero Endpoint:", config.endpoint);
        console.log("===========================================");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // 1. Deploy implementation contract
        IrysOFT implementation = new IrysOFT(config.endpoint);
        console.log("Implementation deployed at:", address(implementation));
        
        // 2. Get token configuration from environment (with fallbacks)
        string memory tokenName = vm.envOr("TOKEN_NAME", string("Irys Token"));
        string memory tokenSymbol = vm.envOr("TOKEN_SYMBOL", string("IRYS"));

        // Total supply examples (all values include 18 decimals):
        // 1 million tokens:    1000000000000000000000000
        // 10 million tokens:   10000000000000000000000000
        // 100 million tokens:  100000000000000000000000000
        // 500 million tokens:  500000000000000000000000000
        // 1 billion tokens:    1000000000000000000000000000
        // 2 billion tokens:    2000000000000000000000000000
        // 10 billion tokens:   10000000000000000000000000000

        // Total supply is only non-zero for Ethereum mainnet and Sepolia
        // All other chains get 0 supply (tokens will be bridged via LayerZero)
        uint256 defaultSupply;
        if (config.chainId == 1 || config.chainId == 11155111) {
            // Ethereum mainnet or Sepolia: Default 2B tokens
            defaultSupply = 2_000_000_000 * 10**18;
        } else {
            // All other chains: 0 supply (tokens bridged via LayerZero)
            defaultSupply = 0;
        }
        uint256 totalSupply = vm.envOr("TOTAL_SUPPLY", defaultSupply);

        // 3. Determine owner/delegate address (Gnosis Safe for mainnet, deployer for testnet)
        // For mainnet: set GNOSIS_SAFE_ADDRESS to the multisig address
        // The Gnosis Safe will receive all tokens and become the contract owner
        address ownerDelegate = vm.envOr("GNOSIS_SAFE_ADDRESS", deployer);

        if (ownerDelegate != deployer) {
            console.log("Using Gnosis Safe as owner:", ownerDelegate);
        } else {
            console.log("Using deployer as owner:", deployer);
        }

        // 4. Encode initialization data
        bytes memory initData = abi.encodeWithSelector(
            IrysOFT.initialize.selector,
            tokenName,
            tokenSymbol,
            ownerDelegate,  // Gnosis Safe or deployer becomes owner and receives entire supply
            totalSupply
        );
        
        // 5. Deploy proxy with initialization (entire supply minted to owner/delegate)
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy deployed at:", address(proxy));

        // 6. Wrap proxy in IrysOFT interface
        IrysOFT token = IrysOFT(address(proxy));

        // 7. Verify deployment
        console.log("\n=== DEPLOYMENT VERIFICATION ===");
        console.log("Token name:", token.name());
        console.log("Token symbol:", token.symbol());
        console.log("Token decimals:", token.decimals());
        console.log("Total supply:", token.totalSupply());
        console.log("Owner:", token.owner());
        console.log("Owner balance:", token.balanceOf(ownerDelegate));
        console.log("Contract paused:", token.paused());
        
        vm.stopBroadcast();
        
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Network:", config.name);
        console.log("IrysOFT Proxy Address:", address(proxy));
        console.log("Implementation Address:", address(implementation));
        console.log("Owner/Delegate:", ownerDelegate);
        console.log("Deployer (tx sender):", deployer);
        console.log("Explorer:", config.explorerUrl);

        // Save deployment info to file
        vm.writeLine("deployments.txt", string.concat("# ", config.name, " Deployment"));
        vm.writeLine("deployments.txt", string.concat("Chain ID: ", vm.toString(config.chainId)));
        vm.writeLine("deployments.txt", string.concat("Proxy Address: ", vm.toString(address(proxy))));
        vm.writeLine("deployments.txt", string.concat("Implementation: ", vm.toString(address(implementation))));
        vm.writeLine("deployments.txt", string.concat("LayerZero Endpoint: ", vm.toString(config.endpoint)));
        vm.writeLine("deployments.txt", string.concat("Owner/Delegate: ", vm.toString(ownerDelegate)));
        vm.writeLine("deployments.txt", string.concat("Deployer: ", vm.toString(deployer)));
        vm.writeLine("deployments.txt", string.concat("Explorer: ", config.explorerUrl, "/address/", vm.toString(address(proxy))));
        vm.writeLine("deployments.txt", "");

        console.log("Deployment info saved to deployments.txt");
    }
    
    function addressToString(address addr) internal pure returns (string memory) {
        return vm.toString(addr);
    }
}