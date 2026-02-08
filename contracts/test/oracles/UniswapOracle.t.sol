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

    /// @notice TDD: This test will FAIL until the rounding bug is fixed.
    /// Solidity division truncates towards zero, not negative infinity.
    /// For example: -7 / 3 = -2 in Solidity (truncates towards zero)
    /// But mathematically floor(-7 / 3) = -3 (rounds towards negative infinity)
    /// This means negative ticks are biased towards zero (higher prices than expected).
    function test_negativeTickShouldUseFloorDivision() public {
        // Get the uniswapTooling to calculate expected prices
        IUniswapTooling uniswapTooling = IUniswapTooling(vm.deployCode("UniswapTooling.sol"));

        // tickCumulativesDelta = -7, twapInterval = 3
        // Solidity: -7 / 3 = -2 (truncates towards zero)
        // Floor:    -7 / 3 = -3 (correct)
        int24 incorrectTick = -2; // what Solidity gives
        int24 correctTick = -3; // what floor division should give

        uint256 priceAtIncorrectTick = uint256(uniswapTooling.TickMath_getSqrtRatioAtTick(incorrectTick));
        uint256 priceAtCorrectTick = uint256(uniswapTooling.TickMath_getSqrtRatioAtTick(correctTick));

        // Mock the pool.observe to return tick cumulatives that result in -7 delta
        // tickCumulatives[1] - tickCumulatives[0] = -7
        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 7; // older
        tickCumulatives[1] = 0; // now (delta = 0 - 7 = -7)

        // Mock the pool to return our tick cumulatives
        // observe(uint32[] secondsAgos) selector
        vm.mockCall(
            address(pool), abi.encodeWithSignature("observe(uint32[])"), abi.encode(tickCumulatives, new uint160[](2))
        );

        // Call oracle with twapInterval = 3
        uint256 oraclePrice = oracle.sqrtPriceX96(pool, 3);

        // The oracle should use floor division and return price at tick -3, not -2
        assertEq(oraclePrice, priceAtCorrectTick, "Oracle should use floor division for negative ticks");
    }
}
