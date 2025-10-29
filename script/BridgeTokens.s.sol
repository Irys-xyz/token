// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IrysOFT} from "../contracts/IrysOFT.sol";
import {SendParam} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {MessagingFee} from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

contract BridgeTokensScript is Script {
    using OptionsBuilder for bytes;

    function run() external {
        // Read configuration from environment variables
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address sourceOFT = vm.envAddress("SOURCE_OFT");
        uint32 destinationEID = uint32(vm.envUint("DESTINATION_EID"));
        address destinationOFT = vm.envAddress("DESTINATION_OFT");
        uint256 amount = vm.envUint("BRIDGE_AMOUNT");

        console.log("==========================================");
        console.log("LayerZero Cross-Chain Token Bridge");
        console.log("==========================================");
        console.log("Source OFT:", sourceOFT);
        console.log("Destination EID:", destinationEID);
        console.log("Destination OFT:", destinationOFT);
        console.log("Sender:", deployer);
        console.log("Amount:", amount);
        console.log("==========================================");

        IrysOFT oft = IrysOFT(sourceOFT);

        // Check balance before
        uint256 balanceBefore = oft.balanceOf(deployer);
        console.log("Balance before:", balanceBefore);

        vm.startBroadcast(deployerPrivateKey);

        // Prepare SendParam
        bytes32 recipient = bytes32(uint256(uint160(deployer)));
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        // Quote the fee
        SendParam memory sendParam = SendParam({
            dstEid: destinationEID,
            to: recipient,
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: options,
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory fee = oft.quoteSend(sendParam, false);

        console.log("LayerZero fee:", fee.nativeFee);

        // Send tokens
        oft.send{value: fee.nativeFee}(sendParam, fee, payable(deployer));

        vm.stopBroadcast();

        // Check balance after
        uint256 balanceAfter = oft.balanceOf(deployer);
        console.log("Balance after:", balanceAfter);
        console.log("Tokens sent:", balanceBefore - balanceAfter);

        console.log("\n==========================================");
        console.log("Bridge transaction submitted!");
        console.log("==========================================");
        console.log("Wait 5-10 minutes for LayerZero to relay the message.");
        console.log("\nCheck destination balance:");
        console.log("Destination OFT:", destinationOFT);
        console.log("Recipient:", deployer);
    }
}
