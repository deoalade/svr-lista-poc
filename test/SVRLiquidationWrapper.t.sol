// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { MockListaLiquidator, MarketParams } from "../src/MockListaLiquidator.sol";
import { SVRLiquidationWrapper } from "../src/SVRLiquidationWrapper.sol";
import { SVRListaSolver } from "../src/SVRListaSolver.sol";

// ================================================== //
//                    Mock ERC20 Tokens                //
// ================================================== //

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ================================================== //
//          Unit Tests (without Atlas)                //
// ================================================== //

contract SVRLiquidationWrapperUnitTest is Test {
    MockListaLiquidator public liquidator;
    SVRLiquidationWrapper public wrapper;
    MockERC20 public loanToken;
    MockERC20 public collateralToken;

    address owner = makeAddr("owner");
    address solver = makeAddr("solver");
    address nop = makeAddr("nop");
    address borrower = makeAddr("borrower");
    address nonNOP = makeAddr("nonNOP");

    MarketParams defaultMarketParams;

    function setUp() public {
        loanToken = new MockERC20("Loan Token", "LOAN");
        collateralToken = new MockERC20("Collateral Token", "COLL");

        liquidator = new MockListaLiquidator();
        wrapper = new SVRLiquidationWrapper(address(liquidator), owner);

        defaultMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(0),
            irm: address(0),
            lltv: 8000
        });

        // Setup: owner approves NOP
        vm.prank(owner);
        wrapper.addApprovedNOP(nop);

        // Whitelist wrapper on the mock liquidator
        liquidator.setApprovedCaller(address(wrapper));

        // Fund the liquidator with collateral (simulating a position)
        collateralToken.mint(address(liquidator), 1000e18);

        // Fund the solver with loan tokens for repayment
        loanToken.mint(solver, 1000e18);

        // Solver approves wrapper to pull loan tokens (done during callback)
        vm.prank(solver);
        loanToken.approve(address(wrapper), type(uint256).max);
    }

    // ------------------------------------------------ //
    //              Admin Function Tests                //
    // ------------------------------------------------ //

    function test_addApprovedNOP() public {
        address newNOP = makeAddr("newNOP");
        assertFalse(wrapper.approvedNOPs(newNOP));

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit SVRLiquidationWrapper.NOPAdded(newNOP);
        wrapper.addApprovedNOP(newNOP);

        assertTrue(wrapper.approvedNOPs(newNOP));
    }

    function test_removeApprovedNOP() public {
        assertTrue(wrapper.approvedNOPs(nop));

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit SVRLiquidationWrapper.NOPRemoved(nop);
        wrapper.removeApprovedNOP(nop);

        assertFalse(wrapper.approvedNOPs(nop));
    }

    function test_onlyOwnerCanAddNOP() public {
        address nonOwner = makeAddr("nonOwner");
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        wrapper.addApprovedNOP(nonOwner);
    }

    function test_recoverToken() public {
        loanToken.mint(address(wrapper), 50e18);
        assertEq(loanToken.balanceOf(address(wrapper)), 50e18);

        vm.prank(owner);
        wrapper.recoverToken(address(loanToken), owner, 50e18);

        assertEq(loanToken.balanceOf(owner), 50e18);
        assertEq(loanToken.balanceOf(address(wrapper)), 0);
    }

    // ------------------------------------------------ //
    //          Access Control Rejection Tests          //
    // ------------------------------------------------ //

    function test_rejectsNonApprovedNOP() public {
        vm.prank(solver, nonNOP); // msg.sender = solver, tx.origin = nonNOP
        vm.expectRevert(SVRLiquidationWrapper.NotApprovedNOP.selector);
        wrapper.liquidate(defaultMarketParams, borrower, 100e18, 0, "");
    }

    // ------------------------------------------------ //
    //        Successful Liquidation Tests             //
    // ------------------------------------------------ //

    function test_successfulLiquidation() public {
        uint256 seizedAssets = 100e18;
        uint256 expectedRepaid = seizedAssets / 2; // Mock: repaid = seized / 2

        uint256 solverLoanBefore = loanToken.balanceOf(solver);
        uint256 solverCollBefore = collateralToken.balanceOf(solver);

        vm.prank(solver, nop); // solver calls, NOP is tx.origin
        (uint256 actualSeized, uint256 actualRepaid) = wrapper.liquidate(
            defaultMarketParams, borrower, seizedAssets, 0, ""
        );

        assertEq(actualSeized, seizedAssets, "Seized assets mismatch");
        assertEq(actualRepaid, expectedRepaid, "Repaid assets mismatch");

        // Collateral should have been forwarded to solver
        assertEq(
            collateralToken.balanceOf(solver),
            solverCollBefore + seizedAssets,
            "Solver should have received collateral"
        );

        // Loan tokens should have been pulled from solver
        assertEq(
            loanToken.balanceOf(solver),
            solverLoanBefore - expectedRepaid,
            "Solver should have paid loan tokens"
        );

        // Wrapper should have zero balance of both tokens
        assertEq(loanToken.balanceOf(address(wrapper)), 0, "Wrapper should have no loan tokens");
        assertEq(collateralToken.balanceOf(address(wrapper)), 0, "Wrapper should have no collateral");
    }

    function test_successfulLiquidationWithCallbackData() public {
        uint256 seizedAssets = 200e18;
        bytes memory customData = abi.encode(uint256(42));

        vm.prank(solver, nop);
        (uint256 actualSeized, uint256 actualRepaid) = wrapper.liquidate(
            defaultMarketParams, borrower, seizedAssets, 0, customData
        );

        assertEq(actualSeized, seizedAssets);
        assertEq(actualRepaid, seizedAssets / 2);
        assertEq(collateralToken.balanceOf(solver), seizedAssets, "Solver got collateral");
    }

    function test_liquidatorWhitelistEnforced() public {
        // Remove wrapper from liquidator whitelist
        liquidator.removeApprovedCaller(address(wrapper));

        vm.prank(solver, nop);
        vm.expectRevert(); // MockListaLiquidator.NotWhitelisted
        wrapper.liquidate(defaultMarketParams, borrower, 100e18, 0, "");
    }

    function test_onMorphoLiquidateOnlyCallableByLiquidator() public {
        vm.prank(nonNOP);
        vm.expectRevert(SVRLiquidationWrapper.NotLiquidator.selector);
        wrapper.onMorphoLiquidate(100, "");
    }

    function test_tokenFlowEndToEnd() public {
        uint256 seizedAssets = 500e18;
        uint256 expectedRepaid = seizedAssets / 2;

        // Initial balances
        uint256 liquidatorCollBefore = collateralToken.balanceOf(address(liquidator));
        uint256 solverLoanBefore = loanToken.balanceOf(solver);

        vm.prank(solver, nop);
        wrapper.liquidate(defaultMarketParams, borrower, seizedAssets, 0, "");

        // Liquidator lost collateral
        assertEq(
            collateralToken.balanceOf(address(liquidator)),
            liquidatorCollBefore - seizedAssets,
            "Liquidator should have lost collateral"
        );

        // Liquidator gained loan tokens
        assertEq(
            loanToken.balanceOf(address(liquidator)),
            expectedRepaid,
            "Liquidator should have received loan token repayment"
        );

        // Solver gained collateral
        assertEq(
            collateralToken.balanceOf(solver),
            seizedAssets,
            "Solver should have received collateral"
        );

        // Solver lost loan tokens
        assertEq(
            loanToken.balanceOf(solver),
            solverLoanBefore - expectedRepaid,
            "Solver should have spent loan tokens"
        );

        // Wrapper is clean
        assertEq(loanToken.balanceOf(address(wrapper)), 0, "Wrapper loan balance should be 0");
        assertEq(collateralToken.balanceOf(address(wrapper)), 0, "Wrapper coll balance should be 0");
    }
}

