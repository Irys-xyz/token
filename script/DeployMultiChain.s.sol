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
        } else if (chainId == 42161) {
            return ChainConfig("Arbitrum", 42161, UNIVERSAL_ENDPOINT_V2, "https://arbiscan.io");
        } else if (chainId == 137) {
            return ChainConfig("Polygon", 137, UNIVERSAL_ENDPOINT_V2, "https://polygonscan.com");
        } else if (chainId == 8453) {
            return ChainConfig("Base", 8453, UNIVERSAL_ENDPOINT_V2, "https://basescan.org");
        }
        // Testnets
        else if (chainId == 11155111) {
            return ChainConfig("Sepolia", 11155111, SEPOLIA_ENDPOINT_V2, "https://sepolia.etherscan.io");
        } else if (chainId == 421614) {
            return ChainConfig("Arbitrum Sepolia", 421614, UNIVERSAL_ENDPOINT_V2, "https://sepolia.arbiscan.io");
        } else if (chainId == 80002) {
            return ChainConfig("Polygon Amoy", 80002, UNIVERSAL_ENDPOINT_V2, "https://amoy.polygonscan.com");
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
        
        // Max supply examples (all values include 18 decimals):
        // 1 million tokens:    1000000000000000000000000
        // 10 million tokens:   10000000000000000000000000
        // 100 million tokens:  100000000000000000000000000
        // 500 million tokens:  500000000000000000000000000
        // 1 billion tokens:    1000000000000000000000000000
        // 2 billion tokens:    2000000000000000000000000000
        // 10 billion tokens:   10000000000000000000000000000
        uint256 maxSupply = vm.envOr("MAX_SUPPLY", uint256(2_000_000_000 * 10**18)); // Default 2B tokens
        
        // 3. Encode initialization data with minting included
        bytes memory initData = abi.encodeWithSelector(
            IrysOFT.initialize.selector,
            tokenName,
            tokenSymbol,
            deployer,  // deployer becomes owner and initial minter/burner
            maxSupply  // This will be minted to deployer during initialization
        );
        
        // 4. Deploy proxy with initialization (minting happens in constructor via initialize)
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        console.log("Proxy deployed at:", address(proxy));
        
        // 5. Wrap proxy in IrysOFT interface
        IrysOFT token = IrysOFT(address(proxy));
        
        // 6. Verify deployment
        console.log("\n=== DEPLOYMENT VERIFICATION ===");
        console.log("Token name:", token.name());
        console.log("Token symbol:", token.symbol());
        console.log("Token decimals:", token.decimals());
        console.log("Max supply:", token.getMaxSupply());
        console.log("Current supply:", token.getCurrentSupply());
        console.log("Deployer balance:", token.balanceOf(deployer)); // Should equal maxSupply
        console.log("Owner:", token.owner());
        console.log("Deployer is minter:", token.isMinter(deployer));
        console.log("Deployer is burner:", token.isBurner(deployer));
        console.log("Contract paused:", token.paused());
        
        vm.stopBroadcast();
        
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Network:", config.name);
        console.log("IrysOFT Proxy Address:", address(proxy));
        console.log("Implementation Address:", address(implementation));
        console.log("Owner/Delegate:", deployer);
        console.log("Explorer URL:", string.concat(config.explorerUrl, "/address/", addressToString(address(proxy))));
        
        // Save deployment info to file
        string memory deploymentInfo = string.concat(
            "# ", config.name, " Deployment\n",
            "Chain ID: ", vm.toString(config.chainId), "\n",
            "Proxy Address: ", addressToString(address(proxy)), "\n",
            "Implementation: ", addressToString(address(implementation)), "\n",
            "LayerZero Endpoint: ", addressToString(config.endpoint), "\n",
            "Owner: ", addressToString(deployer), "\n",
            "Explorer: ", config.explorerUrl, "/address/", addressToString(address(proxy)), "\n\n"
        );
        
        vm.writeFile("deployments.txt", deploymentInfo);
        console.log("Deployment info saved to deployments.txt");
    }
    
    function addressToString(address addr) internal pure returns (string memory) {
        return vm.toString(addr);
    }
}