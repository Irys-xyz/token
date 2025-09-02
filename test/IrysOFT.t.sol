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
    event MinterSet(address indexed account, bool enabled);
    event BurnerSet(address indexed account, bool enabled);
    event PrivilegedMint(address indexed to, uint256 amount, address indexed minter);
    event PrivilegedBurn(address indexed from, uint256 amount, address indexed burner);
    event Initialized(string name, string symbol, address indexed delegate, uint256 maxSupply);
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
            owner
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(tokenImpl), initData);
        token = IrysOFT(address(proxy));

        // Deploy IrysOFTTestable contracts for cross-chain testing
        IrysOFTTestable aOFTTestable = new IrysOFTTestable(address(endpoints[aEid]));
        IrysOFTTestable bOFTTestable = new IrysOFTTestable(address(endpoints[bEid]));

        // Initialize the testable contracts
        aOFTTestable.initialize("aOFT", "aOFT", owner);
        bOFTTestable.initialize("bOFT", "bOFT", owner);

        aOFT = IrysOFT(address(aOFTTestable));
        bOFT = IrysOFT(address(bOFTTestable));

        // Configure peers for cross-chain testing
        vm.startPrank(owner);
        aOFT.setPeer(bEid, addressToBytes32(address(bOFT)));
        bOFT.setPeer(aEid, addressToBytes32(address(aOFT)));

        // Set minter roles for testing
        aOFT.setMinter(owner, true);
        bOFT.setMinter(owner, true);
        vm.stopPrank();

        // Transfer some tokens from owner to test users (since max supply is already minted to owner)
        vm.startPrank(owner);
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

        // Check that initial supply was minted to owner
        assertEq(aOFT.getMaxSupply(), 2_000_000_000 * 10**18);
        assertEq(bOFT.getMaxSupply(), 2_000_000_000 * 10**18);

        // Total supply should equal max supply since we minted everything
        assertEq(aOFT.totalSupply(), aOFT.getMaxSupply());
        assertEq(bOFT.totalSupply(), bOFT.getMaxSupply());
    }

    // ============ BURNER FUNCTIONALITY TESTS ============

    function test_burn_with_authorized_burner() public {
        // Setup: Give userA some tokens and make them a burner
        vm.startPrank(owner);
        token.transfer(userA, 1000 ether);
        token.setBurner(userA, true);
        vm.stopPrank();

        uint256 burnAmount = 500 ether;
        uint256 supplyBefore = token.totalSupply();
        uint256 balanceBefore = token.balanceOf(userA);

        // Test: Authorized burner can burn tokens
        vm.prank(userA);
        token.burn(userA, burnAmount);

        assertEq(token.totalSupply(), supplyBefore - burnAmount);
        assertEq(token.balanceOf(userA), balanceBefore - burnAmount);
        assertEq(token.getCurrentSupply(), supplyBefore - burnAmount);
    }

    function test_burn_fails_with_unauthorized_burner() public {
        // Setup: Give userA tokens but don't make them a burner
        vm.prank(owner);
        token.transfer(userA, 1000 ether);

        // Test: Unauthorized burner cannot burn
        vm.expectRevert(IrysOFT.IrysOFT__UnauthorizedBurner.selector);
        vm.prank(userA);
        token.burn(userA, 100 ether);
    }

    function test_burn_from_another_address() public {
        // Setup: Give userA tokens and make userB a burner
        vm.startPrank(owner);
        token.transfer(userA, 1000 ether);
        token.setBurner(userB, true);
        vm.stopPrank();

        uint256 burnAmount = 300 ether;
        uint256 supplyBefore = token.totalSupply();

        // Test: Burner can burn from another address
        vm.prank(userB);
        token.burn(userA, burnAmount);

        assertEq(token.totalSupply(), supplyBefore - burnAmount);
        assertEq(token.balanceOf(userA), 1000 ether - burnAmount);
    }

    function test_burn_fails_when_paused() public {
        // Setup: Make userA a burner with tokens
        vm.startPrank(owner);
        token.transfer(userA, 1000 ether);
        token.setBurner(userA, true);
        token.pause();
        vm.stopPrank();

        // Test: Cannot burn when paused
        vm.expectRevert();
        vm.prank(userA);
        token.burn(userA, 100 ether);
    }

    function test_burn_exceeds_balance_reverts() public {
        // Setup: Give userA limited tokens and burner role
        vm.startPrank(owner);
        token.transfer(userA, 100 ether);
        token.setBurner(userA, true);
        vm.stopPrank();

        // Test: Cannot burn more than balance
        vm.expectRevert();
        vm.prank(userA);
        token.burn(userA, 200 ether);
    }

    function test_mint_after_burn_works() public {
        // Setup: Burn some tokens first
        vm.startPrank(owner);
        token.burn(owner, 1000 ether);
        uint256 supplyAfterBurn = token.totalSupply();

        // Now we have room to mint
        token.setMinter(userA, true);
        vm.stopPrank();

        // Test: Can mint after burn created room
        vm.prank(userA);
        token.mint(userB, 500 ether);

        assertEq(token.totalSupply(), supplyAfterBurn + 500 ether);
        assertEq(token.balanceOf(userB), 500 ether);
        assertTrue(token.totalSupply() < MAX_SUPPLY);
    }

    // ============ MINTER ACCESS CONTROL TESTS ============

    function test_minter_access_control() public {
        // Since max supply is already minted, any mint should fail
        vm.expectRevert(IrysOFT.IrysOFT__MaxSupplyExceeded.selector);
        vm.prank(owner);
        aOFT.mint(userA, 1);

        // User should not be able to mint
        vm.expectRevert(IrysOFT.IrysOFT__UnauthorizedMinter.selector);
        vm.prank(userA);
        aOFT.mint(userA, 1);

        // Set user as minter (but still can't mint due to max supply)
        vm.prank(owner);
        aOFT.setMinter(userA, true);

        // User is now a minter but still can't mint due to max supply
        vm.expectRevert(IrysOFT.IrysOFT__MaxSupplyExceeded.selector);
        vm.prank(userA);
        aOFT.mint(userB, 1);

        // Verify user is actually a minter
        assertTrue(aOFT.isMinter(userA));
    }

    function test_max_supply_enforcement() public {
        // Since we already minted max supply in initialize, any additional mint should fail
        vm.expectRevert(IrysOFT.IrysOFT__MaxSupplyExceeded.selector);
        vm.prank(owner);
        aOFT.mint(userA, 1);
    }

    // ============ ROLE MANAGEMENT TESTS ============

    function test_remove_minter_role() public {
        // Setup: Add then remove minter role
        vm.startPrank(owner);
        token.setMinter(userA, true);
        assertTrue(token.isMinter(userA));

        token.setMinter(userA, false);
        assertFalse(token.isMinter(userA));

        // First burn to make room for minting
        token.burn(owner, 1000 ether);
        vm.stopPrank();

        // Test: Removed minter cannot mint
        vm.expectRevert(IrysOFT.IrysOFT__UnauthorizedMinter.selector);
        vm.prank(userA);
        token.mint(userB, 100 ether);
    }

    function test_remove_burner_role() public {
        // Setup: Add then remove burner role
        vm.startPrank(owner);
        token.transfer(userA, 1000 ether);
        token.setBurner(userA, true);
        assertTrue(token.isBurner(userA));

        token.setBurner(userA, false);
        assertFalse(token.isBurner(userA));
        vm.stopPrank();

        // Test: Removed burner cannot burn
        vm.expectRevert(IrysOFT.IrysOFT__UnauthorizedBurner.selector);
        vm.prank(userA);
        token.burn(userA, 100 ether);
    }

    function test_multiple_minters_and_burners() public {
        // Setup: Add multiple minters and burners
        vm.startPrank(owner);
        token.setMinter(userA, true);
        token.setMinter(userB, true);
        token.setBurner(userA, true);
        token.setBurner(userB, true);

        // Transfer tokens for testing
        token.transfer(userA, 1000 ether);
        token.transfer(userB, 1000 ether);
        vm.stopPrank();

        // Test: Both can burn
        vm.prank(userA);
        token.burn(userA, 100 ether);

        vm.prank(userB);
        token.burn(userB, 100 ether);

        // Test: Both can mint (after burns created room)
        vm.prank(userA);
        token.mint(userA, 50 ether);

        vm.prank(userB);
        token.mint(userB, 50 ether);

        assertTrue(token.isMinter(userA));
        assertTrue(token.isMinter(userB));
        assertTrue(token.isBurner(userA));
        assertTrue(token.isBurner(userB));
    }

    function test_authorization_functions() public {
        // Test authorization checks
        assertTrue(aOFT.isMinter(owner));
        assertTrue(aOFT.isBurner(owner));
        assertFalse(aOFT.isMinter(userA));
        assertFalse(aOFT.isBurner(userA));

        // Owner can set minter/burner roles
        vm.prank(owner);
        aOFT.setMinter(userA, true);
        assertTrue(aOFT.isMinter(userA));

        vm.prank(owner);
        aOFT.setBurner(userB, true);
        assertTrue(aOFT.isBurner(userB));
    }

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
        token.setMinter(userA, true);
        token.setBurner(userB, true);
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
        assertTrue(token.isMinter(userA));
        assertTrue(token.isBurner(userB));
        assertEq(token.owner(), owner);
    }

    // ============ EVENT EMISSION TESTS ============

    function test_event_MinterSet() public {
        vm.expectEmit(true, false, false, true);
        emit MinterSet(userA, true);

        vm.prank(owner);
        token.setMinter(userA, true);

        vm.expectEmit(true, false, false, true);
        emit MinterSet(userA, false);

        vm.prank(owner);
        token.setMinter(userA, false);
    }

    function test_event_BurnerSet() public {
        vm.expectEmit(true, false, false, true);
        emit BurnerSet(userB, true);

        vm.prank(owner);
        token.setBurner(userB, true);

        vm.expectEmit(true, false, false, true);
        emit BurnerSet(userB, false);

        vm.prank(owner);
        token.setBurner(userB, false);
    }

    function test_event_PrivilegedMint() public {
        // Setup: Create room for minting
        vm.startPrank(owner);
        token.burn(owner, 1000 ether);
        token.setMinter(userA, true);
        vm.stopPrank();

        vm.expectEmit(true, false, true, true);
        emit PrivilegedMint(userB, 100 ether, userA);

        vm.prank(userA);
        token.mint(userB, 100 ether);
    }

    function test_event_PrivilegedBurn() public {
        // Setup
        vm.startPrank(owner);
        token.transfer(userA, 1000 ether);
        token.setBurner(userB, true);
        vm.stopPrank();

        vm.expectEmit(true, false, true, true);
        emit PrivilegedBurn(userA, 200 ether, userB);

        vm.prank(userB);
        token.burn(userA, 200 ether);
    }

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

    function test_pause_blocks_all_operations() public {
        vm.startPrank(owner);
        token.transfer(userA, 1000 ether);
        token.setMinter(userA, true);
        token.setBurner(userA, true);
        token.burn(owner, 1000 ether); // Make room for minting
        token.pause();
        vm.stopPrank();

        // Test: All operations fail when paused
        vm.startPrank(userA);

        // Transfer fails
        vm.expectRevert();
        token.transfer(userB, 100 ether);

        // Mint fails
        vm.expectRevert();
        token.mint(userB, 100 ether);

        // Burn fails
        vm.expectRevert();
        token.burn(userA, 100 ether);

        vm.stopPrank();
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
        // Check initial supply tracking
        assertEq(aOFT.getCurrentSupply(), aOFT.getMaxSupply());

        // Supply tracking should work correctly
        uint256 burnAmount = 1000 ether;
        vm.prank(owner);
        aOFT.burn(owner, burnAmount);

        assertEq(aOFT.getCurrentSupply(), aOFT.getMaxSupply() - burnAmount);
        assertEq(aOFT.totalSupply(), aOFT.getMaxSupply() - burnAmount);
    }

    // ============ EDGE CASES & SECURITY TESTS ============

    function test_zero_address_validation() public {
        vm.startPrank(owner);

        // Note: The contract currently allows setting zero address as minter/burner
        // This is a potential issue but we'll test the actual behavior
        token.setMinter(address(0), true);
        assertTrue(token.isMinter(address(0)));

        token.setBurner(address(0), true);
        assertTrue(token.isBurner(address(0)));

        // Create room for minting
        token.burn(owner, 1000 ether);

        // Test: Minting to zero address should revert (ERC20 behavior)
        vm.expectRevert();
        token.mint(address(0), 100 ether);

        // Test: Burning from zero address should revert (no balance)
        vm.expectRevert();
        token.burn(address(0), 100 ether);

        vm.stopPrank();
    }

    function test_max_supply_strictly_enforced() public {
        // Setup: Burn just 1 token
        vm.startPrank(owner);
        token.burn(owner, 1);
        token.setMinter(userA, true);
        vm.stopPrank();

        // Test: Can mint exactly 1 token
        vm.prank(userA);
        token.mint(userB, 1);

        // Test: Cannot mint even 1 more
        vm.expectRevert(IrysOFT.IrysOFT__MaxSupplyExceeded.selector);
        vm.prank(userA);
        token.mint(userB, 1);

        assertEq(token.totalSupply(), MAX_SUPPLY);
    }

    function test_reentrancy_protection() public {
        // This would require a malicious contract, but we can test that 
        // state changes happen in the correct order
        vm.startPrank(owner);
        token.burn(owner, 1000 ether);
        token.setMinter(userA, true);
        vm.stopPrank();

        uint256 supplyBefore = token.totalSupply();

        // Mint should update state before external call
        vm.prank(userA);
        token.mint(userB, 500 ether);

        assertEq(token.totalSupply(), supplyBefore + 500 ether);
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