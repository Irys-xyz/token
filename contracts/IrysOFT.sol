// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { OFTUpgradeable } from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTUpgradeable.sol";

/// @custom:oz-upgrades-unsafe-allow constructor
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable
contract IrysOFT is Initializable, OwnableUpgradeable, PausableUpgradeable, UUPSUpgradeable, OFTUpgradeable {
    uint256[50] private __gap;

    error IrysOFT__ZeroAddress();

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
        if (_delegate == address(0)) revert IrysOFT__ZeroAddress();

        __Ownable_init(_delegate);
        __UUPSUpgradeable_init();
        __Pausable_init();
        __OFT_init(_name, _symbol, _delegate);

        // Mint entire fixed supply to delegate/owner
        _mint(_delegate, _totalSupply);

        emit Initialized(_name, _symbol, _delegate, _totalSupply);
    }
    
    function getCurrentSupply() external view returns (uint256) {
        return totalSupply();
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