// ================================================== //
//     Integration Tests (with full SVR + Atlas)       //
// ================================================== //
//
// Uses the real ChainlinkSvrDAppControl and ChainlinkSvrDAppExecutor
// from https://github.com/smartcontractkit/atlas-chainlink-external
// to test the complete SVR liquidation flow:
//
//   Chainlink NOP (bundler) submits Atlas metacall
//     → _preOpsCall: validates bundler, oracle, selector, userOp signer
//     → UserOp: DAppControl.update() → Executor → Oracle price update
//     → SolverOp: SVRListaSolver.executeLiquidation() → Wrapper → Liquidator
//     → _allocateValueCall: OEV distribution
//

import { SolverOperation } from "atlas/types/SolverOperation.sol";
import { UserOperation } from "atlas/types/UserOperation.sol";
import "atlas/types/DAppOperation.sol";
import { CallConfig } from "atlas/types/ConfigTypes.sol";
import { Atlas } from "atlas/atlas/Atlas.sol";
import { AtlasVerification } from "atlas/atlas/AtlasVerification.sol";
import { ExecutionEnvironment } from "atlas/common/ExecutionEnvironment.sol";
import { FactoryLib } from "atlas/atlas/FactoryLib.sol";
import { CallVerification } from "atlas/libraries/CallVerification.sol";

