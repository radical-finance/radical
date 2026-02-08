pragma solidity 0.7.6;

// Adaptor contract to expose UniswapV3 tooling functions that are not
// compatible with Solidity 0.8

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {IUniswapTooling} from "@interfaces/adaptors/IUniswapTooling.sol";

import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

contract UniswapTooling is IUniswapTooling {
    function TickMath_getSqrtRatioAtTick(int24 tick) external pure override returns (uint160) {
        return TickMath.getSqrtRatioAtTick(tick);
    }

    function TickMath_getTickAtSqrtRatio(uint160 sqrtPriceX96) external pure override returns (int24) {
        return TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    function LiquidityAmounts_getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        external
        pure
        override
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, amount0);
    }

    function LiquidityAmounts_getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        external
        pure
        override
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, amount1);
    }

    function LiquidityAmounts_getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) external pure override returns (uint256 amount0, uint256 amount1) {
        return LiquidityAmounts.getAmountsForLiquidity(sqrtRatioX96, sqrtRatioAX96, sqrtRatioBX96, liquidity);
    }

    function LiquidityAmounts_getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        external
        pure
        override
        returns (uint256 amount0)
    {
        return LiquidityAmounts.getAmount0ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
    }

    function LiquidityAmounts_getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        external
        pure
        override
        returns (uint256 amount1)
    {
        return LiquidityAmounts.getAmount1ForLiquidity(sqrtRatioAX96, sqrtRatioBX96, liquidity);
    }
}
