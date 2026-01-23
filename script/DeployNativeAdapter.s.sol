// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { Script, console } from "forge-std/Script.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IrysNativeOFTAdapter } from "../contracts/IrysNativeOFTAdapter.sol";

/// @title DeployNativeAdapter
/// @notice Deployment script for IrysNativeOFTAdapter (UUPS upgradeable)
/// @dev Usage:
///   # Deploy to testnet with mock endpoint
///   LZ_ENDPOINT=0x... DELEGATE=0x... forge script script/DeployNativeAdapter.s.sol --rpc-url <RPC_URL> --broadcast
///
///   # Deploy to mainnet (use actual LayerZero endpoint)
///   LZ_ENDPOINT=0x1a44076050125825900e736c501f859c50fE728c DELEGATE=0x... forge script script/DeployNativeAdapter.s.sol --rpc-url <RPC_URL> --broadcast
///
/// Required environment variables:
///   LZ_ENDPOINT - LayerZero endpoint address (or mock endpoint for testing)
///   DELEGATE    - Owner/delegate address (should be multisig for production)
contract DeployNativeAdapter is Script {
    function run() external {
        // Required parameters
        address lzEndpoint = vm.envAddress("LZ_ENDPOINT");
        address delegate = vm.envAddress("DELEGATE");

        require(lzEndpoint != address(0), "LZ_ENDPOINT required");
        require(delegate != address(0), "DELEGATE required");

        console.log("Deploying IrysNativeOFTAdapter...");
        console.log("  LZ Endpoint:", lzEndpoint);
        console.log("  Delegate:", delegate);

        vm.startBroadcast();

        // Deploy implementation
        IrysNativeOFTAdapter implementation = new IrysNativeOFTAdapter(lzEndpoint);
        console.log("");
        console.log("Implementation deployed at:", address(implementation));

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeWithSelector(
            IrysNativeOFTAdapter.initialize.selector,
            delegate
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        // Cast proxy to adapter interface for verification
        IrysNativeOFTAdapter adapter = IrysNativeOFTAdapter(payable(address(proxy)));

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Proxy (use this address):", address(proxy));
        console.log("Implementation:", address(implementation));
        console.log("");
        console.log("=== Configuration ===");
        console.log("Owner:", adapter.owner());
        console.log("Token:", adapter.token());
        console.log("Approval Required:", adapter.approvalRequired());
        console.log("Total Escrowed:", adapter.totalEscrowed());
        console.log("Paused:", adapter.paused());
    }
}
