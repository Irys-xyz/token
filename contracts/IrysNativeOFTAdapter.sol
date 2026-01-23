// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { OFTCoreUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTCoreUpgradeable.sol";
import { MessagingFee, MessagingReceipt, OFTReceipt, SendParam, OFTLimit, OFTFeeDetail } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

/// @title IrysNativeOFTAdapter
/// @notice Adapter for bridging native L1 Irys tokens to remote chains via LayerZero
/// @dev Escrows native tokens when sending to remote chains, releases when receiving from remote chains.
///      This contract acts as the canonical token reservoir - all tokens on remote OFT chains
///      are backed by native tokens locked in this adapter.
/// @custom:oz-upgrades-unsafe-allow constructor
contract IrysNativeOFTAdapter is
    Initializable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    OFTCoreUpgradeable
{
    // ============ Constants ============

    /// @notice Native token decimals (18 for EVM chains)
    uint8 public constant NATIVE_DECIMALS = 18;

    // ============ State Variables ============

    /// @notice Address of the pending owner for two-step ownership transfer
    address private _pendingOwner;

    /// @notice Total native tokens escrowed (authoritative locked balance)
    /// @dev Use this instead of address(this).balance to avoid force-send attacks
    uint256 public totalEscrowed;

    /// @notice Claimable credits for recipients whose native transfer failed
    mapping(address => uint256) public claimable;

    /// @notice Total amount currently claimable across all recipients
    uint256 public totalClaimable;

    /// @notice Timestamp after which emergency withdrawal is allowed (0 = not initiated)
    /// @dev Set via initiateEmergencyWithdrawal(), cleared via cancelEmergencyWithdrawal()
    uint256 public emergencyUnlockTime;

    /// @notice Reserved storage gap for future upgrades
    /// @dev This allows adding new state variables without corrupting storage layout
    uint256[49] private __gap;

    // ============ Errors ============

    /// @notice Thrown when a zero address is provided where not allowed
    error IrysNativeOFTAdapter__ZeroAddress();

    /// @notice Thrown when attempting to renounce ownership (disabled)
    error IrysNativeOFTAdapter__RenounceOwnershipDisabled();

    /// @notice Thrown when acceptOwnership is called by non-pending owner
    error IrysNativeOFTAdapter__NotPendingOwner();

    /// @notice Thrown when upgrade target is not a valid contract
    error IrysNativeOFTAdapter__InvalidImplementation();

    /// @notice Thrown when msg.value doesn't match required amount (fee + bridged amount)
    error IrysNativeOFTAdapter__IncorrectMessageValue(uint256 provided, uint256 required);

    /// @notice Thrown when claim amount is zero
    error IrysNativeOFTAdapter__NothingToClaim();

    /// @notice Thrown when native transfer fails during claim
    error IrysNativeOFTAdapter__ClaimTransferFailed();

    /// @notice Thrown when seedEscrow is called with zero value
    error IrysNativeOFTAdapter__ZeroSeedAmount();

    /// @notice Thrown when _credit attempts to release more than escrowed
    error IrysNativeOFTAdapter__InsufficientEscrow(uint256 escrowed, uint256 requested);

    /// @notice Thrown when sweepSurplus requests more than available surplus
    error IrysNativeOFTAdapter__InsufficientSurplus(uint256 available, uint256 requested);

    /// @notice Thrown when sweepSurplus transfer fails
    error IrysNativeOFTAdapter__SweepFailed();

    /// @notice Thrown when emergency withdrawal is attempted before timelock expires
    error IrysNativeOFTAdapter__EmergencyNotReady(uint256 currentTime, uint256 unlockTime);

    /// @notice Thrown when emergency withdrawal is not active
    error IrysNativeOFTAdapter__EmergencyNotActive();

    /// @notice Thrown when emergency withdrawal transfer fails
    error IrysNativeOFTAdapter__EmergencyWithdrawFailed();

    // ============ Events ============

    /// @notice Emitted when ownership transfer is initiated
    /// @param previousOwner The current owner initiating the transfer
    /// @param newOwner The address that can accept ownership
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when a pending ownership transfer is canceled
    event OwnershipTransferCanceled();

    /// @notice Emitted when a credit transfer succeeds
    /// @param recipient The address that received the funds
    /// @param amount The amount credited
    /// @param srcEid The source endpoint ID
    event CreditSucceeded(address indexed recipient, uint256 amount, uint32 srcEid);

    /// @notice Emitted when a credit transfer fails and is queued for later claim
    /// @param recipient The intended recipient
    /// @param amount The amount queued
    /// @param srcEid The source endpoint ID
    event CreditQueued(address indexed recipient, uint256 amount, uint32 srcEid);

    /// @notice Emitted when a queued credit is claimed (claim or claimFor)
    /// @param recipient The address that received the claimed funds
    /// @param amount The amount claimed
    event Claimed(address indexed recipient, uint256 amount);

    /// @notice Emitted when a queued credit is claimed and redirected (claimTo)
    /// @param claimant The address whose claimable balance was consumed
    /// @param to The address that received the claimed funds
    /// @param amount The amount claimed
    event ClaimedTo(address indexed claimant, address indexed to, uint256 amount);

    /// @notice Emitted when escrow is seeded with native tokens
    /// @param sender The address that sent the tokens
    /// @param amount The amount of tokens seeded
    event EscrowSeeded(address indexed sender, uint256 amount);

    /// @notice Emitted when surplus funds are swept
    /// @param to The recipient of the surplus
    /// @param amount The amount swept
    event SurplusSwept(address indexed to, uint256 amount);

    /// @notice Emitted when emergency withdrawal is initiated
    /// @param initiator The owner who initiated the emergency
    /// @param unlockTime The timestamp when withdrawal becomes available
    event EmergencyWithdrawalInitiated(address indexed initiator, uint256 unlockTime);

    /// @notice Emitted when emergency withdrawal is canceled
    /// @param canceler The owner who canceled the emergency
    event EmergencyWithdrawalCanceled(address indexed canceler);

    /// @notice Emitted when emergency withdrawal is executed
    /// @param to The recipient of the withdrawn funds
    /// @param amount The total amount withdrawn
    event EmergencyWithdrawalExecuted(address indexed to, uint256 amount);

    // ============ Constructor ============

    /// @notice Constructor sets immutable variables (decimals and LZ endpoint)
    /// @param _lzEndpoint The LayerZero endpoint address on this chain
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _lzEndpoint) OFTCoreUpgradeable(NATIVE_DECIMALS, _lzEndpoint) {
        if (_lzEndpoint == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();
        _disableInitializers();
    }

    // ============ Initialization ============

    /// @notice Initializes the adapter with the owner/delegate address
    /// @param _delegate The address that will own the contract and configure OApp settings
    /// @dev Should be a Gnosis Safe or other multisig for production deployments
    function initialize(address _delegate) public initializer {
        if (_delegate == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();

        __Ownable_init(_delegate);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __OFTCore_init(_delegate);
    }

    // ============ Receive ============

    /// @notice Allows the contract to receive native tokens
    /// @dev Required for receiving bridged tokens back from remote chains
    receive() external payable {}

    // ============ Token Interface ============

    /// @notice Returns the address of the token (address(0) for native)
    /// @return The zero address indicating native token
    function token() public pure returns (address) {
        return address(0);
    }

    /// @notice Indicates whether approval is required to send
    /// @return false since native tokens don't require approval
    function approvalRequired() external pure returns (bool) {
        return false;
    }

    // ============ Send Override ============

    /// @notice Executes the send operation while ensuring correct native amount is sent
    /// @param _sendParam The parameters for the send operation
    /// @param _fee The calculated fee for the send() operation
    /// @param _refundAddress The address to receive any excess funds
    /// @return msgReceipt The receipt for the send operation
    /// @return oftReceipt The OFT receipt information
    /// @dev msg.value must equal exactly: _fee.nativeFee + amountSentLD (computed via _debitView)
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable virtual override nonReentrant returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
        // Fail fast if paused (saves gas vs discovering in _debit)
        if (paused()) revert EnforcedPause();

        // Compute exact debited amount
        (uint256 amountSentLD, uint256 amountReceivedLD) = _debitView(
            _sendParam.amountLD,
            _sendParam.minAmountLD,
            _sendParam.dstEid
        );

        uint256 requiredMsgValue = _fee.nativeFee + amountSentLD;
        if (msg.value != requiredMsgValue) {
            revert IrysNativeOFTAdapter__IncorrectMessageValue(msg.value, requiredMsgValue);
        }

        // Debit native tokens (records escrow, tokens already in contract via msg.value)
        _debit(msg.sender, _sendParam.amountLD, _sendParam.minAmountLD, _sendParam.dstEid);

        // Build the message and options
        (bytes memory message, bytes memory options) = _buildMsgAndOptions(_sendParam, amountReceivedLD);

        // Send via LayerZero
        msgReceipt = _lzSend(_sendParam.dstEid, message, options, _fee, _refundAddress);

        // Formulate the OFT receipt
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);

        emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }

    // ============ Quote Override ============

    /// @notice Provides the fee breakdown and settings for an OFT operation
    /// @param _sendParam The parameters for the send operation
    /// @return oftLimit The OFT limit information
    /// @return oftFeeDetails The details of OFT fees
    /// @return oftReceipt The OFT receipt information
    function quoteOFT(
        SendParam calldata _sendParam
    )
        external
        view
        virtual
        override
        returns (OFTLimit memory oftLimit, OFTFeeDetail[] memory oftFeeDetails, OFTReceipt memory oftReceipt)
    {
        oftLimit = OFTLimit(0, type(uint256).max);
        oftFeeDetails = new OFTFeeDetail[](0);

        (uint256 amountSentLD, uint256 amountReceivedLD) = _debitView(
            _sendParam.amountLD,
            _sendParam.minAmountLD,
            _sendParam.dstEid
        );
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);
    }

    // ============ Pausable ============

    /// @notice Pauses all bridge operations (lock/unlock)
    /// @dev Only callable by owner. Use in emergencies to halt bridging.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses bridge operations
    /// @dev Only callable by owner
    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Debit/Credit Overrides ============

    /// @notice Locks native tokens when bridging to a remote chain
    /// @dev Native tokens are already "locked" via msg.value in the overridden send()
    /// @param _amountLD The amount of tokens in local decimals
    /// @param _minAmountLD The minimum amount to send (slippage protection)
    /// @param _dstEid The destination endpoint ID
    /// @return amountSentLD The actual amount sent in local decimals
    /// @return amountReceivedLD The amount that will be received on the remote chain
    function _debit(
        address,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal virtual override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);

        // Native tokens are already in the contract via msg.value
        // Update authoritative escrow accounting
        totalEscrowed += amountSentLD;
    }

    /// @notice Unlocks native tokens when receiving from a remote chain
    /// @dev If native transfer fails, queues the credit for later claim instead of reverting
    /// @param _to The address to credit tokens to
    /// @param _amountLD The amount of tokens in local decimals
    /// @param _srcEid The source endpoint ID
    /// @return amountReceivedLD The actual amount received in local decimals
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 _srcEid
    ) internal virtual override returns (uint256 amountReceivedLD) {
        if (paused()) revert EnforcedPause();
        if (_to == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();

        // Guard against underflow with explicit check
        if (totalEscrowed < _amountLD) {
            revert IrysNativeOFTAdapter__InsufficientEscrow(totalEscrowed, _amountLD);
        }

        // Update escrow accounting (safe after bound check)
        unchecked {
            totalEscrowed -= _amountLD;
        }

        // Attempt native transfer
        (bool success,) = payable(_to).call{value: _amountLD}("");

        if (success) {
            emit CreditSucceeded(_to, _amountLD, _srcEid);
        } else {
            // Queue for later claim instead of reverting
            claimable[_to] += _amountLD;
            totalClaimable += _amountLD;
            emit CreditQueued(_to, _amountLD, _srcEid);
        }

        return _amountLD;
    }

    /// @notice Overridden to be empty as fee validation is done in send()
    /// @param _nativeFee The native fee to be paid
    /// @return nativeFee The amount of native currency paid
    function _payNative(uint256 _nativeFee) internal pure override returns (uint256 nativeFee) {
        return _nativeFee;
    }

    // ============ Claim ============

    /// @notice Internal function to execute claim logic
    /// @param _from The address whose claimable balance to consume
    /// @param _to The address to send the funds to
    /// @return amount The amount that was claimed
    function _executeClaim(address _from, address payable _to) internal returns (uint256 amount) {
        amount = claimable[_from];
        if (amount == 0) revert IrysNativeOFTAdapter__NothingToClaim();

        claimable[_from] = 0;
        totalClaimable -= amount;

        (bool success,) = _to.call{value: amount}("");
        if (!success) revert IrysNativeOFTAdapter__ClaimTransferFailed();
    }

    /// @notice Allows recipients to claim credits that failed during initial transfer
    /// @dev Uses nonReentrant to prevent reentrancy attacks on native transfer
    function claim() external nonReentrant {
        uint256 amount = _executeClaim(msg.sender, payable(msg.sender));
        emit Claimed(msg.sender, amount);
    }

    /// @notice Allows claiming on behalf of another address (sends to that address)
    /// @param _recipient The address to claim for and send to
    /// @dev Uses nonReentrant to prevent reentrancy attacks on native transfer
    function claimFor(address _recipient) external nonReentrant {
        uint256 amount = _executeClaim(_recipient, payable(_recipient));
        emit Claimed(_recipient, amount);
    }

    /// @notice Allows caller to claim their credits and redirect to a different address
    /// @param _to The address to send the claimed funds to
    /// @dev Useful when original recipient is a contract that cannot receive native tokens
    function claimTo(address payable _to) external nonReentrant {
        if (_to == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();
        uint256 amount = _executeClaim(msg.sender, _to);
        emit ClaimedTo(msg.sender, _to, amount);
    }

    // ============ Escrow Management ============

    /// @notice Seeds the escrow with native tokens to back existing remote OFT supply
    /// @dev Only callable by owner. Used to initialize escrow for pre-existing ERC20 tokens
    ///      on remote chains that need to be bridgeable back to this chain.
    ///
    ///      IMPORTANT: To pre-fund backing for remote supply, you MUST call this function.
    ///      Do NOT fund via plain transfer to receive() - that will become sweepable surplus,
    ///      not escrow. Only seedEscrow() increases totalEscrowed.
    function seedEscrow() external payable onlyOwner {
        if (msg.value == 0) revert IrysNativeOFTAdapter__ZeroSeedAmount();
        totalEscrowed += msg.value;
        emit EscrowSeeded(msg.sender, msg.value);
    }

    /// @notice Returns the surplus balance (funds above obligations)
    /// @dev Surplus = balance - (escrowed + claimable). Can accumulate from force-sends.
    /// @return The amount of surplus funds available for sweeping
    function surplusBalance() public view returns (uint256) {
        uint256 obligations = totalEscrowed + totalClaimable;
        uint256 bal = address(this).balance;
        if (bal <= obligations) return 0;
        return bal - obligations;
    }

    /// @notice Sweeps surplus funds to the owner
    /// @dev Only callable by owner. Only sweeps funds above obligations (escrow + claimable).
    /// @param _amount The amount to sweep (must be <= surplusBalance())
    function sweepSurplus(uint256 _amount) external onlyOwner nonReentrant {
        uint256 surplus = surplusBalance();
        if (_amount > surplus) {
            revert IrysNativeOFTAdapter__InsufficientSurplus(surplus, _amount);
        }

        address payable recipient = payable(owner());
        (bool success,) = recipient.call{value: _amount}("");
        if (!success) revert IrysNativeOFTAdapter__SweepFailed();

        emit SurplusSwept(recipient, _amount);
    }

    // ============ View Functions ============

    /// @notice Returns the total amount of native tokens locked in the adapter
    /// @dev This is the authoritative escrow balance, not address(this).balance
    /// @return The total escrowed native tokens
    function lockedBalance() external view returns (uint256) {
        return totalEscrowed;
    }

    /// @notice Returns the total obligations (escrowed + claimable)
    /// @dev Useful for monitoring: backingBalance() should always >= totalObligations()
    /// @return The sum of totalEscrowed and totalClaimable
    function totalObligations() public view returns (uint256) {
        return totalEscrowed + totalClaimable;
    }

    /// @notice Returns the contract's native token balance
    /// @dev This is the actual balance, which should always be >= totalObligations()
    /// @return The contract's native balance
    function backingBalance() public view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Returns whether the contract is fully backed (balance >= obligations)
    /// @dev Useful for monitoring dashboards and alerts. Should always return true.
    /// @return True if backing balance covers all obligations
    function isFullyBacked() external view returns (bool) {
        return address(this).balance >= totalEscrowed + totalClaimable;
    }

    // ============ Two-Step Ownership ============

    /// @notice Returns the address of the pending owner
    /// @return The pending owner address, or zero if no transfer is pending
    function pendingOwner() public view virtual returns (address) {
        return _pendingOwner;
    }

    /// @notice Initiates ownership transfer to a new address
    /// @dev The new owner must call acceptOwnership() to complete the transfer.
    ///      Replaces any existing pending transfer.
    /// @param newOwner The address to transfer ownership to
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        if (newOwner == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    /// @notice Completes the ownership transfer
    /// @dev Can only be called by the pending owner
    function acceptOwnership() public virtual {
        if (msg.sender != _pendingOwner) revert IrysNativeOFTAdapter__NotPendingOwner();
        delete _pendingOwner;
        _transferOwnership(msg.sender);
    }

    /// @notice Cancels a pending ownership transfer
    /// @dev Only callable by the current owner
    function cancelOwnershipTransfer() public virtual onlyOwner {
        delete _pendingOwner;
        emit OwnershipTransferCanceled();
    }

    /// @notice Renouncing ownership is disabled to prevent accidental lockout
    /// @dev Always reverts. Ownership must be transferred, not renounced.
    function renounceOwnership() public override onlyOwner {
        revert IrysNativeOFTAdapter__RenounceOwnershipDisabled();
    }

    // ============ Upgrade ============

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Validates that the new implementation is a non-zero address with code
    /// @param newImplementation The address of the new implementation contract
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (newImplementation == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();
        if (newImplementation.code.length == 0) revert IrysNativeOFTAdapter__InvalidImplementation();
    }

    // ============ Emergency Withdrawal ============

    /// @notice Duration of the emergency withdrawal timelock (7 days)
    uint256 public constant EMERGENCY_TIMELOCK_DURATION = 7 days;

    /// @notice Initiates emergency withdrawal with a 7-day timelock
    /// @dev Pauses all bridging operations immediately. Can be canceled before timelock expires.
    ///      Use only when LayerZero endpoint is compromised or permanently unavailable.
    function initiateEmergencyWithdrawal() external onlyOwner {
        emergencyUnlockTime = block.timestamp + EMERGENCY_TIMELOCK_DURATION;
        _pause();
        emit EmergencyWithdrawalInitiated(msg.sender, emergencyUnlockTime);
    }

    /// @notice Cancels a pending emergency withdrawal and resumes normal operations
    /// @dev Unpauses bridging operations. Can only be called while emergency is pending.
    function cancelEmergencyWithdrawal() external onlyOwner {
        if (emergencyUnlockTime == 0) revert IrysNativeOFTAdapter__EmergencyNotActive();
        delete emergencyUnlockTime;
        _unpause();
        emit EmergencyWithdrawalCanceled(msg.sender);
    }

    /// @notice Executes emergency withdrawal after timelock expires
    /// @dev Withdraws entire contract balance to specified address. Resets all accounting.
    /// @param _to The address to receive all funds
    function emergencyWithdraw(address payable _to) external onlyOwner nonReentrant {
        if (_to == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();
        if (emergencyUnlockTime == 0) revert IrysNativeOFTAdapter__EmergencyNotActive();
        if (block.timestamp < emergencyUnlockTime) {
            revert IrysNativeOFTAdapter__EmergencyNotReady(block.timestamp, emergencyUnlockTime);
        }

        uint256 amount = address(this).balance;

        // Reset all accounting since we're withdrawing everything
        totalEscrowed = 0;
        totalClaimable = 0;
        delete emergencyUnlockTime;

        (bool success,) = _to.call{value: amount}("");
        if (!success) revert IrysNativeOFTAdapter__EmergencyWithdrawFailed();

        emit EmergencyWithdrawalExecuted(_to, amount);
    }

    /// @notice Returns whether emergency withdrawal is currently pending
    /// @return True if emergency has been initiated but not yet executed or canceled
    function isEmergencyActive() external view returns (bool) {
        return emergencyUnlockTime != 0;
    }
}
