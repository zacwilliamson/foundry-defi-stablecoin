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
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(AMOUNT_TO_MINT);
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
}
