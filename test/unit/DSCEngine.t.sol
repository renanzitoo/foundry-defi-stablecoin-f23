// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { DeployDSC } from "../../script/DeployDSC.s.sol";
import { DSCEngine } from "../../src/DSCEngine.sol";
import { DecentralizedStableCoin } from "../../src/DecentralizedStableCoin.sol";
import { Test, console } from "forge-std/Test.sol";
import { HelperConfig } from "../../script/HelperConfig.s.sol";

contract DSCEngineTest is Test {
  DeployDSC deployer;
  DecentralizedStableCoin dsc;
  DSCEngine dsce;
  HelperConfig config;
  address weth;
  address ethUsdPriceFeed;

  function setUp() external {
    deployer = new DeployDSC();
    (dsc, dsce, config) = deployer.run();
    (ethUsdPriceFeed,, weth,,) = config.activeNetworkConfig();
  }

  function testGetUsdValue() external {
    uint256 ethAmount = 15e18;
    // 15 ETH * $2000/ETH = $30,000
    uint256 expectedUsd = 30000e18; 
    uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
    assertEq(expectedUsd, actualUsd);
  }
}