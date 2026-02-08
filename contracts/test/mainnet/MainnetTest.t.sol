pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {UniswapV3Vault} from "@src/strategies/UniswapV3Vault.sol";
import {UniswapOracle} from "@src/oracles/UniswapOracle.sol";
import {IUniswapTooling} from "@src/interfaces/adaptors/IUniswapTooling.sol";
// import {UniswapTooling} from "@src/versionAdapter/UniswapTooling.sol";

import {console} from "forge-std/console.sol";

contract MainnetTest is Test {
    UniswapV3Vault staking;

    address constant user = 0x8309BeBF4fe7650d50e7Bd524A58d1a1D2F877C2;

    function setUp() public {
        address deployed = 0x6f88F02049D8138Fb2ada1e9F48Ae6bACEF62993;
        staking = UniswapV3Vault(deployed);
    }

    function test_DeployUniswapV3Vault() public {
        UniswapOracle oracle = UniswapOracle(address(staking.oracleContract()));

        console.log("supply is", staking.totalSupply());
        console.log("balance of user is", staking.balanceOf(user));
        console.log("pool is", address(staking.getPool()));
        console.log("oracle tooling is", address(oracle.uniswapTooling()));

        oracle.uniswapTooling().TickMath_getSqrtRatioAtTick(3);

        (
            ,
            int24 tick, // uint16 observationIndex
            ,
            ,
            ,
            ,
        ) = staking.getPool().slot0();
        console.log("current tick is", tick);

        oracle.sqrtPriceX96(staking.getPool(), 3);

        staking.collectFeesAndReinvest();

        // vm.prank(user);
        // staking.depositExact(1, 1);
    }
}
