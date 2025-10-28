// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { OFTUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTUpgradeable.sol";

/// @custom:oz-upgrades-unsafe-allow constructor
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable
contract IrysOFT is Initializable, PausableUpgradeable, UUPSUpgradeable, OFTUpgradeable {
    // Two-step ownership state
    address private _pendingOwner;

    error IrysOFT__ZeroAddress();
    error IrysOFT__RenounceOwnershipDisabled();
    error IrysOFT__NotPendingOwner();
    error IrysOFT__SupplyTooLarge();
    error IrysOFT__InvalidName();
    error IrysOFT__InvalidSymbol();

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferCanceled();

    event Initialized(string name, string symbol, address indexed delegate, uint256 totalSupply);
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _lzEndpoint) OFTUpgradeable(_lzEndpoint) {
        _disableInitializers();
    }
    
    function initialize(
        string memory _name,
        string memory _symbol,
        address _delegate,
        uint256 _totalSupply
    ) public initializer {
        // Input validation
        if (_delegate == address(0)) revert IrysOFT__ZeroAddress();
        if (_totalSupply > type(uint256).max / 2) revert IrysOFT__SupplyTooLarge(); // Prevent overflow issues

        // Name validation: must be non-empty and <= 50 chars
        uint256 nameLength = bytes(_name).length;
        if (nameLength == 0 || nameLength > 50) revert IrysOFT__InvalidName();

        // Symbol validation: must be non-empty and <= 20 chars
        uint256 symbolLength = bytes(_symbol).length;
        if (symbolLength == 0 || symbolLength > 20) revert IrysOFT__InvalidSymbol();

        __Ownable_init(_delegate);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __OFT_init(_name, _symbol, _delegate);

        // Mint entire fixed supply to delegate/owner (if supply > 0)
        if (_totalSupply > 0) {
            _mint(_delegate, _totalSupply);
        }

        emit Initialized(_name, _symbol, _delegate, _totalSupply);
    }

    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Returns the address of the pending owner
    function pendingOwner() public view virtual returns (address) {
        return _pendingOwner;
    }

    /// @notice Starts the ownership transfer of the contract to a new account
    /// @dev Replaces the pending transfer if there is one
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        if (newOwner == address(0)) revert IrysOFT__ZeroAddress();
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    /// @notice The new owner accepts the ownership transfer
    function acceptOwnership() public virtual {
        if (msg.sender != _pendingOwner) revert IrysOFT__NotPendingOwner();
        delete _pendingOwner;
        _transferOwnership(msg.sender);
    }

    /// @notice Cancels a pending ownership transfer
    /// @dev Can only be called by the current owner
    function cancelOwnershipTransfer() public virtual onlyOwner {
        delete _pendingOwner;
        emit OwnershipTransferCanceled();
    }

    /// @notice Ownership renouncement is disabled to prevent accidental loss of control
    function renounceOwnership() public view override onlyOwner {
        revert IrysOFT__RenounceOwnershipDisabled();
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}
    
    function _update(
        address from,
        address to,
        uint256 amount
    ) internal override {
        if (paused()) {
            revert EnforcedPause();
        }
        super._update(from, to, amount);
    }
}
