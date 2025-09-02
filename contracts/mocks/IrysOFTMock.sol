// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { IrysOFT } from "../IrysOFT.sol";

// @dev WARNING: This is for testing purposes only
contract IrysOFTMock is IrysOFT {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _lzEndpoint) IrysOFT(_lzEndpoint) {}

    function initializeMock(
        string memory _name,
        string memory _symbol,
        address _delegate
    ) public initializer {
        initialize(_name, _symbol, _delegate);
    }

    function mint(address _to, uint256 _amount) public override {
        _mint(_to, _amount);
    }
}
