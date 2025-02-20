// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Test, console} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address weth;
    address wbtc;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    // actually 100 DSC, ether writes it in a 18 decimal value because DSC follows the same decimal standard as ETH.
    uint256 public constant AMOUNT_TO_MINT = 100 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesNotMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////
    // Price Tests //
    /////////////////

    function testGetUsdValue() public view {
        // 15e18 * 2,000/ETH = 30,000e18
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmounrFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $2,000 / ETH, $100
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        // NOTE: In the expectRevert, if errors have parameters, we need to use abi.encodeWithSelector
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__TokenNotAllowed.selector, ranToken));
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testDepositCollateralEmitsEvent() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectEmit(true, true, true, true, address(dsce));
        emit CollateralDeposited(USER, weth, AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    function testDepositCollateralTransfersFromUserToContract() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        // Step 1: Record balances before deposit
        uint256 contractBalanceBefore = ERC20Mock(weth).balanceOf(address(dsce));
        uint256 userBalanceBefore = ERC20Mock(weth).balanceOf(USER);

        // Step 2: Deposit collateral
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Step 3: Record balances after deposit
        uint256 contractBalanceAfter = ERC20Mock(weth).balanceOf(address(dsce));
        uint256 userBalanceAfter = ERC20Mock(weth).balanceOf(USER);

        // Step 4: Check contract received the correct amount
        assertEq(contractBalanceAfter, contractBalanceBefore + AMOUNT_COLLATERAL, "Contract balance should increase");

        // Step 5: Check user's balance decreased by the correct amount
        assertEq(userBalanceAfter, userBalanceBefore - AMOUNT_COLLATERAL, "User balance should decrease");

        vm.stopPrank();
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();

        // calculates the max aamount of DSC our user can mint with their collateral
        uint256 amountToMint =
            (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));

        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_TO_MINT);
    }

    ///////////////////////////////////
    // mintDsc Tests                 //
    ///////////////////////////////////

    function testMintDscRevertsIfAmountIsZero() public {
        // Arrange: Deposit collateral first
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Act & Assert: Try to mint 0 DSC and expect revert
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);

        vm.stopPrank();
    }

    // confirms that the internal state of the dsce has been updated
    function testMintDscUpdatesDSCMinted() public {
        // Arrange: Deposit collateral first
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Act: Mint DSC
        dsce.mintDsc(AMOUNT_TO_MINT);

        // Assert: Check if s_DSCMinted is updated
        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, AMOUNT_TO_MINT, "s_DSCMinted should be equal to the amount minted");

        vm.stopPrank();
    }

    function testMintDscRevertsIfHealthFactorBroken() public {
        // Arrange: Deposit Collateral
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Calculate Unsafe Mint Amount
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        // This amount will break the health factor
        uint256 unsafeAmountToMint =
            ((AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision()) + 1;

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(unsafeAmountToMint, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));

        // Act & Assert: Expect Health Factor to Break and Revert
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(unsafeAmountToMint);

        vm.stopPrank();
    }

    function testMintDscUpdatesUserBalance() public {
        // Arrange: Deposit Collateral
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // Act: Mint DSC
        dsce.mintDsc(AMOUNT_TO_MINT);

        // Assert: Check if the user balance is equal to the minted amount
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_TO_MINT, "User balance should be equal to the minted amount");

        vm.stopPrank();
    }

    ///////////////////////////////////
    // burnDsc Tests                 //
    ///////////////////////////////////

    modifier mintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        _;
        vm.stopPrank();
    }

    function testBurnDscRevertsIfAmountIsZero() public mintedDsc {
        // Act & Assert: Try to burn 0 DSC and expect revert
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
    }

    function testBurnDscUpdatesDSCMinted() public mintedDsc {
        // Confirm initial DSC minted
        (uint256 totalDscMintedBefore,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMintedBefore, AMOUNT_TO_MINT, "Initial DSC minted should be equal to the amount minted");

        // User needs to approve DSCEngine to spend DSC before burning
        dsc.approve(address(dsce), AMOUNT_TO_MINT);

        // Act: Burn half of the minted DSC
        uint256 amountToBurn = AMOUNT_TO_MINT / 2;
        dsce.burnDsc(amountToBurn);

        // Assert: Check if s_DSCMinted is reduced by the burned amount
        (uint256 totalDscMintedAfter,) = dsce.getAccountInformation(USER);
        uint256 expectedRemainingDsc = AMOUNT_TO_MINT - amountToBurn;
        assertEq(totalDscMintedAfter, expectedRemainingDsc, "s_DSCMinted should be reduced by the burned amount");
    }

    function testBurnDscUpdatesBalances() public mintedDsc {
        // Arrange: Approve DSCEngine to spend DSC
        dsc.approve(address(dsce), AMOUNT_TO_MINT);

        // Record initial balances
        uint256 userBalanceBefore = dsc.balanceOf(USER);
        uint256 contractBalanceBefore = dsc.balanceOf(address(dsce));

        // Act: Burn half of the minted DSC
        uint256 amountToBurn = AMOUNT_TO_MINT / 2;
        dsce.burnDsc(amountToBurn);

        // Assert: Check User Balance
        uint256 userBalanceAfter = dsc.balanceOf(USER);
        uint256 expectedUserBalance = userBalanceBefore - amountToBurn;
        assertEq(userBalanceAfter, expectedUserBalance, "User balance should be reduced by the burned amount");

        // Assert: Check Contract Balance
        uint256 contractBalanceAfter = dsc.balanceOf(address(dsce));
        assertEq(contractBalanceAfter, contractBalanceBefore, "Contract balance should remain unchanged after burning");
    }

    function testBurnDscFullAmount() public mintedDsc {
        // Arrange: Approve DSCEngine to spend the full amount of DSC
        dsc.approve(address(dsce), AMOUNT_TO_MINT);

        // Confirm initial DSC minted
        (uint256 totalDscMintedBefore,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMintedBefore, AMOUNT_TO_MINT, "Initial DSC minted should be equal to the amount minted");

        // Act: Burn the full amount of DSC
        dsce.burnDsc(AMOUNT_TO_MINT);

        // Assert: Check User Balance is Zero
        uint256 userBalanceAfter = dsc.balanceOf(USER);
        assertEq(userBalanceAfter, 0, "User balance should be zero after burning full amount");

        // Assert: Check s_DSCMinted is Zero
        (uint256 totalDscMintedAfter,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMintedAfter, 0, "s_DSCMinted should be zero after burning full amount");
    }

    /////////////////////////////
    // redeemCollateral Tests  //
    /////////////////////////////

    function testRedeemCollateralRevertsIfZeroAmount() public mintedDsc {
        // Act & Assert: Expect revert when redeeming zero collateral
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
    }

    function testRedeemCollateralUpdatesUserBalance() public mintedDsc {
        // Arrange: Get initial balance
        uint256 initialBalance = dsce.getCollateralBalanceOfUser(USER, weth);

        // Act: Redeem collateral
        uint256 amountToWithdraw = (AMOUNT_COLLATERAL * 50) / 100; // Withdraw 50% of collateral
        dsce.redeemCollateral(weth, amountToWithdraw);

        // Assert: Check balance after redemption
        uint256 finalBalance = dsce.getCollateralBalanceOfUser(USER, weth);
        uint256 expectedBalance = initialBalance - amountToWithdraw;
        assertEq(finalBalance, expectedBalance, "User's collateral balance should be reduced by the redeemed amount");
    }

    function testRedeemCollateralTransfersToUser() public mintedDsc {
        // Arrange: Get initial balances
        uint256 initialUserBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 initialContractBalance = ERC20Mock(weth).balanceOf(address(dsce));

        // Act: Redeem collateral
        uint256 amountToWithdraw = (AMOUNT_COLLATERAL * 50) / 100; // Withdraw 50% of collateral
        dsce.redeemCollateral(weth, amountToWithdraw);

        // Assert: Check balances after redemption
        uint256 finalUserBalance = ERC20Mock(weth).balanceOf(USER);
        uint256 finalContractBalance = ERC20Mock(weth).balanceOf(address(dsce));

        assertEq(
            finalUserBalance, initialUserBalance + amountToWithdraw, "User's balance should increase by redeemed amount"
        );
        assertEq(
            finalContractBalance,
            initialContractBalance - amountToWithdraw,
            "Contract balance should decrease by redeemed amount"
        );
    }

    function testRedeemCollateralEmitsEvent() public mintedDsc {
        // Act & Assert: Expect CollateralRedeemed event to be emitted
        uint256 amountToWithdraw = (AMOUNT_COLLATERAL * 50) / 100;
        vm.expectEmit(true, true, true, true, address(dsce));
        emit CollateralRedeemed(USER, USER, weth, amountToWithdraw);
        dsce.redeemCollateral(weth, amountToWithdraw);
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        dsc.approve(address(dsce), AMOUNT_TO_MINT);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    // ////////////////////////
    // // healthFactor Tests //
    // ////////////////////////

    // function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDsc {
    //     uint256 expectedHealthFactor = 100 ether;
    //     uint256 healthFactor = dsce.getHealthFactor(user);
    //     // $100 minted with $20,000 collateral at 50% liquidation threshold
    //     // means that we must have $200 collatareral at all times.
    //     // 20,000 * 0.5 = 10,000
    //     // 10,000 / 100 = 100 health factor
    //     assertEq(healthFactor, expectedHealthFactor);
    // }

    // function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDsc {
    //     int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
    //     // Remember, we need $200 at all times if we have $100 of debt

    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

    //     uint256 userHealthFactor = dsce.getHealthFactor(user);
    //     // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
    //     // 0.9
    //     assert(userHealthFactor == 0.9 ether);
    // }

    // ///////////////////////
    // // Liquidation Tests //
    // ///////////////////////

    // // This test needs it's own setup
    // function testMustImproveHealthFactorOnLiquidation() public {
    //     // Arrange - Setup
    //     MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
    //     tokenAddresses = [weth];
    //     feedAddresses = [ethUsdPriceFeed];
    //     address owner = msg.sender;
    //     vm.prank(owner);
    //     DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));
    //     mockDsc.transferOwnership(address(mockDsce));
    //     // Arrange - User
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(mockDsce), amountCollateral);
    //     mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
    //     vm.stopPrank();

    //     // Arrange - Liquidator
    //     collateralToCover = 1 ether;
    //     ERC20Mock(weth).mint(liquidator, collateralToCover);

    //     vm.startPrank(liquidator);
    //     ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
    //     uint256 debtToCover = 10 ether;
    //     mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
    //     mockDsc.approve(address(mockDsce), debtToCover);
    //     // Act
    //     int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
    //     // Act/Assert
    //     vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
    //     mockDsce.liquidate(weth, user, debtToCover);
    //     vm.stopPrank();
    // }

    // function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
    //     ERC20Mock(weth).mint(liquidator, collateralToCover);

    //     vm.startPrank(liquidator);
    //     ERC20Mock(weth).approve(address(dsce), collateralToCover);
    //     dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
    //     dsc.approve(address(dsce), amountToMint);

    //     vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
    //     dsce.liquidate(weth, user, amountToMint);
    //     vm.stopPrank();
    // }

    // modifier liquidated() {
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(dsce), amountCollateral);
    //     dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
    //     vm.stopPrank();
    //     int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
    //     uint256 userHealthFactor = dsce.getHealthFactor(user);

    //     ERC20Mock(weth).mint(liquidator, collateralToCover);

    //     vm.startPrank(liquidator);
    //     ERC20Mock(weth).approve(address(dsce), collateralToCover);
    //     dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
    //     dsc.approve(address(dsce), amountToMint);
    //     dsce.liquidate(weth, user, amountToMint); // We are covering their whole debt
    //     vm.stopPrank();
    //     _;
    // }

    // function testLiquidationPayoutIsCorrect() public liquidated {
    //     uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
    //     uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint)
    //         + (dsce.getTokenAmountFromUsd(weth, amountToMint) * dsce.getLiquidationBonus() / dsce.getLiquidationPrecision());
    //     uint256 hardCodedExpected = 6_111_111_111_111_111_110;
    //     assertEq(liquidatorWethBalance, hardCodedExpected);
    //     assertEq(liquidatorWethBalance, expectedWeth);
    // }

    // function testUserStillHasSomeEthAfterLiquidation() public liquidated {
    //     // Get how much WETH the user lost
    //     uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, amountToMint)
    //         + (dsce.getTokenAmountFromUsd(weth, amountToMint) * dsce.getLiquidationBonus() / dsce.getLiquidationPrecision());

    //     uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);
    //     uint256 expectedUserCollateralValueInUsd = dsce.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);

    //     (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(user);
    //     uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
    //     assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
    //     assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    // }

    // function testLiquidatorTakesOnUsersDebt() public liquidated {
    //     (uint256 liquidatorDscMinted,) = dsce.getAccountInformation(liquidator);
    //     assertEq(liquidatorDscMinted, amountToMint);
    // }

    // function testUserHasNoMoreDebt() public liquidated {
    //     (uint256 userDscMinted,) = dsce.getAccountInformation(user);
    //     assertEq(userDscMinted, 0);
    // }

    // ///////////////////////////////////
    // // View & Pure Function Tests //
    // //////////////////////////////////
    // function testGetCollateralTokenPriceFeed() public {
    //     address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
    //     assertEq(priceFeed, ethUsdPriceFeed);
    // }

    // function testGetCollateralTokens() public {
    //     address[] memory collateralTokens = dsce.getCollateralTokens();
    //     assertEq(collateralTokens[0], weth);
    // }

    // function testGetMinHealthFactor() public {
    //     uint256 minHealthFactor = dsce.getMinHealthFactor();
    //     assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    // }

    // function testGetLiquidationThreshold() public {
    //     uint256 liquidationThreshold = dsce.getLiquidationThreshold();
    //     assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    // }

    // function testGetAccountCollateralValueFromInformation() public depositedCollateral {
    //     (, uint256 collateralValue) = dsce.getAccountInformation(user);
    //     uint256 expectedCollateralValue = dsce.getUsdValue(weth, amountCollateral);
    //     assertEq(collateralValue, expectedCollateralValue);
    // }

    // function testGetCollateralBalanceOfUser() public {
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(dsce), amountCollateral);
    //     dsce.depositCollateral(weth, amountCollateral);
    //     vm.stopPrank();
    //     uint256 collateralBalance = dsce.getCollateralBalanceOfUser(user, weth);
    //     assertEq(collateralBalance, amountCollateral);
    // }

    // function testGetAccountCollateralValue() public {
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(dsce), amountCollateral);
    //     dsce.depositCollateral(weth, amountCollateral);
    //     vm.stopPrank();
    //     uint256 collateralValue = dsce.getAccountCollateralValue(user);
    //     uint256 expectedCollateralValue = dsce.getUsdValue(weth, amountCollateral);
    //     assertEq(collateralValue, expectedCollateralValue);
    // }

    // function testGetDsc() public {
    //     address dscAddress = dsce.getDsc();
    //     assertEq(dscAddress, address(dsc));
    // }

    // function testLiquidationPrecision() public {
    //     uint256 expectedLiquidationPrecision = 100;
    //     uint256 actualLiquidationPrecision = dsce.getLiquidationPrecision();
    //     assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    // }
}
