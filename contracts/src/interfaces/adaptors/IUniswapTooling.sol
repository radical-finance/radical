pragma solidity >=0.5.13 <0.9.0;

interface IUniswapTooling {
    function LiquidityAmounts_getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        external
        pure
        returns (uint128);
    function LiquidityAmounts_getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        external
        pure
        returns (uint128);
    function LiquidityAmounts_getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) external pure returns (uint256 amount0, uint256 amount1);
    function TickMath_getSqrtRatioAtTick(int24 tick) external pure returns (uint160);
    function TickMath_getTickAtSqrtRatio(uint160 sqrtPriceX96) external pure returns (int24);
    function LiquidityAmounts_getAmount0ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        external
        pure
        returns (uint256 amount0);
    function LiquidityAmounts_getAmount1ForLiquidity(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint128 liquidity)
        external
        pure
        returns (uint256 amount1);
}
