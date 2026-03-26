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
    address nonSolver = makeAddr("nonSolver");
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

        // Setup: owner approves solver and NOP
        vm.startPrank(owner);
        wrapper.addApprovedSolver(solver);
        wrapper.addApprovedNOP(nop);
        vm.stopPrank();

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

    function test_addApprovedSolver() public {
        address newSolver = makeAddr("newSolver");
        assertFalse(wrapper.approvedSolvers(newSolver));

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit SVRLiquidationWrapper.SolverAdded(newSolver);
        wrapper.addApprovedSolver(newSolver);

        assertTrue(wrapper.approvedSolvers(newSolver));
    }

    function test_removeApprovedSolver() public {
        assertTrue(wrapper.approvedSolvers(solver));

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit SVRLiquidationWrapper.SolverRemoved(solver);
        wrapper.removeApprovedSolver(solver);

        assertFalse(wrapper.approvedSolvers(solver));
    }

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

    function test_onlyOwnerCanAddSolver() public {
        vm.prank(nonSolver);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonSolver));
        wrapper.addApprovedSolver(nonSolver);
    }

    function test_onlyOwnerCanAddNOP() public {
        vm.prank(nonSolver);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonSolver));
        wrapper.addApprovedNOP(nonSolver);
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

    function test_rejectsNonApprovedSolver() public {
        vm.prank(nonSolver, nop); // msg.sender = nonSolver, tx.origin = nop
        vm.expectRevert(SVRLiquidationWrapper.NotApprovedSolver.selector);
        wrapper.liquidate(defaultMarketParams, borrower, 100e18, 0, "");
    }

    function test_rejectsNonApprovedNOP() public {
        vm.prank(solver, nonNOP); // msg.sender = solver, tx.origin = nonNOP
        vm.expectRevert(SVRLiquidationWrapper.NotApprovedNOP.selector);
        wrapper.liquidate(defaultMarketParams, borrower, 100e18, 0, "");
    }

    function test_rejectsBothInvalid() public {
        vm.prank(nonSolver, nonNOP);
        vm.expectRevert(SVRLiquidationWrapper.NotApprovedSolver.selector);
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
        vm.prank(nonSolver);
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
//     Integration Tests (with Atlas doMetacall)      //
// ================================================== //

import { TxBuilder } from "atlas/helpers/TxBuilder.sol";
import { SolverOperation } from "atlas/types/SolverOperation.sol";
import { UserOperation } from "atlas/types/UserOperation.sol";
import { DAppConfig } from "atlas/types/ConfigTypes.sol";
import "atlas/types/DAppOperation.sol";
import { DAppControl } from "atlas/dapp/DAppControl.sol";
import { CallConfig } from "atlas/types/ConfigTypes.sol";
import { Atlas } from "atlas/atlas/Atlas.sol";
import { AtlasVerification } from "atlas/atlas/AtlasVerification.sol";
import { ExecutionEnvironment } from "atlas/common/ExecutionEnvironment.sol";
import { FactoryLib } from "atlas/atlas/FactoryLib.sol";
import { Sorter } from "atlas/helpers/Sorter.sol";

/// @notice Mock WETH for non-fork testing
contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 wad) external { _burn(msg.sender, wad); payable(msg.sender).transfer(wad); }
    receive() external payable { _mint(msg.sender, msg.value); }
}

/// @notice Minimal DAppControl for testing the wrapper flow in Atlas.
contract TestDAppControl is DAppControl {
    constructor(address _atlas) DAppControl(
        _atlas,
        msg.sender,
        CallConfig({
            userNoncesSequential: false,
            dappNoncesSequential: false,
            requirePreOps: false,
            trackPreOpsReturnData: false,
            trackUserReturnData: false,
            delegateUser: false,
            requirePreSolver: false,
            requirePostSolver: false,
            zeroSolvers: false,
            reuseUserOp: false,
            userAuctioneer: false,
            solverAuctioneer: false,
            unknownAuctioneer: false,
            verifyCallChainHash: false,
            forwardReturnData: false,
            requireFulfillment: false,
            trustedOpHash: false,
            invertBidValue: false,
            exPostBids: false,
            multipleSuccessfulSolvers: false,
            checkMetacallGasLimit: false
        })
    ) {}

    function getBidFormat(UserOperation calldata) public pure override returns (address) {
        return address(0); // ETH bids
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }

    function _allocateValueCall(bool, address, uint256, bytes calldata) internal virtual override {}

    /// @notice No-op function that the userOp calls to simulate an oracle update
    function noOp() external {}
}

/// @notice Simulator stub - Atlas needs a simulator address but we don't use simulation in tests
contract MockSimulator {
    address public atlas;
    function setAtlas(address _atlas) external { atlas = _atlas; }
}

