// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MarketParams, IMorphoLiquidateCallback } from "./MockListaLiquidator.sol";

/// @notice Interface for the ListaDAO Liquidator's liquidate function
interface IListaLiquidator {
    function liquidate(
        MarketParams memory marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256, uint256);
}

/// @title SVRLiquidationWrapper
/// @notice Wrapper that sits between Atlas solvers and the ListaDAO Liquidator.
///         Enforces dual access control: approved solver (msg.sender) + approved NOP (tx.origin).
///         Handles token approvals, forwards liquidation calls, and routes tokens back to solver.
contract SVRLiquidationWrapper is Ownable, IMorphoLiquidateCallback {
    using SafeERC20 for IERC20;

    address public immutable liquidator;

    mapping(address => bool) public approvedSolvers;
    mapping(address => bool) public approvedNOPs;

    // Transient storage for mid-liquidation callback context
    address private _activeSolver;
    address private _activeLoanToken;

    error NotApprovedSolver();
    error NotApprovedNOP();
    error NotLiquidator();

    event SolverAdded(address indexed solver);
    event SolverRemoved(address indexed solver);
    event NOPAdded(address indexed nop);
    event NOPRemoved(address indexed nop);
    event LiquidationExecuted(
        address indexed solver,
        address indexed collateralToken,
        address indexed loanToken,
        uint256 seizedAssets,
        uint256 repaidAssets
    );

    constructor(address _liquidator, address _owner) Ownable(_owner) {
        liquidator = _liquidator;
    }

    // ---------------------------------------------------- //
    //                  Admin Functions                      //
    // ---------------------------------------------------- //

    function addApprovedSolver(address solver) external onlyOwner {
        approvedSolvers[solver] = true;
        emit SolverAdded(solver);
    }

    function removeApprovedSolver(address solver) external onlyOwner {
        approvedSolvers[solver] = false;
        emit SolverRemoved(solver);
    }

    function addApprovedNOP(address nop) external onlyOwner {
        approvedNOPs[nop] = true;
        emit NOPAdded(nop);
    }

    function removeApprovedNOP(address nop) external onlyOwner {
        approvedNOPs[nop] = false;
        emit NOPRemoved(nop);
    }

    function recoverToken(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    // ---------------------------------------------------- //
    //                 Liquidation Logic                     //
    // ---------------------------------------------------- //

    /// @notice Execute a liquidation through the ListaDAO Liquidator
    /// @dev Caller must be an approved solver, tx.origin must be an approved NOP
    /// @param marketParams Morpho-style market parameters
    /// @param borrower The borrower being liquidated
    /// @param seizedAssets Amount of collateral to seize
    /// @param repaidShares Amount of debt shares to repay
    /// @param data Callback data (non-empty triggers onMorphoLiquidate callback)
    function liquidate(
        MarketParams calldata marketParams,
        address borrower,
        uint256 seizedAssets,
        uint256 repaidShares,
        bytes calldata data
    ) external returns (uint256 actualSeizedAssets, uint256 actualRepaidAssets) {
        require(approvedSolvers[msg.sender], NotApprovedSolver());
        // solhint-disable-next-line avoid-tx-origin
        require(approvedNOPs[tx.origin], NotApprovedNOP());

        // Store context for the callback
        _activeSolver = msg.sender;
        _activeLoanToken = marketParams.loanToken;

        // The Liquidator will pull loan tokens from us via transferFrom,
        // so we need the solver to have sent us loan tokens first, OR
        // we handle it in the callback. We use the callback approach:
        // pass non-empty data to trigger onMorphoLiquidate where we pull
        // loan tokens from the solver.
        bytes memory callbackData = data.length > 0
            ? data
            : abi.encode(msg.sender); // Always trigger callback

        // Approve the Liquidator to pull loan tokens from us (set in callback)
        // We do a max approval here for simplicity; in production use exact amounts
        IERC20(marketParams.loanToken).forceApprove(liquidator, type(uint256).max);

        (actualSeizedAssets, actualRepaidAssets) = IListaLiquidator(liquidator).liquidate(
            marketParams,
            borrower,
            seizedAssets,
            repaidShares,
            callbackData
        );

        // Forward seized collateral back to the solver
        uint256 collateralBalance = IERC20(marketParams.collateralToken).balanceOf(address(this));
        if (collateralBalance > 0) {
            IERC20(marketParams.collateralToken).safeTransfer(msg.sender, collateralBalance);
        }

        // Return any leftover loan tokens to the solver
        uint256 loanBalance = IERC20(marketParams.loanToken).balanceOf(address(this));
        if (loanBalance > 0) {
            IERC20(marketParams.loanToken).safeTransfer(msg.sender, loanBalance);
        }

        // Reset approval
        IERC20(marketParams.loanToken).forceApprove(liquidator, 0);

        // Clear transient state
        _activeSolver = address(0);
        _activeLoanToken = address(0);

        emit LiquidationExecuted(
            msg.sender,
            marketParams.collateralToken,
            marketParams.loanToken,
            actualSeizedAssets,
            actualRepaidAssets
        );
    }

    /// @notice Callback from the Liquidator during liquidation
    /// @dev Called after collateral is transferred to us, before loan tokens are pulled.
    ///      We pull loan tokens from the solver here so the Liquidator can then pull from us.
    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata /* data */) external {
        require(msg.sender == liquidator, NotLiquidator());

        // Pull loan tokens from the active solver to cover the repayment
        IERC20(_activeLoanToken).safeTransferFrom(_activeSolver, address(this), repaidAssets);
    }
}
