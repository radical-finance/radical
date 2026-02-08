pragma solidity ^0.8.20;

pragma abicoder v2;

import {IERC20} from "@openzeppelin/contracts8/token/ERC20/IERC20.sol";
import {ISwapRouter} from "v3-periphery/interfaces/ISwapRouter.sol";

contract TraderSimulator {
    function trade(address token0, address token1, address swapRouter) public {
        // convert the whole balance of token 0 to token 1
        uint256 balanceToken0 = IERC20(token0).balanceOf(address(this));

        // Approve the router to spend token0
        IERC20(token0).approve(swapRouter, balanceToken0);

        // Create the params for exactInputSingle
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: token0,
            tokenOut: token1,
            fee: 100, // 0.01% fee tier
            recipient: address(this),
            deadline: block.timestamp + 120,
            amountIn: balanceToken0,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        // Execute the swap
        ISwapRouter(swapRouter).exactInputSingle(params);
    }

    function tradeFixedAmount(address token0, address token1, address swapRouter, uint256 amount) public {
        // Use fixed amount instead of entire balance to avoid exponential growth
        uint256 balanceToken0 = IERC20(token0).balanceOf(address(this));
        uint256 amountToTrade = amount > balanceToken0 ? balanceToken0 : amount;

        if (amountToTrade == 0) return; // Skip if no balance

        // Approve the router to spend token0
        IERC20(token0).approve(swapRouter, amountToTrade);

        // Create the params for exactInputSingle
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: token0,
            tokenOut: token1,
            fee: 100, // 0.01% fee tier
            recipient: address(this),
            deadline: block.timestamp + 120,
            amountIn: amountToTrade,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        // Execute the swap
        ISwapRouter(swapRouter).exactInputSingle(params);
    }
}
