//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// NOTE: This is a reference copy of Chainlink's ChainlinkSvrDAppControl from
// https://github.com/smartcontractkit/atlas-chainlink-external
// Included for POC integration testing. Production uses the deployed Chainlink contract.

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IAtlas } from "atlas/interfaces/IAtlas.sol";
import { DAppControl } from "atlas/dapp/DAppControl.sol";
import { CallConfig } from "atlas/types/ConfigTypes.sol";
import { UserOperation } from "atlas/types/UserOperation.sol";
import { SolverOperation } from "atlas/types/SolverOperation.sol";
import { ChainlinkSvrDAppExecutor } from "./ChainlinkSvrDAppExecutor.sol";

interface IAuthorizedForwarder {
    function isAuthorizedSender(address sender) external view returns (bool);
    function forward(address to, bytes memory data) external;
}

contract ChainlinkSvrDAppControl is DAppControl {
    error OnlyGovernance();
    error OnlyWhitelistedOracleAllowed();
    error InvalidUserOpDapp();
    error InvalidUserOpFrom();
    error InvalidUserEntryCall();
    error OracleUpdateFailed();
    error InvalidOevShares();
    error InvalidOevAllocationDestination();
    error InvalidBundlerSurchargeRate();
    error InvalidAuthorizedUserOpSigner();
    error InvalidExecutor();
    error InvalidExecutionEnv();
    error InvalidSelector();
    error BundlerIsNotAuthorizedSender();

    event OevSharesUpdated(uint256 shareFastlane, uint256 shareBuilder);
    event AllocationDestinationFastlaneUpdated(address indexed newDestination);
    event AllocationDestinationProtocolUpdated(address indexed newDestination);
    event SolverGasLimitUpdated(uint32 newLimit);
    event DAppGasLimitUpdated(uint32 newLimit);
    event BundlerSurchargeRateUpdated(uint24 newRate);
    event AuthorizedUserOpSignerUpdated(address indexed newSigner);
    event AllowedSelectorUpdated(bytes4 indexed selector, bool isAllowed);
    event OracleWhitelistUpdated(address indexed oracle, bool isWhitelisted);
    event BundlerWhitelistUpdated(address indexed bundler, bool isWhitelisted);

    event OevAllocated(
        address indexed fastlaneOevDestination,
        address indexed bundlerDestination,
        address indexed protocolOevDestination,
        uint256 totalOev,
        uint256 oevFastlane,
        uint256 oevBuilder,
        uint256 oevProtocol
    );

    uint256 public constant OEV_SHARE_SCALE = 10_000;
    uint256 public constant MAX_BUNDLER_SURCHARGE_RATE = 10_000;

    ChainlinkSvrDAppExecutor public immutable EXECUTOR;

    uint32 internal solverGasLimit = 6_000_000;
    uint32 internal dappGasLimit = 2_000_000;
    uint24 internal bundlerSurchargeRate = 0;

    uint16 public oevShareFastlane;
    uint16 public oevShareBuilder;

    address public oevAllocationDestinationFastlane;
    address public oevAllocationDestinationProtocol;

    address public authorizedUserOpSigner;
    address public authorizedExecutionEnv;

    uint32 public whitelistedOraclesCount = 0;
    uint32 public allowedSelectorsCount = 0;

    mapping(address oracle => bool isWhitelisted) public oracleWhitelist;
    mapping(address bundler => bool isWhitelisted) public bundlerWhitelist;
    mapping(bytes4 selector => bool isAllowed) public allowedSelectors;

    constructor(
        address atlas,
        address executor_,
        uint256 oevShareFastlane_,
        uint256 oevShareBuilder_,
        address oevAllocationDestinationFastlane_,
        address oevAllocationDestinationProtocol_
    )
        DAppControl(
            atlas,
            msg.sender,
            CallConfig({
                userNoncesSequential: false,
                dappNoncesSequential: false,
                requirePreOps: true,
                trackPreOpsReturnData: false,
                trackUserReturnData: false,
                delegateUser: false,
                requirePreSolver: false,
                requirePostSolver: false,
                zeroSolvers: false,
                reuseUserOp: true,
                userAuctioneer: false,
                solverAuctioneer: false,
                unknownAuctioneer: false,
                verifyCallChainHash: true,
                forwardReturnData: false,
                requireFulfillment: true,
                trustedOpHash: false,
                invertBidValue: false,
                exPostBids: false,
                multipleSuccessfulSolvers: false,
                checkMetacallGasLimit: false
            })
        )
    {
        if (executor_ == address(0)) revert InvalidExecutor();
        EXECUTOR = ChainlinkSvrDAppExecutor(executor_);

        if (oevShareFastlane_ + oevShareBuilder_ > OEV_SHARE_SCALE) revert InvalidOevShares();
        if (oevAllocationDestinationFastlane_ == address(0)) revert InvalidOevAllocationDestination();
        if (oevAllocationDestinationProtocol_ == address(0)) revert InvalidOevAllocationDestination();

        oevShareFastlane = uint16(oevShareFastlane_);
        oevShareBuilder = uint16(oevShareBuilder_);
        oevAllocationDestinationFastlane = oevAllocationDestinationFastlane_;
        oevAllocationDestinationProtocol = oevAllocationDestinationProtocol_;

        allowedSelectors[IAuthorizedForwarder.forward.selector] = true;
        allowedSelectorsCount = 1;
    }

    // ---------------------------------------------------- //
    //                   Custom Functions                   //
    // ---------------------------------------------------- //

    modifier onlyGov() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    function setOevShares(uint256 oevShareFastlane_, uint256 oevShareBuilder_) external onlyGov {
        if (oevShareFastlane_ + oevShareBuilder_ > OEV_SHARE_SCALE) revert InvalidOevShares();
        oevShareFastlane = uint16(oevShareFastlane_);
        oevShareBuilder = uint16(oevShareBuilder_);
        emit OevSharesUpdated(oevShareFastlane, oevShareBuilder);
    }

    function setOevAllocationDestinationFastlane(address oevAllocationDestinationFastlane_) external onlyGov {
        if (oevAllocationDestinationFastlane_ == address(0)) revert InvalidOevAllocationDestination();
        oevAllocationDestinationFastlane = oevAllocationDestinationFastlane_;
        emit AllocationDestinationFastlaneUpdated(oevAllocationDestinationFastlane);
    }

    function setOevAllocationDestinationProtocol(address oevAllocationDestinationProtocol_) external onlyGov {
        if (oevAllocationDestinationProtocol_ == address(0)) revert InvalidOevAllocationDestination();
        oevAllocationDestinationProtocol = oevAllocationDestinationProtocol_;
        emit AllocationDestinationProtocolUpdated(oevAllocationDestinationProtocol);
    }

    function setSolverGasLimit(uint32 solverGasLimit_) external onlyGov {
        solverGasLimit = solverGasLimit_;
        emit SolverGasLimitUpdated(solverGasLimit);
    }

    function setDAppGasLimit(uint32 dappGasLimit_) external onlyGov {
        dappGasLimit = dappGasLimit_;
        emit DAppGasLimitUpdated(dappGasLimit);
    }

    function setBundlerSurchargeRate(uint24 bundlerSurchargeRate_) external onlyGov {
        if (bundlerSurchargeRate_ > MAX_BUNDLER_SURCHARGE_RATE) revert InvalidBundlerSurchargeRate();
        bundlerSurchargeRate = bundlerSurchargeRate_;
        emit BundlerSurchargeRateUpdated(bundlerSurchargeRate);
    }

    function setAuthorizedUserOpSigner(address authorizedUserOpSigner_) external onlyGov {
        if (authorizedUserOpSigner_ == address(0)) revert InvalidAuthorizedUserOpSigner();
        authorizedUserOpSigner = authorizedUserOpSigner_;
        _updateAuthorizedExecutionEnv(authorizedUserOpSigner_);
        emit AuthorizedUserOpSignerUpdated(authorizedUserOpSigner);
    }

    function verifyAllowedSelector(bytes4 selector) external view {
        if (allowedSelectorsCount > 0 && !allowedSelectors[selector]) revert InvalidSelector();
    }

    function addBundlersToWhitelist(address[] calldata bundlers) external onlyGov {
        for (uint256 i = 0; i < bundlers.length; ++i) {
            address bundler = bundlers[i];
            if (!bundlerWhitelist[bundler]) {
                bundlerWhitelist[bundler] = true;
                emit BundlerWhitelistUpdated(bundler, true);
            }
        }
    }

    function removeBundlersFromWhitelist(address[] calldata bundlers) external onlyGov {
        for (uint256 i = 0; i < bundlers.length; ++i) {
            address bundler = bundlers[i];
            if (bundlerWhitelist[bundler]) {
                bundlerWhitelist[bundler] = false;
                emit BundlerWhitelistUpdated(bundler, false);
            }
        }
    }

    function addAllowedSelector(bytes4 selector) external onlyGov {
        if (!allowedSelectors[selector]) {
            allowedSelectors[selector] = true;
            allowedSelectorsCount++;
            emit AllowedSelectorUpdated(selector, true);
        }
    }

    function removeAllowedSelector(bytes4 selector) external onlyGov {
        if (allowedSelectors[selector]) {
            allowedSelectors[selector] = false;
            allowedSelectorsCount--;
            emit AllowedSelectorUpdated(selector, false);
        }
    }

    // ---------------------------------------------------- //
    //               Oracle Related Functions               //
    // ---------------------------------------------------- //

    function verifyOracleWhitelist(address oracle) external view {
        if (whitelistedOraclesCount > 0 && !oracleWhitelist[oracle]) revert OnlyWhitelistedOracleAllowed();
    }

    function addOracleToWhitelist(address oracle) external onlyGov {
        if (!oracleWhitelist[oracle]) {
            oracleWhitelist[oracle] = true;
            whitelistedOraclesCount++;
            emit OracleWhitelistUpdated(oracle, true);
        }
    }

    function removeOracleFromWhitelist(address oracle) external onlyGov {
        if (oracleWhitelist[oracle]) {
            oracleWhitelist[oracle] = false;
            whitelistedOraclesCount--;
            emit OracleWhitelistUpdated(oracle, false);
        }
    }

    // ---------------------------------------------------- //
    //                  Atlas Hook Overrides                //
    // ---------------------------------------------------- //

    function _preOpsCall(UserOperation calldata userOp) internal view virtual override returns (bytes memory) {
        if (userOp.dapp != CONTROL) revert InvalidUserOpDapp();
        if (userOp.from != ChainlinkSvrDAppControl(CONTROL).authorizedUserOpSigner()) revert InvalidUserOpFrom();
        if (bytes4(userOp.data) != bytes4(ChainlinkSvrDAppControl.update.selector)) {
            revert InvalidUserEntryCall();
        }

        (address _oracle, bytes memory _updateCallData) = abi.decode(userOp.data[4:], (address, bytes));
        ChainlinkSvrDAppControl(CONTROL).verifyOracleWhitelist(_oracle);
        ChainlinkSvrDAppControl(CONTROL).verifyAllowedSelector(bytes4(_updateCallData));

        if (
            !ChainlinkSvrDAppControl(CONTROL).bundlerWhitelist(_bundler())
                && !IAuthorizedForwarder(_oracle).isAuthorizedSender(_bundler())
        ) {
            revert BundlerIsNotAuthorizedSender();
        }

        return "";
    }

    function _allocateValueCall(bool, address, uint256 bidAmount, bytes calldata) internal virtual override {
        if (bidAmount == 0) return;

        (uint256 fastlaneShare, uint256 builderShare, address fastlaneDest, address protocolDest) =
            ChainlinkSvrDAppControl(CONTROL).getSharesAndDestinations();

        uint256 _oevShareFastlane = bidAmount * fastlaneShare / OEV_SHARE_SCALE;
        if (_oevShareFastlane > 0) SafeTransferLib.safeTransferETH(fastlaneDest, _oevShareFastlane);

        uint256 _oevShareBuilder = bidAmount * builderShare / OEV_SHARE_SCALE;
        if (_oevShareBuilder > 0) SafeTransferLib.safeTransferETH(block.coinbase, _oevShareBuilder);

        uint256 _oevShareProtocol = bidAmount - _oevShareFastlane - _oevShareBuilder;
        if (_oevShareProtocol > 0) SafeTransferLib.safeTransferETH(protocolDest, _oevShareProtocol);

        emit OevAllocated(
            fastlaneDest,
            block.coinbase,
            protocolDest,
            bidAmount,
            _oevShareFastlane,
            _oevShareBuilder,
            _oevShareProtocol
        );
    }

    // ---------------------------------------------------- //
    //                    UserOp Function                   //
    // ---------------------------------------------------- //

    function update(address oracle, bytes calldata callData) external {
        if (msg.sender != authorizedExecutionEnv) revert InvalidExecutionEnv();
        EXECUTOR.execute(oracle, callData);
    }

    // ---------------------------------------------------- //
    //                    View Functions                    //
    // ---------------------------------------------------- //

    function getBidFormat(UserOperation calldata) public pure override returns (address bidToken) {
        return address(0);
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }

    function getSolverGasLimit() public view override returns (uint32) {
        return solverGasLimit;
    }

    function getDAppGasLimit() public view override returns (uint32) {
        return dappGasLimit;
    }

    function getBundlerSurchargeRate() public view override returns (uint24) {
        return bundlerSurchargeRate;
    }

    function getSharesAndDestinations()
        external
        view
        returns (
            uint256 oevShareFastlane_,
            uint256 oevShareBuilder_,
            address oevAllocationDestinationFastlane_,
            address oevAllocationDestinationProtocol_
        )
    {
        return (oevShareFastlane, oevShareBuilder, oevAllocationDestinationFastlane, oevAllocationDestinationProtocol);
    }

    // ---------------------------------------------------- //
    //                  Internal Functions                  //
    // ---------------------------------------------------- //

    function _updateAuthorizedExecutionEnv(address newAuthedUserOpSigner) internal {
        (authorizedExecutionEnv,,) = IAtlas(ATLAS).getExecutionEnvironment(newAuthedUserOpSigner, address(this));
    }
}
