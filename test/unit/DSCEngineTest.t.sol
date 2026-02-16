// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {Test, console} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;

    address weth;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 20 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 50 ether;
    address public constant INVALID_TOKEN = address(0x123);

    /////////////
    // Modifiers
    /////////////
    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(10 ether);
        vm.stopPrank();
        _;
    }

    // setUp
    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, /* wbtc */, /* deployerKey */) =
            config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);

        console.log("DSC.owner in test:", dsc.owner());
    }

    // 1. Constructor test
    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        address[] memory tokenAddresses = new address[](2);
        address[] memory priceFeedAddresses = new address[](3);
        tokenAddresses[0] = weth;
        priceFeedAddresses[0] = ethUsdPriceFeed;

        // Your DecentralizedStableCoin has constructor(address initialOwner)
        DecentralizedStableCoin dummyDsc = new DecentralizedStableCoin(address(this));

        vm.expectRevert(
            DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch.selector
        );
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dummyDsc));
    }

    // 2. Price Tests
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30_000e18; // $2k/ETH * 15 ETH
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    // 3. Deposit Tests
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testDepositCollateral() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) =
            dsce.getAccountInformation(USER);
        uint256 expectedCollateral = 40_000e18; // 20 ETH * $2k
        assertEq(collateralValueInUsd, expectedCollateral);
        assertEq(totalDscMinted, 0);
    }

    function testDepositCollateralUpdatesAccountCollateralValue()
        public
        depositedCollateral
    {
        uint256 collateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedCollateral = 40_000e18;
        assertEq(collateralValue, expectedCollateral);
    }

    function testDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        uint256 collatAmount = 20 ether;
        uint256 dscAmount = 15 ether;
        ERC20Mock(weth).mint(USER, collatAmount);
        ERC20Mock(weth).approve(address(dsce), collatAmount);
        dsce.depositCollateralAndMintDsc(weth, collatAmount, dscAmount);
        vm.stopPrank();

        (uint256 totalDscMinted, uint256 collateralValueInUsd) =
            dsce.getAccountInformation(USER);
        assertEq(collateralValueInUsd, 40_000e18);
        assertEq(totalDscMinted, 15 ether);
    }

    // TokenNotAllowed test – no need to mint on INVALID_TOKEN
    function testRevertsIfTokenNotAllowed() public {
        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                DSCEngine.DSCEngine__TokenNotAllowed.selector,
                INVALID_TOKEN
            )
        );
        dsce.depositCollateral(INVALID_TOKEN, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    // 4. Mint/Burn Tests
    function testMintDsc() public depositedCollateral {
        vm.startPrank(USER);
        uint256 amount = 10 ether;
        dsce.mintDsc(amount);
        uint256 healthFactor = dsce.getHealthFactor(); // msg.sender = USER
        vm.stopPrank();

        assertGt(healthFactor, 1e18);
    }

    function testBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        uint256 amount = 5 ether;
        dsc.approve(address(dsce), amount);
        dsce.burnDsc(amount);
        vm.stopPrank();

        uint256 totalSupply = dsc.totalSupply();
        assertLe(totalSupply, 5 ether);
    }

    function testBurnDscRevertsZeroAmount() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), 10 ether);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testMintDscRevertsHealthFactorLow() public depositedCollateral {
        vm.startPrank(USER);
        uint256 badAmount = 1_000_000 ether; // way too much
        vm.expectRevert(); // accept any revert due to HF check
        dsce.mintDsc(badAmount);
        vm.stopPrank();
    }

    // 5. Health Factor Tests
    function testHealthFactorAboveMinWithCollateral() public depositedCollateral {
        vm.prank(USER);
        uint256 healthFactor = dsce.getHealthFactor();
        assertGt(healthFactor, 1e18);
    }

    function testGetAccountInformation() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) =
            dsce.getAccountInformation(USER);
        assertEq(collateralValueInUsd, 40_000e18);
        assertEq(totalDscMinted, 0);
    }

    function testGetHealthFactorNoDebt() public depositedCollateral {
        vm.prank(USER);
        uint256 healthFactor = dsce.getHealthFactor();
        assertEq(healthFactor, type(uint256).max);
    }

    // 6. Liquidation Test
    function testLiquidateRevertsIfHealthFactorOk()
        public
        depositedCollateralAndMintedDsc
    {
        // Mint DSC to liquidator from DSC owner
        vm.startPrank(dsc.owner());
        dsc.mint(LIQUIDATOR, 1 ether);
        vm.stopPrank();

        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(dsce), 1 ether);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, 1 ether);
        vm.stopPrank();
    }

    
    function testGetCollateralBalance() public depositedCollateral {
        uint256 balance = dsce.getCollateralBalance(USER, weth);
        assertEq(balance, AMOUNT_COLLATERAL);
    }

    function testGetDscMinted() public depositedCollateralAndMintedDsc {
        uint256 minted = dsce.getDscMinted(USER);
        assertEq(minted, 10 ether);
    }

    function testRedeemCollateralForDsc() public depositedCollateralAndMintedDsc {
    vm.startPrank(USER);
    dsc.approve(address(dsce), 5 ether);
    dsce.redeemCollateralForDsc(weth, 5 ether, 5 ether);
    vm.stopPrank();

    uint256 collateralBalance = dsce.getCollateralBalance(USER, weth);
    uint256 dscMinted = dsce.getDscMinted(USER);

    assertEq(collateralBalance, AMOUNT_COLLATERAL - 5 ether);
    assertEq(dscMinted, 5 ether);
}

function testRedeemCollateralRevertsIfMoreThanDeposited()
    public
    depositedCollateralAndMintedDsc
{
    vm.startPrank(USER);
    vm.expectRevert(); // underflow on sCollateralDeposited
    dsce.redeemCollateral(weth, AMOUNT_COLLATERAL + 1 ether);
    vm.stopPrank();
}

function testHealthFactorMaxWhenNoDebt() public depositedCollateral {
    vm.prank(USER);
    uint256 hf = dsce.getHealthFactor();
    assertEq(hf, type(uint256).max);
}
function testGetTokenAmountFromUsd() public view {
    uint256 usd = 2_000e18; // $2k
    uint256 amount = dsce.getTokenAmountFromUsd(weth, usd);
    // With 2000 price and FEED_PRECISION 1e8, should be 1 ETH
    assertEq(amount, 1e18);
}




}
