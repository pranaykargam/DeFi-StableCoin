// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../src/DSCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDSC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run()
        external
        returns (DecentralizedStableCoin, DSCEngine, HelperConfig)
    {
        HelperConfig helperConfig = new HelperConfig();
        (
            address wethUsdPriceFeed,
            address wbtcUsdPriceFeed,
            address weth,
            address wbtc,
            uint256 deployerKey
        ) = helperConfig.activeNetworkConfig();

        // 1) derive deployer address from private key
        address deployer = vm.addr(deployerKey);

        // Build the arrays for DSCEngine
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        // 2) all txs from `deployer`
        vm.startBroadcast(deployerKey);

        // 3) pass *deployer* as initialOwner
        DecentralizedStableCoin dsc = new DecentralizedStableCoin(deployer);

        DSCEngine engine = new DSCEngine(
            tokenAddresses,
            priceFeedAddresses,
            address(dsc)
        );

        // 4) transferOwnership called by the same owner (deployer)
        dsc.transferOwnership(address(engine));

        vm.stopBroadcast();

        return (dsc, engine, helperConfig);
    }
}
