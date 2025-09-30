// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { OFTUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTUpgradeable.sol";

// Test version of IrysOFT that allows direct initialization (no proxy required)
// Note: Retains old mint/burn functionality for testing purposes only
contract IrysOFTTestable is Initializable, PausableUpgradeable, UUPSUpgradeable, OFTUpgradeable {
    // Traditional state variables (mirroring production contract structure)
    // Two-step ownership state
    address private _pendingOwner;

    // Additional state for testing mint/burn functionality
    uint256 private _maxSupply;
    mapping(address => bool) private _minters;
    mapping(address => bool) private _burners;

    // Storage gap for upgradeability (46 slots to account for the 3 storage variables above)
    uint256[46] private __gap;

    error IrysOFT__MaxSupplyExceeded();
    error IrysOFT__UnauthorizedMinter();
    error IrysOFT__UnauthorizedBurner();
    error IrysOFT__ZeroAddress();
    error IrysOFT__RenounceOwnershipDisabled();
    error IrysOFT__NotPendingOwner();
    error IrysOFT__InvalidSupply();
    error IrysOFT__SupplyTooLarge();
    error IrysOFT__InvalidName();
    error IrysOFT__InvalidSymbol();

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferCanceled();

    event MinterSet(address indexed account, bool enabled);
    event BurnerSet(address indexed account, bool enabled);
    event PrivilegedMint(address indexed to, uint256 amount, address indexed minter);
    event PrivilegedBurn(address indexed from, uint256 amount, address indexed burner);
    event Initialized(string name, string symbol, address indexed delegate, uint256 maxSupply);
    
    // No disabled initializers for testing
    constructor(address _lzEndpoint) OFTUpgradeable(_lzEndpoint) {}
    
    function initialize(
        string memory _name,
        string memory _symbol,
        address _delegate,
        uint256 maxSupply
    ) public initializer {
        // Input validation (matching production contract)
        if (_delegate == address(0)) revert IrysOFT__ZeroAddress();
        if (maxSupply == 0) revert IrysOFT__InvalidSupply();
        if (maxSupply > type(uint256).max / 2) revert IrysOFT__SupplyTooLarge();

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

        // Initialize state variables directly
        _maxSupply = maxSupply;
        _minters[_delegate] = true;
        _burners[_delegate] = true;

        // Mint initial supply to delegate/owner
        _mint(_delegate, _maxSupply);

        // Emit initialization event for transparency
        emit Initialized(_name, _symbol, _delegate, _maxSupply);
    }
    
    function mint(address to, uint256 amount) external virtual whenNotPaused {
        if (!_minters[msg.sender]) revert IrysOFT__UnauthorizedMinter();
        if (totalSupply() + amount > _maxSupply) revert IrysOFT__MaxSupplyExceeded();

        _mint(to, amount);
        emit PrivilegedMint(to, amount, msg.sender);
    }

    function burn(address from, uint256 amount) external virtual whenNotPaused {
        if (!_burners[msg.sender]) revert IrysOFT__UnauthorizedBurner();

        _burn(from, amount);
        emit PrivilegedBurn(from, amount, msg.sender);
    }

    function setMinter(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert IrysOFT__ZeroAddress();
        _minters[account] = enabled;
        emit MinterSet(account, enabled);
    }

    function setBurner(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert IrysOFT__ZeroAddress();
        _burners[account] = enabled;
        emit BurnerSet(account, enabled);
    }

    function isMinter(address account) external view returns (bool) {
        return _minters[account];
    }

    function isBurner(address account) external view returns (bool) {
        return _burners[account];
    }

    function getMaxSupply() external view returns (uint256) {
        return _maxSupply;
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