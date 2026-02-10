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

    /////////////////////////
    //   State Variables   //
    /////////////////////////

    // token => price feed
    mapping(address token => address priceFeed) private _priceFeeds;

    // user => token => amount
    mapping(address user => mapping(address token => uint256 amount)) private _collateralDeposited;

    // user => DSC minted (debt)
    mapping(address user => uint256 dscMinted) private _dscMinted;

    // list of collateral tokens
    address[] private _collateralTokens;

    // DSC token
    DecentralizedStableCoin private immutable _DSC;

    ///////////////////
    //   Constants   //
    ///////////////////

    uint256 private constant _LIQUIDATION_THRESHOLD = 150; // 150%
    uint256 private constant _LIQUIDATION_PRECISION = 1e18;
    uint256 private constant _FEED_PRECISION = 1e8; // typical Chainlink
    uint256 private constant _ADDITIONAL_FEED_PRECISION = 1e10; // to scale 1e8 -> 1e18
    uint256 private constant _PRECISION = 1e18;

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

function _moreThanZero(uint256 amount) internal pure {
    if (amount == 0) {
        revert DSCEngine__NeedsMoreThanZero();
    }
}

modifier isAllowedToken(address token) {
    _isAllowedToken(token);
    _;
}

function _isAllowedToken(address token) internal view {
    if (_priceFeeds[token] == address(0)) {
        revert DSCEngine__TokenNotAllowed(token);
    }
}


    ///////////////////
    //  Constructor  //
    ///////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            _priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            _collateralTokens.push(tokenAddresses[i]);
        }

       _DSC = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////////
    //   External Functions  //
    ///////////////////////////

    /**
     * @param tokenCollateralAddress ERC20 collateral token
     * @param amountCollateral amount to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        _collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success =
            IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    )
        external
        moreThanZero(amountCollateral)
        moreThanZero(amountDscToMint)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    ///////////////////////////
    //   Mint / Burn Logic   //
    ///////////////////////////

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) {
        _dscMinted[msg.sender] += amountDscToMint;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool success = _DSC.mint(msg.sender, amountDscToMint);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function burnDsc(uint256 amountDscToBurn) public moreThanZero(amountDscToBurn) {
        _dscMinted[msg.sender] -= amountDscToBurn;

        bool success = _DSC.transferFrom(msg.sender, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        _DSC.burn(amountDscToBurn);

        _revertIfHealthFactorIsBroken(msg.sender);
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
        _collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
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

    function liquidate(address user, address tokenCollateralAddress, uint256 collateralToLiquidate, uint256 dscToBurn)
        external
        moreThanZero(collateralToLiquidate)
        moreThanZero(dscToBurn)
        nonReentrant
    {
        uint256 startingHealth = _getAccountHealthFactor(user);
        if (startingHealth >= _LIQUIDATION_PRECISION) {
            revert DSCEngine__HealthFactorOk();
        }

        _dscMinted[user] -= dscToBurn;

        bool success = _DSC.transferFrom(msg.sender, address(this), dscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _DSC.burn(dscToBurn);

        _collateralDeposited[user][tokenCollateralAddress] -= collateralToLiquidate;
        bool successColl = IERC20(tokenCollateralAddress).transfer(msg.sender, collateralToLiquidate);
        if (!successColl) {
            revert DSCEngine__TransferFailed();
        }

        uint256 endingHealth = _getAccountHealthFactor(user);
        if (endingHealth <= startingHealth) {
            revert DSCEngine__HealthFactorNotImproved();
        }
    }

    ///////////////////////////
    //   Internal Functions  //
    ///////////////////////////

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _getAccountHealthFactor(user);
        if (healthFactor < _LIQUIDATION_PRECISION) {
            revert DSCEngine__HealthFactorBroken(healthFactor);
        }
    }

    function _getAccountHealthFactor(address user) internal view returns (uint256) {
        (uint256 collateralValueInUsd, uint256 totalDscMinted) = _getAccountValues(user);
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }

        uint256 collateralAdjustedForThreshold =
            (collateralValueInUsd * _LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * _LIQUIDATION_PRECISION) / totalDscMinted;
    }

    function _getAccountCollateralValueInUsd(address user) internal view returns (uint256) {
        uint256 totalCollateralUsd;

        for (uint256 i = 0; i < _collateralTokens.length; i++) {
            address token = _collateralTokens[i];
            uint256 amount = _collateralDeposited[user][token];
            if (amount == 0) continue;

            totalCollateralUsd += _getUsdValue(token, amount);
        }

        return totalCollateralUsd;
    }

    function _getUsdValue(address token, uint256 amount) internal view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        // price: 1e8, amount: 1e18 → result 1e18
        return (uint256(price) * _ADDITIONAL_FEED_PRECISION * amount) / _PRECISION;
    }

    function _getAccountValues(address user) private view returns (uint256 collateralValue, uint256 dscValue) {
        collateralValue = _getAccountCollateralValueInUsd(user);
        dscValue = _dscMinted[user];
    }

    ///////////////////////////
    //   View / Pure         //
    ///////////////////////////

    function getHealthFactor() external view returns (uint256) {
        return _getAccountHealthFactor(msg.sender);
    }

    function getCollateralBalance(address user, address token) external view returns (uint256) {
        return _collateralDeposited[user][token];
    }

    function getPriceFeed(address token) external view returns (address) {
        return _priceFeeds[token];
    }

    function getDscMinted(address user) external view returns (uint256) {
        return _dscMinted[user];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return _collateralTokens;
    }
}
