//SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Handler} from "./Handler.t.sol";
import {console} from "forge-std/console.sol";

contract InvariantTest is StdInvariant, Test{
  DeployDSC deployer;
  DSCEngine dscEngine;
  DecentralizedStableCoin dsc;
  HelperConfig config;
  address weth;
  address wbtc;
  Handler handler;

  function setUp() external {
    deployer = new DeployDSC();
    (dsc, dscEngine, config) = deployer.run();
    (,,weth, wbtc,) = config.activeNetworkConfig();
    handler = new Handler(dscEngine, dsc);
    targetContract(address(handler));
  }

  function invariant_protocolMustHaveValueThanTotalSupply() public view {
    uint256 totalSupply = dsc.totalSupply();
    uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dscEngine));
    uint256 totalBtcDeposited = IERC20(wbtc).balanceOf(address(dscEngine));

    uint256 wethValue = dscEngine.getUsdValue(weth, totalWethDeposited);
    uint256 btcValue = dscEngine.getUsdValue(wbtc, totalBtcDeposited);

    console.log("totalSupply: ", totalSupply);
    console.log("wethValue: ", wethValue);
    console.log("wbtcValue: ", btcValue);
    console.log("Times Mint Called: ", handler.timesMintIsCalled());
    assert(wethValue + btcValue >= totalSupply);
  }

}