contract SVRLiquidationWrapperIntegrationTest is Test {
    struct Sig { uint8 v; bytes32 r; bytes32 s; }

    // Atlas infrastructure
    Atlas public atlas;
    AtlasVerification public atlasVerification;

    MockListaLiquidator public mockLiquidator;
    SVRLiquidationWrapper public wrapper;
    SVRListaSolver public listaSolver;
    TestDAppControl public testDAppControl;
    TxBuilder public txBuilder;
    Sig public sig;

    MockERC20 public loanToken;
    MockERC20 public collateralToken;
    MockWETH public weth;

    address deployer = makeAddr("Deployer");

    uint256 governancePK;
    address governanceEOA;
    uint256 userPK;
    address userEOA;
    uint256 solverOnePK;
    address solverOneEOA;

    address dAppGovEOA;
    address executionEnvironment;

    MarketParams defaultMarketParams;
    uint256 seizedAssets = 100e18;

    function setUp() public {
        // Create accounts
        (userEOA, userPK) = makeAddrAndKey("userEOA");
        (governanceEOA, governancePK) = makeAddrAndKey("govEOA");
        (solverOneEOA, solverOnePK) = makeAddrAndKey("solverOneEOA");
        dAppGovEOA = makeAddr("dAppGov");

        vm.deal(solverOneEOA, 100e18);
        vm.deal(deployer, 100e18);

        // Deploy mock tokens
        weth = new MockWETH();
        loanToken = new MockERC20("Loan Token", "LOAN");
        collateralToken = new MockERC20("Collateral Token", "COLL");

        // Deploy Atlas infrastructure (mirrors BaseTest.__deployAtlasContracts)
        vm.startPrank(deployer);

        MockSimulator simulator = new MockSimulator();

        address expectedAtlasAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 2);
        address expectedAtlasVerificationAddr = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 3);

        ExecutionEnvironment execEnvTemplate = new ExecutionEnvironment(expectedAtlasAddr);

        // Deploy FactoryLib from precompiled artifact
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

        // Fund solver and deposit in Atlas
        vm.startPrank(solverOneEOA);
        atlas.deposit{ value: 1e18 }();
        vm.stopPrank();

        // Deploy mock liquidator
        mockLiquidator = new MockListaLiquidator();

        // Deploy DAppControl and register governance signatory
        vm.startPrank(dAppGovEOA);
        testDAppControl = new TestDAppControl(address(atlas));
        atlasVerification.initializeGovernance(address(testDAppControl));
        // Add our governanceEOA as a signatory for signing dAppOps
        atlasVerification.addSignatory(address(testDAppControl), governanceEOA);
        vm.stopPrank();

        // Create execution environment
        vm.prank(userEOA);
        executionEnvironment = atlas.createExecutionEnvironment(userEOA, address(testDAppControl));

        // Deploy wrapper
        wrapper = new SVRLiquidationWrapper(address(mockLiquidator), address(this));
        mockLiquidator.setApprovedCaller(address(wrapper));

        defaultMarketParams = MarketParams({
            loanToken: address(loanToken),
            collateralToken: address(collateralToken),
            oracle: address(0),
            irm: address(0),
            lltv: 8000
        });

        txBuilder = new TxBuilder({
            _control: address(testDAppControl),
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });

        vm.label(address(atlas), "Atlas");
        vm.label(address(atlasVerification), "AtlasVerification");
        vm.label(address(wrapper), "SVRLiquidationWrapper");
        vm.label(address(mockLiquidator), "MockListaLiquidator");
    }

    function test_atlasMetacallLiquidation() public {
        UserOperation memory userOp;
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        DAppOperation memory dAppOp;

        // Deploy solver as solverOneEOA
        vm.startPrank(solverOneEOA);
        listaSolver = new SVRListaSolver(address(weth), address(atlas), address(wrapper));
        atlas.bond(1e18);
        vm.stopPrank();

        // Approve the solver and the NOP (userEOA acts as Chainlink NOP here)
        wrapper.addApprovedSolver(address(listaSolver));
        wrapper.addApprovedNOP(userEOA);

        // Fund: give solver loan tokens for repayment, give liquidator collateral
        loanToken.mint(address(listaSolver), 1000e18);
        collateralToken.mint(address(mockLiquidator), 1000e18);

        // Solver approves wrapper to pull loan tokens during callback
        vm.prank(address(listaSolver));
        loanToken.approve(address(wrapper), type(uint256).max);

        // Build UserOperation (no-op for POC - in prod this would be SVR oracle update)
        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: address(testDAppControl),
            maxFeePerGas: block.basefee + 1e9,
            value: 0,
            deadline: block.number + 2,
            data: abi.encodeWithSelector(TestDAppControl.noOp.selector)
        });
        userOp.sessionKey = governanceEOA;

        // Build SolverOperation - encodes the liquidation call
        bytes memory solverOpData = abi.encodeWithSelector(
            SVRListaSolver.executeLiquidation.selector,
            defaultMarketParams,
            address(0), // borrower
            seizedAssets,
            uint256(0), // repaidShares
            "" // callback data
        );

        solverOps[0] = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: solverOpData,
            solver: solverOneEOA,
            solverContract: address(listaSolver),
            bidAmount: 0, // Zero bid for POC - no ETH payment needed
            value: 0
        });

        // Sign solver operation
        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Build and sign DApp operation
        dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Record balances before
        uint256 solverCollBefore = collateralToken.balanceOf(address(listaSolver));
        uint256 solverLoanBefore = loanToken.balanceOf(address(listaSolver));
        uint256 liquidatorCollBefore = collateralToken.balanceOf(address(mockLiquidator));

        // Set tx.gasprice to avoid division by zero in Atlas gas accounting
        vm.txGasPrice(1e9);

        // Execute metacall as the NOP (userEOA is both msg.sender and tx.origin)
        vm.prank(userEOA, userEOA);
        atlas.metacall{ gas: 5_000_000 }({
            userOp: userOp,
            solverOps: solverOps,
            dAppOp: dAppOp,
            gasRefundBeneficiary: address(0)
        });

        uint256 expectedRepaid = seizedAssets / 2;

        // Check collateral moved from liquidator to solver
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

        // Check loan tokens moved from solver to liquidator
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

        // Wrapper should be clean
        assertEq(loanToken.balanceOf(address(wrapper)), 0, "Wrapper loan balance should be 0");
        assertEq(collateralToken.balanceOf(address(wrapper)), 0, "Wrapper collateral balance should be 0");

        console.log("Atlas metacall liquidation successful!");
        console.log("Seized collateral:", seizedAssets);
        console.log("Repaid loan tokens:", expectedRepaid);
    }
}
