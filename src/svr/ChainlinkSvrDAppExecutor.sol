//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// NOTE: This is a reference copy of Chainlink's ChainlinkSvrDAppExecutor from
// https://github.com/smartcontractkit/atlas-chainlink-external
// Included for POC integration testing. Production uses the deployed Chainlink contract.

import { OwnerIsCreator } from "@chainlink/src/v0.8/shared/access/OwnerIsCreator.sol";

/// @title ChainlinkSvrDAppExecutor
/// @notice Stable executor contract that forwards oracle update calls
/// @dev This contract should be authorized on oracles. DAppControls can be upgraded
///      while this executor remains stable, avoiding the need to re-authorize on oracles.
contract ChainlinkSvrDAppExecutor is OwnerIsCreator {
    error Unauthorized();
    error OracleUpdateFailed();
    error ZeroAddress();

    event DAppAuthorized(address indexed dApp);
    event DAppRevoked(address indexed dApp);

    mapping(address dApp => bool isAuthorized) public authorizedDAppControls;

    /// @notice Authorize a DAppControl to use this executor
    /// @param dApp The address of the DAppControl contract
    function authorizeDAppControl(address dApp) external onlyOwner {
        if (dApp == address(0)) revert ZeroAddress();
        authorizedDAppControls[dApp] = true;
        emit DAppAuthorized(dApp);
    }

    /// @notice Revoke a DAppControl's authorization
    /// @param dApp The address of the DAppControl contract
    function revokeDAppControl(address dApp) external onlyOwner {
        if (dApp == address(0)) revert ZeroAddress();
        authorizedDAppControls[dApp] = false;
        emit DAppRevoked(dApp);
    }

    /// @notice Execute a call to an oracle
    /// @dev Only callable by authorized DAppControls
    /// @dev msg.sender to the oracle will be this executor (stable, authorized address)
    /// @param target The oracle address to call
    /// @param data The calldata to send to the oracle
    function execute(address target, bytes calldata data) external {
        if (!authorizedDAppControls[msg.sender]) revert Unauthorized();
        (bool success,) = target.call(data);
        if (!success) revert OracleUpdateFailed();
    }
}
