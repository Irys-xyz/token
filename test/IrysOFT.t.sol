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
    event OwnershipTransferCanceled();
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

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
        assertEq(aOFT.totalSupply(), MAX_SUPPLY);
        assertEq(bOFT.totalSupply(), MAX_SUPPLY);
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

    function test_invalid_supply_validation() public {
        // Test: Zero supply should revert
        IrysOFT newTokenImpl = new IrysOFT(address(endpoints[aEid]));

        bytes memory initData = abi.encodeWithSelector(
            IrysOFT.initialize.selector,
            "TestToken",
            "TEST",
            owner,
            0 // zero supply
        );

        vm.expectRevert(IrysOFT.IrysOFT__InvalidSupply.selector);
        new ERC1967Proxy(address(newTokenImpl), initData);
    }

    function test_supply_too_large_validation() public {
        // Test: Supply > max/2 should revert
        IrysOFT newTokenImpl = new IrysOFT(address(endpoints[aEid]));

        bytes memory initData = abi.encodeWithSelector(
            IrysOFT.initialize.selector,
            "TestToken",
            "TEST",
            owner,
            type(uint256).max // max supply
        );

        vm.expectRevert(IrysOFT.IrysOFT__SupplyTooLarge.selector);
        new ERC1967Proxy(address(newTokenImpl), initData);
    }

    function test_invalid_name_validation() public {
        // Test: Empty name should revert
        IrysOFT newTokenImpl = new IrysOFT(address(endpoints[aEid]));

        bytes memory initData = abi.encodeWithSelector(
            IrysOFT.initialize.selector,
            "", // empty name
            "TEST",
            owner,
            MAX_SUPPLY
        );

        vm.expectRevert(IrysOFT.IrysOFT__InvalidName.selector);
        new ERC1967Proxy(address(newTokenImpl), initData);

        // Test: Name too long (> 50 chars) should revert
        initData = abi.encodeWithSelector(
            IrysOFT.initialize.selector,
            "ThisIsAVeryLongTokenNameThatExceedsTheFiftyCharacterLimitAndShouldFail",
            "TEST",
            owner,
            MAX_SUPPLY
        );

        vm.expectRevert(IrysOFT.IrysOFT__InvalidName.selector);
        new ERC1967Proxy(address(newTokenImpl), initData);
    }

    function test_invalid_symbol_validation() public {
        // Test: Empty symbol should revert
        IrysOFT newTokenImpl = new IrysOFT(address(endpoints[aEid]));

        bytes memory initData = abi.encodeWithSelector(
            IrysOFT.initialize.selector,
            "TestToken",
            "", // empty symbol
            owner,
            MAX_SUPPLY
        );

        vm.expectRevert(IrysOFT.IrysOFT__InvalidSymbol.selector);
        new ERC1967Proxy(address(newTokenImpl), initData);

        // Test: Symbol too long (> 20 chars) should revert
        initData = abi.encodeWithSelector(
            IrysOFT.initialize.selector,
            "TestToken",
            "THISISAVERYLONGSYMBOLTHATEXCEEDSLIMIT",
            owner,
            MAX_SUPPLY
        );

        vm.expectRevert(IrysOFT.IrysOFT__InvalidSymbol.selector);
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

    // ============ OWNERSHIP TESTS (Two-Step & Renouncement) ============

    function test_two_step_ownership_transfer() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: Current owner proposes transfer
        vm.prank(owner);
        token.transferOwnership(newOwner);

        // Ownership not transferred yet
        assertEq(token.owner(), owner);
        assertEq(token.pendingOwner(), newOwner);

        // Old owner still has control
        vm.prank(owner);
        token.pause();
        assertTrue(token.paused());

        vm.prank(owner);
        token.unpause();
        assertFalse(token.paused());

        // Step 2: New owner accepts ownership
        vm.prank(newOwner);
        token.acceptOwnership();

        // Ownership now transferred
        assertEq(token.owner(), newOwner);
        assertEq(token.pendingOwner(), address(0));

        // Old owner no longer has control
        vm.expectRevert();
        vm.prank(owner);
        token.pause();

        // New owner has control
        vm.prank(newOwner);
        token.pause();
        assertTrue(token.paused());
    }

    function test_non_pending_owner_cannot_accept_ownership() public {
        address newOwner = makeAddr("newOwner");
        address attackerAddr = makeAddr("attackerAddr");

        // Owner proposes transfer to newOwner
        vm.prank(owner);
        token.transferOwnership(newOwner);

        // Attacker tries to accept ownership (should fail)
        vm.expectRevert();
        vm.prank(attackerAddr);
        token.acceptOwnership();

        // Ownership unchanged
        assertEq(token.owner(), owner);
        assertEq(token.pendingOwner(), newOwner);
    }

    function test_pending_owner_can_be_changed() public {
        address firstPendingOwner = makeAddr("firstPendingOwner");
        address secondPendingOwner = makeAddr("secondPendingOwner");

        // Set first pending owner
        vm.prank(owner);
        token.transferOwnership(firstPendingOwner);
        assertEq(token.pendingOwner(), firstPendingOwner);

        // Change to second pending owner
        vm.prank(owner);
        token.transferOwnership(secondPendingOwner);
        assertEq(token.pendingOwner(), secondPendingOwner);

        // First pending owner cannot accept
        vm.expectRevert();
        vm.prank(firstPendingOwner);
        token.acceptOwnership();

        // Second pending owner can accept
        vm.prank(secondPendingOwner);
        token.acceptOwnership();
        assertEq(token.owner(), secondPendingOwner);
    }

    function test_renounce_ownership_disabled() public {
        // Test: renounceOwnership should revert
        vm.expectRevert(IrysOFT.IrysOFT__RenounceOwnershipDisabled.selector);
        vm.prank(owner);
        token.renounceOwnership();

        // Ownership unchanged
        assertEq(token.owner(), owner);

        // Owner still has control
        vm.prank(owner);
        token.pause();
        assertTrue(token.paused());
    }

    function test_non_owner_cannot_transfer_ownership() public {
        address newOwner = makeAddr("newOwner");

        // Non-owner tries to transfer ownership
        vm.expectRevert();
        vm.prank(attacker);
        token.transferOwnership(newOwner);

        // Ownership unchanged
        assertEq(token.owner(), owner);
    }

    function test_owner_can_cancel_pending_transfer() public {
        address newOwner = makeAddr("newOwner");

        // Owner initiates transfer
        vm.prank(owner);
        token.transferOwnership(newOwner);
        assertEq(token.pendingOwner(), newOwner);

        // Owner cancels transfer
        vm.expectEmit(false, false, false, false);
        emit OwnershipTransferCanceled();

        vm.prank(owner);
        token.cancelOwnershipTransfer();

        // No pending owner anymore
        assertEq(token.pendingOwner(), address(0));

        // Original owner still in control
        assertEq(token.owner(), owner);

        // Canceled pending owner cannot accept
        vm.expectRevert();
        vm.prank(newOwner);
        token.acceptOwnership();
    }

    function test_non_owner_cannot_cancel_transfer() public {
        address newOwner = makeAddr("newOwner");

        // Owner initiates transfer
        vm.prank(owner);
        token.transferOwnership(newOwner);

        // Non-owner tries to cancel
        vm.expectRevert();
        vm.prank(attacker);
        token.cancelOwnershipTransfer();

        // Pending owner unchanged
        assertEq(token.pendingOwner(), newOwner);

        // Pending owner can still accept
        vm.prank(newOwner);
        token.acceptOwnership();
        assertEq(token.owner(), newOwner);
    }

    function test_cancel_when_no_pending_transfer() public {
        // No pending transfer exists
        assertEq(token.pendingOwner(), address(0));

        // Cancel still works (no-op)
        vm.expectEmit(false, false, false, false);
        emit OwnershipTransferCanceled();

        vm.prank(owner);
        token.cancelOwnershipTransfer();

        // Still no pending owner
        assertEq(token.pendingOwner(), address(0));
        assertEq(token.owner(), owner);
    }

    function test_cannot_transfer_ownership_to_zero_address() public {
        // Owner tries to transfer to zero address
        vm.expectRevert(IrysOFT.IrysOFT__ZeroAddress.selector);
        vm.prank(owner);
        token.transferOwnership(address(0));

        // Ownership unchanged
        assertEq(token.owner(), owner);
        assertEq(token.pendingOwner(), address(0));
    }

    function test_ownership_transfer_events() public {
        address newOwner = makeAddr("newOwner");

        // Test OwnershipTransferStarted event on transferOwnership
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, newOwner);

        vm.prank(owner);
        token.transferOwnership(newOwner);

        // Test OwnershipTransferred event on acceptOwnership
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, newOwner);

        vm.prank(newOwner);
        token.acceptOwnership();

        // Verify ownership actually changed
        assertEq(token.owner(), newOwner);
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
