// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { IrysOFT } from "../contracts/IrysOFT.sol";
import { IrysOFTTestable } from "../contracts/mocks/IrysOFTTestable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";

// OApp imports
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

// OFT imports
import { SendParam } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingFee, MessagingReceipt } from "@layerzerolabs/oft-evm/contracts/OFTCore.sol";

import "forge-std/console.sol";

contract IrysOFTTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    uint32 private aEid = 1;
    uint32 private bEid = 2;

    IrysOFT private token;
    IrysOFT private tokenImpl;
    IrysOFT private aOFT;
    IrysOFT private bOFT;

    address private owner = makeAddr("owner");
    address private userA = makeAddr("userA");
    address private userB = makeAddr("userB");
    address private attacker = makeAddr("attacker");

    uint256 private constant MAX_SUPPLY = 2_000_000_000 * 10**18;
    uint256 private initialBalance = 100 ether;

    // Events to test
    event Initialized(string name, string symbol, address indexed delegate, uint256 totalSupply);
    event Paused(address account);
    event Unpaused(address account);

    function setUp() public virtual override {
        vm.deal(owner, 1000 ether);
        vm.deal(userA, 1000 ether);
        vm.deal(userB, 1000 ether);
        vm.deal(attacker, 1000 ether);

        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        // Deploy implementation for proxy tests
        tokenImpl = new IrysOFT(address(endpoints[aEid]));

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            IrysOFT.initialize.selector,
            "IrysToken",
            "IRYS",
            owner,
            MAX_SUPPLY
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(tokenImpl), initData);
        token = IrysOFT(address(proxy));

        // Deploy IrysOFTTestable contracts for cross-chain testing
        IrysOFTTestable aOFTTestable = new IrysOFTTestable(address(endpoints[aEid]));
        IrysOFTTestable bOFTTestable = new IrysOFTTestable(address(endpoints[bEid]));

        // Initialize the testable contracts
        aOFTTestable.initialize("aOFT", "aOFT", owner, MAX_SUPPLY);
        bOFTTestable.initialize("bOFT", "bOFT", owner, MAX_SUPPLY);

        aOFT = IrysOFT(address(aOFTTestable));
        bOFT = IrysOFT(address(bOFTTestable));

        // Configure peers for cross-chain testing
        vm.startPrank(owner);
        aOFT.setPeer(bEid, addressToBytes32(address(bOFT)));
        bOFT.setPeer(aEid, addressToBytes32(address(aOFT)));

        // Transfer some tokens from owner to test users (entire supply is minted to owner at deployment)
        aOFT.transfer(userA, initialBalance);
        bOFT.transfer(userB, initialBalance);
        vm.stopPrank();
    }

    // ============ INITIALIZATION TESTS ============

    function test_initialization() public {
        assertEq(aOFT.owner(), owner);
        assertEq(bOFT.owner(), owner);

        assertEq(aOFT.name(), "aOFT");
        assertEq(bOFT.name(), "bOFT");

        assertEq(aOFT.symbol(), "aOFT");
        assertEq(bOFT.symbol(), "bOFT");

        assertEq(aOFT.decimals(), 18);
        assertEq(bOFT.decimals(), 18);

        // Check that entire fixed supply was minted at deployment
        assertEq(aOFT.totalSupply(), MAX_SUPPLY);
        assertEq(bOFT.totalSupply(), MAX_SUPPLY);
    }

    // The contract now implements fixed supply model - entire supply minted at deployment

    // ============ UPGRADE TESTS ============

    function test_upgrade_only_owner() public {
        // Deploy new implementation
        IrysOFT newImpl = new IrysOFT(address(endpoints[aEid]));

        // Test: Non-owner cannot upgrade
        vm.expectRevert();
        vm.prank(attacker);
        token.upgradeToAndCall(address(newImpl), "");

        // Test: Owner can upgrade
        vm.prank(owner);
        token.upgradeToAndCall(address(newImpl), "");
    }

    function test_state_preserved_after_upgrade() public {
        // Setup: Set some state
        vm.startPrank(owner);
        token.transfer(userA, 1000 ether);
        vm.stopPrank();

        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(userA);

        // Perform upgrade
        IrysOFT newImpl = new IrysOFT(address(endpoints[aEid]));
        vm.prank(owner);
        token.upgradeToAndCall(address(newImpl), "");

        // Test: State is preserved
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.balanceOf(userA), balanceBefore);
        assertEq(token.owner(), owner);
    }

    // ============ EVENT EMISSION TESTS ============

    function test_event_Paused_Unpaused() public {
        vm.expectEmit(false, false, false, true);
        emit Paused(owner);

        vm.prank(owner);
        token.pause();

        vm.expectEmit(false, false, false, true);
        emit Unpaused(owner);

        vm.prank(owner);
        token.unpause();
    }

    // ============ PAUSABLE FUNCTIONALITY TESTS ============

    function test_pausable_functionality() public {
        uint256 userABalanceBefore = aOFT.balanceOf(userA);
        uint256 userBBalanceBefore = aOFT.balanceOf(userB);

        // Pause contract
        vm.prank(owner);
        aOFT.pause();

        // Transfers should be blocked
        vm.expectRevert();
        vm.prank(userA);
        aOFT.transfer(userB, 1000);

        // Unpause
        vm.prank(owner);
        aOFT.unpause();

        // Transfers should work again
        vm.prank(userA);
        aOFT.transfer(userB, 1000);
        assertEq(aOFT.balanceOf(userA), userABalanceBefore - 1000);
        assertEq(aOFT.balanceOf(userB), userBBalanceBefore + 1000);
    }

    function test_pause_blocks_transfers() public {
        vm.startPrank(owner);
        token.transfer(userA, 1000 ether);
        token.pause();
        vm.stopPrank();

        // Test: Transfers fail when paused
        vm.expectRevert();
        vm.prank(userA);
        token.transfer(userB, 100 ether);
    }

    function test_only_owner_can_pause() public {
        // Non-owner cannot pause
        vm.expectRevert();
        vm.prank(userA);
        token.pause();

        // Owner can pause
        vm.prank(owner);
        token.pause();

        // Non-owner cannot unpause
        vm.expectRevert();
        vm.prank(userA);
        token.unpause();

        // Owner can unpause
        vm.prank(owner);
        token.unpause();
    }

    // ============ SUPPLY TRACKING TESTS ============

    function test_supply_tracking() public {
        // Check fixed supply - entire supply minted at deployment
        assertEq(aOFT.getCurrentSupply(), MAX_SUPPLY);
        assertEq(aOFT.totalSupply(), MAX_SUPPLY);
    }

    // ============ EDGE CASES & SECURITY TESTS ============

    function test_zero_address_validation_on_init() public {
        // Test: Initializing with zero address delegate should revert
        IrysOFT newTokenImpl = new IrysOFT(address(endpoints[aEid]));

        bytes memory initData = abi.encodeWithSelector(
            IrysOFT.initialize.selector,
            "TestToken",
            "TEST",
            address(0), // zero address delegate
            MAX_SUPPLY
        );

        vm.expectRevert(IrysOFT.IrysOFT__ZeroAddress.selector);
        new ERC1967Proxy(address(newTokenImpl), initData);
    }

    function test_fixed_supply_immutable() public {
        // Test: Total supply is fixed at deployment
        assertEq(token.totalSupply(), MAX_SUPPLY);

        // Transfer some tokens
        vm.prank(owner);
        token.transfer(userA, 1000 ether);

        // Supply remains unchanged
        assertEq(token.totalSupply(), MAX_SUPPLY);
    }

    // ============ CROSS-CHAIN TRANSFER TESTS ============

    function test_cross_chain_transfer() public {
        uint256 tokensToSend = 1 ether;
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        SendParam memory sendParam = SendParam(
            bEid,
            addressToBytes32(userB),
            tokensToSend,
            tokensToSend,
            options,
            "",
            ""
        );
        MessagingFee memory fee = aOFT.quoteSend(sendParam, false);

        assertEq(aOFT.balanceOf(userA), initialBalance);
        assertEq(bOFT.balanceOf(userB), initialBalance);

        vm.prank(userA);
        aOFT.send{ value: fee.nativeFee }(sendParam, fee, payable(address(this)));
        verifyPackets(bEid, addressToBytes32(address(bOFT)));

        assertEq(aOFT.balanceOf(userA), initialBalance - tokensToSend);
        assertEq(bOFT.balanceOf(userB), initialBalance + tokensToSend);
    }
}
