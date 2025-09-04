// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    // CORREÇÃO: Copie exatamente igual ao DSCEngine.sol
    event CollateralRedeemed(
        address indexed redeemedFrom,
        address indexed redeemedTo,
        address indexed token,
        uint256 amount
    );
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address weth;
    address wbtc;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address public user = address(1);
    uint256 amountCollateral = 10 ether;
    uint256 constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether; // 10 * 10^18
    uint256 public amountToMint = 100 ether;
    uint256 public deployerKey;

    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();

        // CORREÇÃO DEFINITIVA: Não desempacote, acesse individualmente
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = config
            .activeNetworkConfig();

        ERC20Mock(weth).mint(user, STARTING_ERC20_BALANCE);
    }

    ////////////////////////
    // Constructor Tests  //
    ////////////////////////

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        address[] memory tokenAddresses = new address[](1);
        address[] memory priceFeedAddresses = new address[](2);

        tokenAddresses[0] = weth;
        priceFeedAddresses[0] = ethUsdPriceFeed;
        priceFeedAddresses[1] = btcUsdPriceFeed;

        vm.expectRevert(
            DSCEngine
                .DSCEngine__TokenAddressAndPriceFeedAddressMustBeSameLength
                .selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////////
    // Price Feed Tests //
    //////////////////////

    function testGetUsdValue() external {
        uint256 ethAmount = 15e18;
        // 15 ETH * $2000/ETH = $30,000
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedTokenAmount = 0.05 ether;
        uint256 actualTokenAmount = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedTokenAmount, actualTokenAmount);
    }

    /////////////////////////////
    // depositCollateralTests  //
    /////////////////////////////

    function testRevertsIfCollateralIsZero() public {
        vm.prank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnnaprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAND", "RAND", user, 1000e18);
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__NotAllowedToken.selector,
                address(randToken)
            )
        );
        dsce.depositCollateral(address(randToken), amountCollateral);
        vm.stopPrank();
    }

    function testCanDepositCollateralWithoutMint() public depositedCollateral {
        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ////////////////////
    // Minting Tests  //
    ////////////////////

    function testRevertIfMintAmountIsZero() public {
        vm.startPrank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        vm.prank(user);
        dsce.mintDsc(amountToMint);

        uint256 userBalance = dsc.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////
    // Burning Tests //
    ///////////////////

    function testCanBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(user);
        uint256 userBalanceBefore = dsc.balanceOf(user);
        assertEq(userBalanceBefore, amountToMint);

        dsc.approve(address(dsce), amountToMint);
        dsce.burnDsc(amountToMint);

        uint256 userBalanceAfter = dsc.balanceOf(user);
        assertEq(userBalanceAfter, 0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor()
        public
        depositedCollateral
    {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        amountToMint =
            (amountCollateral *
                (uint256(price) * dsce.getAdditionalFeedPrecision())) /
            dsce.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(
            amountToMint,
            dsce.getUsdValue(weth, amountCollateral)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor
            )
        );
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // depositCollateralAndMintDsc   //
    ///////////////////////////////////

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed)
            .latestRoundData();
        amountToMint =
            (amountCollateral*
                (uint256(price) * dsce.getAdditionalFeedPrecision())) /
            dsce.getPrecision();
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);

        uint256 expectedHealthFactor = dsce.calculateHealthFactor(
            amountToMint,
            dsce.getUsdValue(weth, amountCollateral)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__BreaksHealthFactor.selector,
                expectedHealthFactor
            )
        );
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    //////////////////////////////
    // Account Information Tests //
    //////////////////////////////

    function testCanDepositedCollateralAndGetAccountInfo()
        public
        depositedCollateralAndMintedDsc
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce
            .getAccountInformation(user);
        assertEq(totalDscMinted, amountToMint);
        assertEq(
            collateralValueInUsd,
            dsce.getUsdValue(weth, amountCollateral)
        );
    }

    //////////////////////////////
    // Reedem Collateral Tests  //
    //////////////////////////////

    function testRevertsIfRedeemAmountIsZero()
        public
        depositedCollateralAndMintedDsc
    {
        vm.prank(user);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        uint256 userBalanceBefore = ERC20Mock(weth).balanceOf(user);
        assertEq(userBalanceBefore, STARTING_ERC20_BALANCE - amountCollateral);

        dsce.redeemCollateral(weth, amountCollateral);

        uint256 userBalanceAfter = ERC20Mock(weth).balanceOf(user);
        assertEq(userBalanceAfter, STARTING_ERC20_BALANCE);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs()
        public
        depositedCollateral
    {
        vm.expectEmit(true, true, true, true, address(dsce));
        emit CollateralRedeemed(user, user, weth, amountCollateral);
        vm.startPrank(user);
        dsce.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral , amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = ERC20Mock(weth).balanceOf(user);
        assertEq(userBalance, STARTING_ERC20_BALANCE);

        uint256 userDscBalance = dsc.balanceOf(user);
        assertEq(userDscBalance, 0);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce
            .getAccountInformation(user);
        assertEq(totalDscMinted, 0);
        assertEq(collateralValueInUsd, 0);
    }

    ///////////////////////////
    // Health Factor Tests   //
    ///////////////////////////

    function testProperlyReportsHealthFactor()
        public
        depositedCollateralAndMintedDsc
    {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce
            .getAccountInformation(user);
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(
            totalDscMinted,
            collateralValueInUsd
        );
        uint256 actualHealthFactor = dsce.getHealthFactor(user);
        assertEq(expectedHealthFactor, actualHealthFactor);
    }

    function testHealthFactorCanGoBelowOne()
        public
        depositedCollateralAndMintedDsc
    {
        int256 newPrice = 18e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(newPrice);

        uint256 userHealthFactor = dsce.getHealthFactor(user);

        assert(userHealthFactor < 1 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    function testCantLiquidateGoodHealthFactor()
        public
        depositedCollateralAndMintedDsc
    {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        dsce.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dsce.getHealthFactor(user);
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);
        dsce.liquidate(weth, user, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }


    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint)
            + (dsce.getTokenAmountFromUsd(weth, amountToMint) * dsce.getLiquidationBonus() / dsce.getLiquidationPrecision());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, amountToMint) +
        (dsce.getTokenAmountFromUsd(weth,amountToMint) * dsce.getLiquidationBonus() / dsce.getLiquidationPrecision());
        uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);
        uint256 expectedCollateralValueInUsd = dsce.getUsdValue(weth, amountCollateral) - usdAmountLiquidated;

        (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(user);
        uint256 hardCodedExpected = 70_000_000_000_000_000_020; // $114
        assertEq(userCollateralValueInUsd, expectedCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpected);
    }

    function testLiquidatorTakesOnUserDebit () public liquidated{
        (uint256 totalDscMinted, ) = dsce.getAccountInformation(liquidator);
        assertEq(totalDscMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated{
        (uint256 totalDscMinted, ) = dsce.getAccountInformation(user);
        assertEq(totalDscMinted, 0);
    }
    
}
