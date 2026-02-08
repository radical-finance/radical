// SPDX-License-Identifier: UNLICENSED
pragma solidity <9;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

interface IUniswapOracle {
    function sqrtPriceX96(IUniswapV3Pool pool, uint32 twapInterval) external view returns (uint256);
}
