// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Minimal stub of Chainlink OwnerIsCreator for POC compilation.
///         Production deploys use the real chainlink contracts package.
contract OwnerIsCreator {
    address private s_owner;

    event OwnershipTransferred(address indexed from, address indexed to);

    constructor() {
        s_owner = msg.sender;
    }

    function owner() public view returns (address) {
        return s_owner;
    }

    modifier onlyOwner() {
        require(msg.sender == s_owner, "Only callable by owner");
        _;
    }

    function transferOwnership(address to) public onlyOwner {
        address oldOwner = s_owner;
        s_owner = to;
        emit OwnershipTransferred(oldOwner, to);
    }
}
