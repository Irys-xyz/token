// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { Script, console } from "forge-std/Script.sol";
import { LZEndpointMock } from "../contracts/mocks/LZEndpointMock.sol";

/// @title DeployLZEndpointMock
/// @notice Deployment script for LZEndpointMock
/// @dev Usage:
///   # Deploy with default endpoint ID (1)
///   forge script script/DeployLZEndpointMock.s.sol --rpc-url <RPC_URL> --broadcast
///
///   # Deploy with custom endpoint ID
///   ENDPOINT_ID=30101 forge script script/DeployLZEndpointMock.s.sol --rpc-url <RPC_URL> --broadcast
///
///   # Deploy with custom fee
///   ENDPOINT_ID=30101 NATIVE_FEE=0.001ether forge script script/DeployLZEndpointMock.s.sol --rpc-url <RPC_URL> --broadcast
contract DeployLZEndpointMock is Script {
    function run() external {
        // Get endpoint ID from env or default to 1
        uint32 endpointId = uint32(vm.envOr("ENDPOINT_ID", uint256(1)));

        // Get optional fee configuration
        uint256 nativeFee = vm.envOr("NATIVE_FEE", uint256(0.001 ether));
        uint256 lzTokenFee = vm.envOr("LZ_TOKEN_FEE", uint256(0));

        console.log("Deploying LZEndpointMock...");
        console.log("  Endpoint ID:", endpointId);
        console.log("  Native Fee:", nativeFee);
        console.log("  LZ Token Fee:", lzTokenFee);

        vm.startBroadcast();

        LZEndpointMock endpoint = new LZEndpointMock(endpointId);

        // Set custom fee if different from default
        if (nativeFee != 0.001 ether || lzTokenFee != 0) {
            endpoint.setMockFee(nativeFee, lzTokenFee);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("LZEndpointMock deployed at:", address(endpoint));
        console.log("  Owner:", endpoint.owner());
        console.log("  Endpoint ID:", endpoint.eid());
        console.log("  Mock Native Fee:", endpoint.mockNativeFee());
    }
}
