// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { OFTCoreUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTCoreUpgradeable.sol";
import { MessagingFee, MessagingReceipt, OFTReceipt, SendParam, OFTLimit, OFTFeeDetail } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";

/// @title IrysNativeOFTAdapterTestable
/// @notice Test version of IrysNativeOFTAdapter that allows direct initialization (no proxy required)
/// @dev For testing purposes only - does not disable initializers in constructor
contract IrysNativeOFTAdapterTestable is
    Initializable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    OFTCoreUpgradeable
{
    // ============ Constants ============

    uint8 public constant NATIVE_DECIMALS = 18;

    // ============ State Variables ============

    address private _pendingOwner;
    uint256 public totalEscrowed;
    mapping(address => uint256) public claimable;
    uint256 public totalClaimable;
    uint256 public emergencyUnlockTime;

    uint256[49] private __gap;

    // ============ Errors ============

    error IrysNativeOFTAdapter__ZeroAddress();
    error IrysNativeOFTAdapter__RenounceOwnershipDisabled();
    error IrysNativeOFTAdapter__NotPendingOwner();
    error IrysNativeOFTAdapter__InvalidImplementation();
    error IrysNativeOFTAdapter__IncorrectMessageValue(uint256 provided, uint256 required);
    error IrysNativeOFTAdapter__NothingToClaim();
    error IrysNativeOFTAdapter__ClaimTransferFailed();
    error IrysNativeOFTAdapter__ZeroSeedAmount();
    error IrysNativeOFTAdapter__InsufficientEscrow(uint256 escrowed, uint256 requested);
    error IrysNativeOFTAdapter__InsufficientSurplus(uint256 available, uint256 requested);
    error IrysNativeOFTAdapter__SweepFailed();
    error IrysNativeOFTAdapter__EmergencyNotReady(uint256 currentTime, uint256 unlockTime);
    error IrysNativeOFTAdapter__EmergencyNotActive();
    error IrysNativeOFTAdapter__EmergencyWithdrawFailed();

    // ============ Events ============

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferCanceled();
    event CreditSucceeded(address indexed recipient, uint256 amount, uint32 srcEid);
    event CreditQueued(address indexed recipient, uint256 amount, uint32 srcEid);
    event Claimed(address indexed recipient, uint256 amount);
    event ClaimedTo(address indexed claimant, address indexed to, uint256 amount);
    event EscrowSeeded(address indexed sender, uint256 amount);
    event SurplusSwept(address indexed to, uint256 amount);
    event EmergencyWithdrawalInitiated(address indexed initiator, uint256 unlockTime);
    event EmergencyWithdrawalCanceled(address indexed canceler);
    event EmergencyWithdrawalExecuted(address indexed to, uint256 amount);

    // ============ Constructor ============

    /// @notice Constructor for testable version - does NOT disable initializers
    /// @param _lzEndpoint The LayerZero endpoint address
    constructor(address _lzEndpoint) OFTCoreUpgradeable(NATIVE_DECIMALS, _lzEndpoint) {
        if (_lzEndpoint == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();
        // Intentionally NOT calling _disableInitializers() for testing
    }

    // ============ Initialization ============

    function initialize(address _delegate) public initializer {
        if (_delegate == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();

        __Ownable_init(_delegate);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __OFTCore_init(_delegate);
    }

    // ============ Receive ============

    receive() external payable {}

    // ============ Token Interface ============

    function token() public pure returns (address) {
        return address(0);
    }

    function approvalRequired() external pure returns (bool) {
        return false;
    }

    // ============ Send Override ============

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable virtual override nonReentrant returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
        if (paused()) revert EnforcedPause();

        (uint256 amountSentLD, uint256 amountReceivedLD) = _debitView(
            _sendParam.amountLD,
            _sendParam.minAmountLD,
            _sendParam.dstEid
        );

        uint256 requiredMsgValue = _fee.nativeFee + amountSentLD;
        if (msg.value != requiredMsgValue) {
            revert IrysNativeOFTAdapter__IncorrectMessageValue(msg.value, requiredMsgValue);
        }

        _debit(msg.sender, _sendParam.amountLD, _sendParam.minAmountLD, _sendParam.dstEid);

        (bytes memory message, bytes memory options) = _buildMsgAndOptions(_sendParam, amountReceivedLD);

        msgReceipt = _lzSend(_sendParam.dstEid, message, options, _fee, _refundAddress);
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);

        emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }

    // ============ Quote Override ============

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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ============ Debit/Credit Overrides ============

    function _debit(
        address,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    ) internal virtual override returns (uint256 amountSentLD, uint256 amountReceivedLD) {
        (amountSentLD, amountReceivedLD) = _debitView(_amountLD, _minAmountLD, _dstEid);
        totalEscrowed += amountSentLD;
    }

    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 _srcEid
    ) internal virtual override returns (uint256 amountReceivedLD) {
        if (paused()) revert EnforcedPause();
        if (_to == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();

        if (totalEscrowed < _amountLD) {
            revert IrysNativeOFTAdapter__InsufficientEscrow(totalEscrowed, _amountLD);
        }

        unchecked {
            totalEscrowed -= _amountLD;
        }

        (bool success,) = payable(_to).call{value: _amountLD}("");

        if (success) {
            emit CreditSucceeded(_to, _amountLD, _srcEid);
        } else {
            claimable[_to] += _amountLD;
            totalClaimable += _amountLD;
            emit CreditQueued(_to, _amountLD, _srcEid);
        }

        return _amountLD;
    }

    function _payNative(uint256 _nativeFee) internal pure override returns (uint256 nativeFee) {
        return _nativeFee;
    }

    // ============ Claim ============

    function _executeClaim(address _from, address payable _to) internal returns (uint256 amount) {
        amount = claimable[_from];
        if (amount == 0) revert IrysNativeOFTAdapter__NothingToClaim();

        claimable[_from] = 0;
        totalClaimable -= amount;

        (bool success,) = _to.call{value: amount}("");
        if (!success) revert IrysNativeOFTAdapter__ClaimTransferFailed();
    }

    function claim() external nonReentrant {
        uint256 amount = _executeClaim(msg.sender, payable(msg.sender));
        emit Claimed(msg.sender, amount);
    }

    function claimFor(address _recipient) external nonReentrant {
        uint256 amount = _executeClaim(_recipient, payable(_recipient));
        emit Claimed(_recipient, amount);
    }

    function claimTo(address payable _to) external nonReentrant {
        if (_to == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();
        uint256 amount = _executeClaim(msg.sender, _to);
        emit ClaimedTo(msg.sender, _to, amount);
    }

    // ============ Escrow Management ============

    function seedEscrow() external payable onlyOwner {
        if (msg.value == 0) revert IrysNativeOFTAdapter__ZeroSeedAmount();
        totalEscrowed += msg.value;
        emit EscrowSeeded(msg.sender, msg.value);
    }

    function surplusBalance() public view returns (uint256) {
        uint256 obligations = totalEscrowed + totalClaimable;
        uint256 bal = address(this).balance;
        if (bal <= obligations) return 0;
        return bal - obligations;
    }

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

    function lockedBalance() external view returns (uint256) {
        return totalEscrowed;
    }

    function totalObligations() public view returns (uint256) {
        return totalEscrowed + totalClaimable;
    }

    function backingBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function isFullyBacked() external view returns (bool) {
        return address(this).balance >= totalEscrowed + totalClaimable;
    }

    // ============ Two-Step Ownership ============

    function pendingOwner() public view virtual returns (address) {
        return _pendingOwner;
    }

    function transferOwnership(address newOwner) public virtual override onlyOwner {
        if (newOwner == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    function acceptOwnership() public virtual {
        if (msg.sender != _pendingOwner) revert IrysNativeOFTAdapter__NotPendingOwner();
        delete _pendingOwner;
        _transferOwnership(msg.sender);
    }

    function cancelOwnershipTransfer() public virtual onlyOwner {
        delete _pendingOwner;
        emit OwnershipTransferCanceled();
    }

    function renounceOwnership() public override onlyOwner {
        revert IrysNativeOFTAdapter__RenounceOwnershipDisabled();
    }

    // ============ Upgrade ============

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        if (newImplementation == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();
        if (newImplementation.code.length == 0) revert IrysNativeOFTAdapter__InvalidImplementation();
    }

    // ============ Emergency Withdrawal ============

    uint256 public constant EMERGENCY_TIMELOCK_DURATION = 7 days;

    function initiateEmergencyWithdrawal() external onlyOwner {
        emergencyUnlockTime = block.timestamp + EMERGENCY_TIMELOCK_DURATION;
        _pause();
        emit EmergencyWithdrawalInitiated(msg.sender, emergencyUnlockTime);
    }

    function cancelEmergencyWithdrawal() external onlyOwner {
        if (emergencyUnlockTime == 0) revert IrysNativeOFTAdapter__EmergencyNotActive();
        delete emergencyUnlockTime;
        _unpause();
        emit EmergencyWithdrawalCanceled(msg.sender);
    }

    function emergencyWithdraw(address payable _to) external onlyOwner nonReentrant {
        if (_to == address(0)) revert IrysNativeOFTAdapter__ZeroAddress();
        if (emergencyUnlockTime == 0) revert IrysNativeOFTAdapter__EmergencyNotActive();
        if (block.timestamp < emergencyUnlockTime) {
            revert IrysNativeOFTAdapter__EmergencyNotReady(block.timestamp, emergencyUnlockTime);
        }

        uint256 amount = address(this).balance;

        totalEscrowed = 0;
        totalClaimable = 0;
        delete emergencyUnlockTime;

        (bool success,) = _to.call{value: amount}("");
        if (!success) revert IrysNativeOFTAdapter__EmergencyWithdrawFailed();

        emit EmergencyWithdrawalExecuted(_to, amount);
    }

    function isEmergencyActive() external view returns (bool) {
        return emergencyUnlockTime != 0;
    }

    // ============ Test Helpers ============

    /// @notice Directly add to escrow for testing inbound credits
    /// @dev Only for testing - allows simulating funds coming from bridge
    function testAddEscrow() external payable {
        totalEscrowed += msg.value;
    }

    /// @notice Directly call _credit for testing inbound messages
    /// @dev Only for testing - simulates receiving a message from LayerZero
    function testCredit(address _to, uint256 _amountLD, uint32 _srcEid) external returns (uint256) {
        return _credit(_to, _amountLD, _srcEid);
    }
}
