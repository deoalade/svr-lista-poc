// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SolverBase } from "atlas/solver/SolverBase.sol";
import { MarketParams } from "./MockListaLiquidator.sol";
import { SVRLiquidationWrapper } from "./SVRLiquidationWrapper.sol";

/// @title SVRListaSolver
/// @notice Atlas solver that executes ListaDAO liquidations via the SVRLiquidationWrapper.
///         Inherits SolverBase for Atlas metacall integration.
contract SVRListaSolver is SolverBase {
    using SafeERC20 for IERC20;

    address public immutable wrapper;

    error NotSolverOwner();

    constructor(
        address weth,
        address atlas,
        address _wrapper
    ) SolverBase(weth, atlas, msg.sender) {
        wrapper = _wrapper;
    }

    /// @notice Execute a liquidation through the wrapper
    /// @dev Called via atlasSolverCall -> address(this).call(solverOpData)
    ///      Must use onlySelf modifier to ensure it's called through Atlas flow
    function executeLiquidation(
        MarketParams calldata marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external onlySelf {
        // Approve the wrapper to pull loan tokens from us during the callback
        IERC20(marketParams.loanToken).forceApprove(wrapper, type(uint256).max);

        // Call the wrapper which calls the ListaDAO Liquidator
        SVRLiquidationWrapper(wrapper).liquidate(
            marketParams,
            borrower,
            seizedAssets,
            repaidShares,
            data
        );

        // Reset approval
        IERC20(marketParams.loanToken).forceApprove(wrapper, 0);
    }

    /// @notice Withdraw ERC20 tokens from the solver (owner only)
    function withdrawToken(address token, address to, uint256 amount) external {
        if (msg.sender != _owner) revert NotSolverOwner();
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Withdraw ETH from the solver (owner only)
    function withdrawETH() external {
        if (msg.sender != _owner) revert NotSolverOwner();
        (bool success,) = payable(msg.sender).call{ value: address(this).balance }("");
        require(success, "Withdraw failed");
    }

    modifier onlySelf() {
        require(msg.sender == address(this), "Not called via atlasSolverCall");
        _;
    }

    fallback() external payable {}
    receive() external payable {}
}