import { ChainlinkSvrDAppControl } from "../src/svr/ChainlinkSvrDAppControl.sol";
import { ChainlinkSvrDAppExecutor } from "../src/svr/ChainlinkSvrDAppExecutor.sol";

/// @notice Mock WETH for non-fork testing
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 wad) external { _burn(msg.sender, wad); payable(msg.sender).transfer(wad); }
    receive() external payable { _mint(msg.sender, msg.value); }
}

/// @notice Simulator stub — Atlas needs a simulator address but we don't use simulation in tests
contract MockSimulator {
    address public atlas;
    function setAtlas(address _atlas) external { atlas = _atlas; }
}

/// @notice Mock Chainlink oracle with authorized forwarder interface.
///         In production this is a real Chainlink Aggregator with SVR support.
contract MockOracle {
    uint256 public price;
    mapping(address sender => bool isAuthorized) internal authorizedSenders;

    constructor(address _authorizedSender) {
        authorizedSenders[_authorizedSender] = true;
        price = 100;
    }

    function isAuthorizedSender(address sender) external view returns (bool) {
        return authorizedSenders[sender];
    }

    /// @notice IAuthorizedForwarder.forward — called by the executor to update price
    function forward(address, bytes memory data) external {
        require(authorizedSenders[msg.sender], "Unauthorized updater");
        price = abi.decode(data, (uint256));
    }

    function setAuthorizedSender(address sender, bool isAuthorized) external {
        authorizedSenders[sender] = isAuthorized;
    }
}

