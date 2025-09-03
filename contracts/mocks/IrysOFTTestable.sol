// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { OFTUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTUpgradeable.sol";

// Test version of IrysOFT that allows direct initialization (no proxy required)
contract IrysOFTTestable is Initializable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable, OFTUpgradeable {
    // ERC-7201 namespaced storage pattern
    struct OFTStorage {
        uint256 maxSupply;
        mapping(address => bool) minters;
        mapping(address => bool) burners;
    }
    
    // keccak256(abi.encode(uint256(keccak256("irysOFT.storage.OFT")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant OFT_STORAGE_LOCATION = 0x0d0eb511d3307aa5801c8e31102dcaf47c45988241aa1d52644ea8a5557b0500;
    
    uint256[50] private __gap;
    
    error IrysOFT__MaxSupplyExceeded();
    error IrysOFT__UnauthorizedMinter();
    error IrysOFT__UnauthorizedBurner();
    error IrysOFT__ZeroAddress();
    
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
        uint256 _maxSupply
    ) public initializer {
        __Ownable_init(_delegate);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __OFT_init(_name, _symbol, _delegate);
        
        // Initialize storage
        OFTStorage storage $ = _getOFTStorage();
        $.maxSupply = _maxSupply;
        $.minters[_delegate] = true;
        $.burners[_delegate] = true;
        
        // Mint initial supply to delegate/owner
        _mint(_delegate, $.maxSupply);
        
        // Emit initialization event for transparency
        emit Initialized(_name, _symbol, _delegate, $.maxSupply);
    }
    
    function _getOFTStorage() private pure returns (OFTStorage storage $) {
        assembly {
            $.slot := OFT_STORAGE_LOCATION
        }
    }
    
    function mint(address to, uint256 amount) external virtual whenNotPaused {
        OFTStorage storage $ = _getOFTStorage();
        if (!$.minters[msg.sender]) revert IrysOFT__UnauthorizedMinter();
        if (totalSupply() + amount > $.maxSupply) revert IrysOFT__MaxSupplyExceeded();
        
        _mint(to, amount);
        emit PrivilegedMint(to, amount, msg.sender);
    }
    
    function burn(address from, uint256 amount) external virtual whenNotPaused {
        OFTStorage storage $ = _getOFTStorage();
        if (!$.burners[msg.sender]) revert IrysOFT__UnauthorizedBurner();
        
        _burn(from, amount);
        emit PrivilegedBurn(from, amount, msg.sender);
    }
    
    function setMinter(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert IrysOFT__ZeroAddress();
        OFTStorage storage $ = _getOFTStorage();
        $.minters[account] = enabled;
        emit MinterSet(account, enabled);
    }
    
    function setBurner(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert IrysOFT__ZeroAddress();
        OFTStorage storage $ = _getOFTStorage();
        $.burners[account] = enabled;
        emit BurnerSet(account, enabled);
    }
    
    function isMinter(address account) external view returns (bool) {
        OFTStorage storage $ = _getOFTStorage();
        return $.minters[account];
    }
    
    function isBurner(address account) external view returns (bool) {
        OFTStorage storage $ = _getOFTStorage();
        return $.burners[account];
    }
    
    function getCurrentSupply() external view returns (uint256) {
        return totalSupply();
    }
    
    function getMaxSupply() external view returns (uint256) {
        OFTStorage storage $ = _getOFTStorage();
        return $.maxSupply;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
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