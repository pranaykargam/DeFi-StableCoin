// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin dsc;
    address owner = address(this);
    address user = address(1);

    function setUp() public {
        dsc = new DecentralizedStableCoin(owner);
    }

    function testOwnerCanMint() public {
        dsc.mint(user, 10e18);
        assertEq(dsc.balanceOf(user), 10e18);
    }
    

    function testNonOwnerCannotMint() public {
        vm.prank(user);
        vm.expectRevert(); // Ownable revert
        dsc.mint(user, 1e18);
    }

    function testBurnReducesSupply() public {
        dsc.mint(user, 10e18);
        vm.prank(user);
        dsc.approve(address(this), 5e18);
        dsc.transferFrom(user, address(this), 5e18);
        dsc.burn(5e18);
        assertEq(dsc.totalSupply(), 5e18);
    }
}
