

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author sunny
 *
 * Exogenously collateralized, dollar-pegged, algorithmic stablecoin engine.
 * - Collateral: e.g. WETH / WBTC
 * - Always overcollateralized
 * - Handles deposit / redeem collateral and mint / burn DSC
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////
    //     Errors    //
    ///////////////////

    error DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorBroken(uint256 healthFactor);
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();

    /////////////////////////
    //   State Variables   //
    /////////////////////////

    // token => price feed
    mapping(address => address) private sPriceFeeds;

    // user => token => amount
    mapping(address => mapping(address => uint256)) private sCollateralDeposited;

    // user => DSC minted (debt)
    mapping(address => uint256) private sDscMinted;

    // list of collateral tokens
    address[] private sCollateralTokens;

    // DSC token
    DecentralizedStableCoin private immutable I_DSC;

    ///////////////////
    //   Constants   //
    ///////////////////

    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 50% (for example)
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    uint256 private constant FEED_PRECISION = 1e8; // typical Chainlink
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // to scale 1e8 -> 1e18
    uint256 private constant PRECISION = 1e18;

    ////////////////
    //   Events   //
    ////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);

    ///////////////////
    //   Modifiers   //
    ///////////////////

    modifier moreThanZero(uint256 amount) {
        _moreThanZero(amount);
        _;
    }

    modifier isAllowedToken(address token) {
        _isAllowedToken(token);
        _;
    }

    ///////////////////
    //  Constructor  //
    ///////////////////

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            sPriceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            sCollateralTokens.push(tokenAddresses[i]);
        }

        I_DSC = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////////
    //   External Functions  //
    ///////////////////////////

    /**
     * @param tokenCollateralAddress ERC20 collateral token
     * @param amountCollateral amount to deposit
     */

     /*//////////////////////////////////////////////////////////////
                            DEPOSITE FUNCTION
    //////////////////////////////////////////////////////////////*/

   // function name(parameters) visibility modifiers { body }
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        sCollateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success =
            IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }



    /*
     * @param tokenCollateralAddress: the address of the token to deposit as collateral
     * @param amountCollateral: The amount of collateral to deposit
     * @param amountDscToMint: The amount of DecentralizedStableCoin to mint
     * @notice: This function will deposit your collateral and mint DSC in one transaction
     */



    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    ///////////////////////////
    //   Mint / Burn Logic   //
    ///////////////////////////

    /*
     * @param amountDscToMint: The amount of DSC you want to mint
     * You can only mint DSC if you have enough collateral
     */

    ///////////////////////////
    //   Mint   //
    ///////////////////////////


    function mintDsc(uint256 amountDscToMint)
        public
        moreThanZero(amountDscToMint)
        nonReentrant
    {
        sDscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = I_DSC.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

 

      ///////////////////////////
    //   Burn Logic   //
    ///////////////////////////

    function burnDsc(uint256 amountDscToBurn)
    
     public moreThanZero(amountDscToBurn) 
     {
        sDscMinted[msg.sender] -= amountDscToBurn;

        bool success = I_DSC.transferFrom(msg.sender, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        I_DSC.burn(amountDscToBurn);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /////////////////////////////////
    //   Private / Internal Logic  //
    /////////////////////////////////

    function _moreThanZero(uint256 amount) internal pure {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
    }

    function _isAllowedToken(address token) internal view {
        if (sPriceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(token);
        }
    }


   /////////////////////////////////
    //  reedemColateral  // 
    /////////////////////////////////
    
    //handles the withdrawal of collateral tokens deposited by users. 

    // function name, parameters, visibility, -- body 
    // it does not have any modifiers because it is a private 
   function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        sCollateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
     * Returns how close to liquidation a user is
     * If a user goes below 1e18, then they can be liquidated.
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }

        uint256 collateralAdjustedForThreshold =
            (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * MIN_HEALTH_FACTOR) / totalDscMinted;
    }

    function getAccountInformation(address user)
    external
    view
    returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
{
    return _getAccountInformation(user);
}


    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = sDscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    ///////////////////////////
    //   Redeem / Withdraw   //
    ///////////////////////////

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        sCollateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    ///////////////////////////
    //     Liquidation       //
    ///////////////////////////

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
        isAllowedToken(collateral)
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor > MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        uint256 bonusCollateral =
            (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralRedeemed = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(collateral, totalCollateralRedeemed, user, msg.sender);

        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        sDscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = I_DSC.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        I_DSC.burn(amountDscToBurn);
    }

    ///////////////////////////
    //   Internal Views      //
    ///////////////////////////

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorBroken(healthFactor);
        }
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei)
        public
        view
        //  moreThanZero(usdAmountInWei) 
        returns (uint256)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(sPriceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData(); // price in 1e8

        // usdAmountInWei: 1e18, price: 1e8 ⇒ token amount: 1e18
        return (usdAmountInWei * FEED_PRECISION) / uint256(price);
    }

    // ---------- USD value helpers ----------

    // Private helper used internally
    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(sPriceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        // price: 1e8, amount: 1e18 → result 1e18
        return (uint256(price) * ADDITIONAL_FEED_PRECISION * amount) / PRECISION;
    }

    // Public view for tests (dsce.getUsdValue(...))
    function getUsdValue(address token, uint256 amount) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    ///////////////////////////
    //   Public View         //
    ///////////////////////////

    function getHealthFactor() external view returns (uint256) {
        return _healthFactor(msg.sender);
    }

    function getAccountCollateralValue(address user)
        public
        view
        returns (uint256 totalCollateralValueInUsd)
    {
        for (uint256 i = 0; i < sCollateralTokens.length; i++) {
            address token = sCollateralTokens[i];
            uint256 amount = sCollateralDeposited[user][token];
            if (amount == 0) {
                continue;
            }
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
    }

    function getCollateralBalance(address user, address token) external view returns (uint256) {
        return sCollateralDeposited[user][token];
    }

    function getPriceFeed(address token) external view returns (address) {
        return sPriceFeeds[token];
    }

    function getDscMinted(address user) external view returns (uint256) {
        return sDscMinted[user];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return sCollateralTokens;
    }
}

