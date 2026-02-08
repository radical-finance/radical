pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {EnviromentSetup} from "@test/uniswap/utils.sol";

import {IUniswapOracle} from "@interfaces/IUniswapOracle.sol";
import {UniswapOracle} from "@src/oracles/UniswapOracle.sol";

import {IUniswapTooling} from "@interfaces/adaptors/IUniswapTooling.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";

// TODO, need trading simulator
// and import from json
contract UniswapOracleTest is Test, EnviromentSetup {
    IUniswapOracle oracle;
    IUniswapV3Pool pool;

    address user = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);

    function setUp() public virtual override {
        super.setUp();

        pool = IUniswapV3Pool(IUniswapV3Factory(factoryAddress).getPool(token0, token1, fee));
        // set up BalanceTestHelper
        setFaucet(user);

        oracle = new UniswapOracle();
        UniswapOracle(address(oracle)).initialize(IUniswapTooling(vm.deployCode("UniswapTooling.sol")));
    }

    function test_worksWithShortWindwow() public {
        uint32 twapInterval = 10;
        simulateTrading(pool, twapInterval, 1000e18);

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        // because of how simulating trading works, price should be very close to current price
        assertApproxEqRel(oracle.sqrtPriceX96(pool, twapInterval), sqrtPriceX96, 0.001e18, "Oracle price mismatch");
    }

    function test_worksWithLongerWindow() public {
        uint32 twapInterval = 300;
        simulateTrading(pool, twapInterval, 1000e18, 10);

        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        // because of how simulating trading works, price should be very close to current price
        assertApproxEqRel(oracle.sqrtPriceX96(pool, twapInterval), sqrtPriceX96, 0.001e18, "Oracle price mismatch");
    }
}