/// @title SVR Integration Test
/// @notice Full Atlas metacall test using ChainlinkSvrDAppControl, oracle update,
///         and ListaDAO liquidation in a single atomic transaction.
contract SVRLiquidationWrapperIntegrationTest is Test {
    struct Sig { uint8 v; bytes32 r; bytes32 s; }

    // Atlas infrastructure
    Atlas public atlas;
    AtlasVerification public atlasVerification;

    // Chainlink SVR infrastructure
    ChainlinkSvrDAppControl public dappControl;
    ChainlinkSvrDAppExecutor public dappExecutor;
    MockOracle public mockOracle;

    // ListaDAO infrastructure
    MockListaLiquidator public mockLiquidator;
    SVRLiquidationWrapper public wrapper;
    SVRListaSolver public listaSolver;

    MockERC20 public loanToken;
    MockERC20 public collateralToken;
    MockWETH public weth;
    Sig public sig;

    address deployer;

    // Chainlink NOP = Atlas bundler (submits metacall, is tx.origin)
    address bundlerNOP;

    // Authorized userOp signer (Chainlink node authorized to create oracle update userOps)
    uint256 userOpSignerPK;
    address userOpSigner;

    // DApp governance signatory (signs DAppOperations)
    uint256 auctioneerPK;
    address auctioneer;

    // Searcher / solver EOA
    uint256 solverPK;
    address solverEOA;

    // DApp governance EOA (deploys and configures DAppControl)
    address govEOA;

    // OEV allocation destinations
    address fastlaneDest;
    address protocolDest;

    address executionEnvironment;

    MarketParams defaultMarketParams;
    uint256 seizedAssets = 100e18;

    function setUp() public {
        // ------------------------------------------------ //
        //              1. Create accounts                   //
        // ------------------------------------------------ //
        deployer = makeAddr("deployer");
        bundlerNOP = makeAddr("bundlerNOP");
        (userOpSigner, userOpSignerPK) = makeAddrAndKey("userOpSigner");
        (auctioneer, auctioneerPK) = makeAddrAndKey("auctioneer");
        (solverEOA, solverPK) = makeAddrAndKey("solverEOA");
        govEOA = makeAddr("govEOA");
        fastlaneDest = makeAddr("fastlaneDest");
        protocolDest = makeAddr("protocolDest");

        vm.deal(deployer, 100e18);
        vm.deal(solverEOA, 100e18);
        vm.deal(bundlerNOP, 100e18);

        // ------------------------------------------------ //
        //              2. Deploy tokens                    //
        // ------------------------------------------------ //
        weth = new MockWETH();
        loanToken = new MockERC20("Loan Token", "LOAN");
        collateralToken = new MockERC20("Collateral Token", "COLL");

        // ------------------------------------------------ //
        //       3. Deploy Atlas infrastructure             //
        // ------------------------------------------------ //
        vm.startPrank(deployer);

        MockSimulator simulator = new MockSimulator();

        address expectedAtlasAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        address expectedAtlasVerificationAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);

        ExecutionEnvironment execEnvTemplate = new ExecutionEnvironment(expectedAtlasAddr);

        string memory factoryLibPath = "lib/atlas/src/contracts/precompiles/FactoryLib.sol/FactoryLib.json";
        FactoryLib factoryLib = FactoryLib(deployCode(factoryLibPath, abi.encode(address(execEnvTemplate))));

        atlas = new Atlas({
            escrowDuration: 64,
            atlasSurchargeRate: 1000,
            verification: expectedAtlasVerificationAddr,
            simulator: address(simulator),
            initialSurchargeRecipient: deployer,
            l2GasCalculator: address(0),
            factoryLib: address(factoryLib)
        });

        atlasVerification = new AtlasVerification({
            atlas: expectedAtlasAddr,
            l2GasCalculator: address(0)
        });

        simulator.setAtlas(address(atlas));
        vm.stopPrank();

        // Fund solver in Atlas escrow
        vm.startPrank(solverEOA);
        atlas.deposit{ value: 1e18 }();
        vm.stopPrank();

        // ------------------------------------------------ //
        //   4. Deploy Chainlink SVR DAppControl + Executor //
        // ------------------------------------------------ //
        vm.startPrank(govEOA);

        dappExecutor = new ChainlinkSvrDAppExecutor();
        dappControl = new ChainlinkSvrDAppControl(
            address(atlas),
            address(dappExecutor),
            1000, // 10% Fastlane OEV share
            1000, // 10% Builder OEV share (remaining 80% → protocol)
            fastlaneDest,
            protocolDest
        );

        // Authorize DAppControl to call through the executor
        dappExecutor.authorizeDAppControl(address(dappControl));

        // Set the authorized userOp signer (Chainlink node)
        dappControl.setAuthorizedUserOpSigner(userOpSigner);

        // Register DAppControl with Atlas governance
        atlasVerification.initializeGovernance(address(dappControl));

        // Add auctioneer as signatory for signing DAppOperations
        atlasVerification.addSignatory(address(dappControl), auctioneer);

        // Whitelist the bundler (Chainlink NOP)
        address[] memory bundlers = new address[](1);
        bundlers[0] = bundlerNOP;
        dappControl.addBundlersToWhitelist(bundlers);

        vm.stopPrank();

        // ------------------------------------------------ //
        //           5. Deploy MockOracle                   //
        // ------------------------------------------------ //
        // The executor is the authorized sender on the oracle
        mockOracle = new MockOracle(address(dappExecutor));

        // Whitelist the oracle on DAppControl
        vm.prank(govEOA);
        dappControl.addOracleToWhitelist(address(mockOracle));

        // ------------------------------------------------ //
        //   6. Create execution environment for signer    //
        // ------------------------------------------------ //
        vm.prank(userOpSigner);
        executionEnvironment = atlas.createExecutionEnvironment(userOpSigner, address(dappControl));

        // ------------------------------------------------ //
        //   7. Deploy ListaDAO mock + Wrapper              //
        // ------------------------------------------------ //
        mockLiquidator = new MockListaLiquidator();
        wrapper = new SVRLiquidationWrapper(address(mockLiquidator), address(this));
        mockLiquidator.setApprovedCaller(address(wrapper));

        defaultMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(0),
            irm: address(0),
            lltv: 8000
        });

        // ------------------------------------------------ //
        //                   Labels                         //
        // ------------------------------------------------ //
        vm.label(address(atlas), "Atlas");
        vm.label(address(atlasVerification), "AtlasVerification");
        vm.label(address(dappControl), "ChainlinkSvrDAppControl");
        vm.label(address(dappExecutor), "ChainlinkSvrDAppExecutor");
        vm.label(address(mockOracle), "MockOracle");
        vm.label(address(wrapper), "SVRLiquidationWrapper");
        vm.label(address(mockLiquidator), "MockListaLiquidator");
        vm.label(bundlerNOP, "BundlerNOP");
        vm.label(userOpSigner, "UserOpSigner");
        vm.label(auctioneer, "Auctioneer");
        vm.label(solverEOA, "SolverEOA");
    }

    /// @notice Full SVR metacall test: oracle update + ListaDAO liquidation in one atomic tx.
    ///
    /// This mirrors the production flow where a Chainlink NOP submits an Atlas metacall
    /// containing both the SVR oracle price update and the searcher's liquidation.
    ///
    /// Flow:
    ///   1. NOP (bundlerNOP) submits atlas.metacall(userOp, solverOps, dAppOp)
    ///   2. _preOpsCall validates bundler whitelist, oracle whitelist, selector, signer
    ///   3. UserOp executes: DAppControl.update() → Executor → Oracle.forward() (price update)
    ///   4. SolverOp executes: SVRListaSolver.executeLiquidation()
    ///        → SVRLiquidationWrapper.liquidate()
    ///        → MockListaLiquidator.liquidate() (token flow)
    ///   5. _allocateValueCall distributes OEV to Fastlane, builder, protocol
    function test_svrMetacallOracleUpdateAndLiquidation() public {
        // ============================================ //
        //       Deploy solver and configure wrapper    //
        // ============================================ //
        vm.startPrank(solverEOA);
        listaSolver = new SVRListaSolver(address(weth), address(atlas), address(wrapper));
        atlas.bond(1e18);
        vm.stopPrank();

        // Approve bundlerNOP as approved NOP
        wrapper.addApprovedNOP(bundlerNOP);

        // Fund tokens
        loanToken.mint(address(listaSolver), 1000e18);
        collateralToken.mint(address(mockLiquidator), 1000e18);

        // Solver pre-approves wrapper to pull loan tokens during callback
        vm.prank(address(listaSolver));
        loanToken.approve(address(wrapper), type(uint256).max);

        // ============================================ //
        //           Build UserOperation               //
        // ============================================ //
        // The userOp calls DAppControl.update(oracle, callData) which
        // forwards through the Executor to update the oracle price.
        bytes memory oracleCallData = abi.encodeCall(
            MockOracle.forward,
            (address(0), abi.encode(uint256(42))) // Update price to 42
        );
        bytes memory userOpData = abi.encodeCall(
            ChainlinkSvrDAppControl.update,
            (address(mockOracle), oracleCallData)
        );

        UserOperation memory userOp = UserOperation({
            from: userOpSigner,
            to: address(atlas),
            value: 0,
            gas: 1_200_000,
            maxFeePerGas: 1e9,
            nonce: 1,
            deadline: block.number + 100,
            dapp: address(dappControl),
            control: address(dappControl),
            callConfig: dappControl.CALL_CONFIG(),
            dappGasLimit: dappControl.getDAppGasLimit(),
            solverGasLimit: dappControl.getSolverGasLimit(),
            bundlerSurchargeRate: dappControl.getBundlerSurchargeRate(),
            sessionKey: address(0),
            data: userOpData,
            signature: new bytes(0)
        });

        // Sign userOp with the authorized signer's private key
        (sig.v, sig.r, sig.s) = vm.sign(userOpSignerPK, atlasVerification.getUserOperationPayload(userOp));
        userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // ============================================ //
        //          Build SolverOperation              //
        // ============================================ //
        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);

        bytes memory solverOpData = abi.encodeWithSelector(
            SVRListaSolver.executeLiquidation.selector,
            defaultMarketParams,
            address(0), // borrower
            seizedAssets,
            uint256(0), // repaidShares
            "" // callback data
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = SolverOperation({
            from: solverEOA,
            to: address(atlas),
            value: 0,
            gas: 6_000_000,
            maxFeePerGas: 1e9,
            deadline: block.number + 100,
            solver: address(listaSolver),
            control: address(dappControl),
            userOpHash: userOpHash,
            bidToken: address(0),
            bidAmount: 0, // Zero bid — no OEV payment in this POC
            data: solverOpData,
            signature: new bytes(0)
        });

        // Sign solver operation
        (sig.v, sig.r, sig.s) = vm.sign(solverPK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // ============================================ //
        //          Build DAppOperation                //
        // ============================================ //
        // verifyCallChainHash is true — must include correct callChainHash
        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);

        DAppOperation memory dAppOp = DAppOperation({
            from: auctioneer,
            to: address(atlas),
            nonce: 0,
            deadline: block.number + 100,
            control: address(dappControl),
            bundler: bundlerNOP,
            userOpHash: userOpHash,
            callChainHash: callChainHash,
            signature: new bytes(0)
        });

        // Sign DApp operation with auctioneer key
        (sig.v, sig.r, sig.s) = vm.sign(auctioneerPK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // ============================================ //
        //        Record balances & execute            //
        // ============================================ //
        uint256 solverCollBefore = collateralToken.balanceOf(address(listaSolver));
        uint256 solverLoanBefore = loanToken.balanceOf(address(listaSolver));
        uint256 liquidatorCollBefore = collateralToken.balanceOf(address(mockLiquidator));
        uint256 oraclePriceBefore = mockOracle.price();

        vm.txGasPrice(1e9);

        // NOP submits the metacall (msg.sender = bundlerNOP, tx.origin = bundlerNOP)
        vm.prank(bundlerNOP, bundlerNOP);
        atlas.metacall{ gas: 8_000_000 }({
            userOp: userOp,
            solverOps: solverOps,
            dAppOp: dAppOp,
            gasRefundBeneficiary: address(0)
        });

        // ============================================ //
        //                Assertions                   //
        // ============================================ //

        // 1. Oracle price was updated (SVR oracle update succeeded)
        assertEq(mockOracle.price(), 42, "Oracle price should be updated to 42");
        assertTrue(mockOracle.price() != oraclePriceBefore, "Oracle price should have changed");

        // 2. Collateral moved: Liquidator → Solver
        uint256 expectedRepaid = seizedAssets / 2;

        assertEq(
            collateralToken.balanceOf(address(mockLiquidator)),
            liquidatorCollBefore - seizedAssets,
            "Liquidator should have lost collateral"
        );
        assertEq(
            collateralToken.balanceOf(address(listaSolver)),
            solverCollBefore + seizedAssets,
            "Solver should have gained collateral"
        );

        // 3. Loan tokens moved: Solver → Liquidator
        assertEq(
            loanToken.balanceOf(address(listaSolver)),
            solverLoanBefore - expectedRepaid,
            "Solver should have spent loan tokens"
        );
        assertEq(
            loanToken.balanceOf(address(mockLiquidator)),
            expectedRepaid,
            "Liquidator should have received loan repayment"
        );

        // 4. Wrapper is clean — no residual tokens
        assertEq(loanToken.balanceOf(address(wrapper)), 0, "Wrapper loan balance should be 0");
        assertEq(collateralToken.balanceOf(address(wrapper)), 0, "Wrapper collateral balance should be 0");

        console.log("=== SVR Metacall Liquidation Successful ===");
        console.log("Oracle price updated:", oraclePriceBefore, "->", mockOracle.price());
        console.log("Seized collateral:", seizedAssets);
        console.log("Repaid loan tokens:", expectedRepaid);
    }

    /// @notice Test that an unauthorized bundler is rejected by _preOpsCall
    function test_svrRejectsUnauthorizedBundler() public {
        // Deploy solver
        vm.startPrank(solverEOA);
        listaSolver = new SVRListaSolver(address(weth), address(atlas), address(wrapper));
        atlas.bond(1e18);
        vm.stopPrank();

        wrapper.addApprovedNOP(bundlerNOP);

        loanToken.mint(address(listaSolver), 1000e18);
        collateralToken.mint(address(mockLiquidator), 1000e18);
        vm.prank(address(listaSolver));
        loanToken.approve(address(wrapper), type(uint256).max);

        // Build operations (same as above)
        bytes memory oracleCallData = abi.encodeCall(
            MockOracle.forward,
            (address(0), abi.encode(uint256(99)))
        );
        bytes memory userOpData = abi.encodeCall(
            ChainlinkSvrDAppControl.update,
            (address(mockOracle), oracleCallData)
        );

        UserOperation memory userOp = UserOperation({
            from: userOpSigner,
            to: address(atlas),
            value: 0,
            gas: 1_200_000,
            maxFeePerGas: 1e9,
            nonce: 1,
            deadline: block.number + 100,
            dapp: address(dappControl),
            control: address(dappControl),
            callConfig: dappControl.CALL_CONFIG(),
            dappGasLimit: dappControl.getDAppGasLimit(),
            solverGasLimit: dappControl.getSolverGasLimit(),
            bundlerSurchargeRate: dappControl.getBundlerSurchargeRate(),
            sessionKey: address(0),
            data: userOpData,
            signature: new bytes(0)
        });

        (sig.v, sig.r, sig.s) = vm.sign(userOpSignerPK, atlasVerification.getUserOperationPayload(userOp));
        userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        bytes32 userOpHash = atlasVerification.getUserOperationHash(userOp);
        bytes memory solverOpData = abi.encodeWithSelector(
            SVRListaSolver.executeLiquidation.selector,
            defaultMarketParams, address(0), seizedAssets, uint256(0), ""
        );

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = SolverOperation({
            from: solverEOA,
            to: address(atlas),
            value: 0,
            gas: 6_000_000,
            maxFeePerGas: 1e9,
            deadline: block.number + 100,
            solver: address(listaSolver),
            control: address(dappControl),
            userOpHash: userOpHash,
            bidToken: address(0),
            bidAmount: 0,
            data: solverOpData,
            signature: new bytes(0)
        });

        (sig.v, sig.r, sig.s) = vm.sign(solverPK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Use UNAUTHORIZED bundler address in DAppOp
        address unauthorizedBundler = makeAddr("unauthorizedBundler");
        vm.deal(unauthorizedBundler, 10e18);

        bytes32 callChainHash = CallVerification.getCallChainHash(userOp, solverOps);
        DAppOperation memory dAppOp = DAppOperation({
            from: auctioneer,
            to: address(atlas),
            nonce: 0,
            deadline: block.number + 100,
            control: address(dappControl),
            bundler: unauthorizedBundler,
            userOpHash: userOpHash,
            callChainHash: callChainHash,
            signature: new bytes(0)
        });

        (sig.v, sig.r, sig.s) = vm.sign(auctioneerPK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        vm.txGasPrice(1e9);

        // Metacall from unauthorized bundler should revert (PreOpsFail due to BundlerIsNotAuthorizedSender)
        vm.prank(unauthorizedBundler, unauthorizedBundler);
        vm.expectRevert();
        atlas.metacall{ gas: 8_000_000 }(userOp, solverOps, dAppOp, address(0));

        // Oracle price should be unchanged
        assertEq(mockOracle.price(), 100, "Oracle price should not have changed");
    }
}
