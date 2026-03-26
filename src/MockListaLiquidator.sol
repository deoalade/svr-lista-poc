// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Morpho-style MarketParams used by ListaDAO (Moolah fork)
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Callback interface that the liquidator calls on msg.sender mid-liquidation
interface IMorphoLiquidateCallback {
    function onMorphoLiquidate(uint256 repaidAssets, bytes calldata data) external;
}

/// @title MockListaLiquidator
/// @notice Simulates ListaDAO's whitelisted Liquidator wrapper around Morpho-style liquidation.
///         Implements: whitelist check, collateral transfer to msg.sender, optional callback,
///         then pulls loan token repayment via transferFrom.
contract MockListaLiquidator {
    mapping(address => bool) public approvedCallers;
    address public owner;

    // Track state for test assertions
    uint256 public lastSeizedAssets;
    uint256 public lastRepaidAssets;

    error NotWhitelisted();
    error OnlyOwner();

    constructor() {
        owner = msg.sender;
    }

    function setApprovedCaller(address caller) external {
        require(msg.sender == owner, OnlyOwner());
        approvedCallers[caller] = true;
    }

    function removeApprovedCaller(address caller) external {
        require(msg.sender == owner, OnlyOwner());
        approvedCallers[caller] = false;
    }

    /// @notice Morpho-style liquidate function with whitelist enforcement
    /// @dev Flow: check whitelist -> transfer collateral to msg.sender -> optional callback -> pull loan tokens
    function liquidate(
        MarketParams memory marketParams,
        address, /* borrower */
        uint256 seizedAssets,
        uint256, /* repaidShares (unused in mock) */
        bytes calldata data
    ) external returns (uint256 actualSeizedAssets, uint256 actualRepaidAssets) {
        require(approvedCallers[msg.sender], NotWhitelisted());

        // In a real Morpho, repaidAssets is calculated from shares. We simplify: repaid = seized / 2
        actualSeizedAssets = seizedAssets;
        actualRepaidAssets = seizedAssets / 2;

        lastSeizedAssets = actualSeizedAssets;
        lastRepaidAssets = actualRepaidAssets;

        // Step 1: Transfer collateral to msg.sender (the caller / wrapper)
        IERC20(marketParams.collateralToken).transfer(msg.sender, actualSeizedAssets);

        // Step 2: If data is non-empty, call onMorphoLiquidate callback on msg.sender
        if (data.length > 0) {
            IMorphoLiquidateCallback(msg.sender).onMorphoLiquidate(actualRepaidAssets, data);
        }

        // Step 3: Pull loan token repayment from msg.sender
        IERC20(marketParams.loanToken).transferFrom(msg.sender, address(this), actualRepaidAssets);

        return (actualSeizedAssets, actualRepaidAssets);
    }
}
