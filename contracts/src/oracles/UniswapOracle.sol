// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts8/proxy/utils/Initializable.sol";

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapOracle} from "@interfaces/IUniswapOracle.sol";

import {IUniswapTooling} from "@interfaces/adaptors/IUniswapTooling.sol";

contract UniswapOracle is IUniswapOracle, Initializable {
    // TODO this is duplicate from staking contract
    IUniswapTooling public uniswapTooling;

    event UniswapToolingSet(IUniswapTooling uniswapTooling);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // Initialize pattern without proxy - don't disable initializers
    }

    function initialize(IUniswapTooling _uniswapTooling) external initializer {
        uniswapTooling = _uniswapTooling;
        emit UniswapToolingSet(_uniswapTooling);
    }

    function sqrtPriceX96(IUniswapV3Pool pool, uint32 twapInterval) external view override returns (uint256) {
        uint32[] memory secondsAgo = new uint32[](2);

        secondsAgo[0] = twapInterval;
        secondsAgo[1] = 0; // now

        (int56[] memory tickCumulatives,) = pool.observe(secondsAgo);

        // Calculate time-weighted average tick
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
        int24 averageTick = int24(tickCumulativesDelta / int56(uint56(twapInterval)));

        // Adjust for negative rounding (Solidity truncates towards zero, we need floor)
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(twapInterval)) != 0)) averageTick--;

        // Convert tick to price (sqrtPriceX96)
        return uint256(uniswapTooling.TickMath_getSqrtRatioAtTick(averageTick));
    }
}
