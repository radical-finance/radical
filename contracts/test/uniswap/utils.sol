pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {BalanceTestHelper} from "@test/utils.sol";
import {IERC20} from "@openzeppelin/contracts8/token/ERC20/IERC20.sol";
import {TraderSimulator} from "@test/uniswap/TraderSimulator.sol";
import {IUniswapV3Pool} from "v3-core/contracts/interfaces/IUniswapV3Pool.sol";

contract EnviromentSetup is Test, BalanceTestHelper {
    using stdJson for string;

    address factoryAddress;
    address swapRouter;
    address nftPositionManager;
    uint24 fee;
    TraderSimulator simulator = new TraderSimulator();

    function setUp() public virtual {
        // Parse JSON data
        string memory addressesJson = vm.readFile("./artifacts/uniswap_addresses_dev_read.json");
        factoryAddress = addressesJson.readAddress(".UniswapV3Factory");
        nftPositionManager = addressesJson.readAddress(".NonfungiblePositionManager");
        swapRouter = addressesJson.readAddress(".SwapRouter"); // Using SwapRouter instead of UniversalRouter
        token0 = addressesJson.readAddress(".token0"); // This will be used as token0
        token1 = addressesJson.readAddress(".token1"); // This will be used as token1
        fee = uint24(addressesJson.readUint(".fee"));

        console.log("Loaded addresses from JSON:");
        console.log("- Factory:", factoryAddress);
        console.log("- NFT Manager:", nftPositionManager);
        console.log("- Token A (token0):", token0);
        console.log("- Token B (token1):", token1);

        token0Contract = IERC20(token0);
        token1Contract = IERC20(token1);
    }

    function simulateFeesWithoutTrading(uint256 _fees) public {
        fund(address(testedContract), _fees);
    }

    function simulateTrading(IUniswapV3Pool pool, uint256 trades, uint256 fixedTradeAmount) public {
        uint24 advanceTimeBy = 1;
        simulateTrading(pool, trades, fixedTradeAmount, advanceTimeBy);
    }

    // TODO move to trading simulator
    function simulateTrading(IUniswapV3Pool pool, uint256 trades, uint256 fixedTradeAmount, uint24 advanceTimeBy)
        public
    {
        int24 currentTick;
        fund(address(simulator), 100000e18);

        // Check price before trading
        (, int24 tickIni,,,,,) = pool.slot0();
        // console.log("Price before trading (sqrtPriceX96):", uint256(sqrtPriceX96Before));
        console.log("Initial tick:", int256(tickIni));

        vm.startPrank(faucet);
        // advance one block after each trade
        for (uint256 i = 0; i < trades; i++) {
            simulator.tradeFixedAmount(token1, token0, swapRouter, fixedTradeAmount);
            vm.roll(block.number + 1); // todo move this before trade
            vm.warp(block.timestamp + advanceTimeBy);

            console.log("Trade", i * 2 + 1, "- token1->token0 completed");
            (, currentTick,,,,,) = pool.slot0();
            console.log("Current tick:", int256(currentTick));

            simulator.tradeFixedAmount(token0, token1, swapRouter, fixedTradeAmount);
            (, currentTick,,,,,) = pool.slot0();
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + advanceTimeBy);
            console.log("Trade", i * 2 + 2, "- token0->token1 completed");
            console.log("Current tick:", int256(currentTick));
        }

        // Check price after trading
        (uint160 sqrtPriceX96After,,,,,,) = pool.slot0();
        console.log("Price after trading (sqrtPriceX96):", uint256(sqrtPriceX96After));

        // Try to return close to original price if significantly different
        // Check if tick moved from initial tick
        (, currentTick,,,,,) = pool.slot0();

        if (currentTick != tickIni) {
            console.log("Tick moved from", int256(tickIni));
            console.log("to", int256(currentTick));
            console.log("attempting to return to original tick...");

            // Binary search approach to get back to original tick
            uint256 maxAttempts = 10;
            uint256 currentTradeSize = fixedTradeAmount / 10;

            for (uint256 attempt = 0; attempt < maxAttempts; attempt++) {
                (, currentTick,,,,,) = pool.slot0();

                // Check if we're back to the original tick
                if (currentTick == tickIni) {
                    console.log("Successfully returned to original tick after", attempt + 1, "attempts");
                    break;
                }

                // Determine trade direction based on current vs target tick
                if (currentTick > tickIni) {
                    // Current tick is higher than target, need to sell token0 (buy token1) to decrease tick
                    simulator.tradeFixedAmount(token0, token1, swapRouter, currentTradeSize);
                } else {
                    // Current tick is lower than target, need to buy token0 (sell token1) to increase tick
                    simulator.tradeFixedAmount(token1, token0, swapRouter, currentTradeSize);
                }

                // Check if we overshot or made progress
                int24 previousTick = currentTick;
                (, currentTick,,,,,) = pool.slot0();

                // Calculate distances from target
                int24 previousDistance = previousTick > tickIni ? previousTick - tickIni : tickIni - previousTick;
                int24 currentDistance = currentTick > tickIni ? currentTick - tickIni : tickIni - currentTick;

                if (currentDistance >= previousDistance) {
                    // We didn't get closer or got further away, reduce trade size
                    currentTradeSize = currentTradeSize / 2;
                    console.log("Not making progress, reducing trade size to:", currentTradeSize);
                } else {
                    // We're getting closer, slightly reduce trade size for precision
                    currentTradeSize = (currentTradeSize * 9) / 10;
                }

                // Prevent infinite loop with very small trades
                if (currentTradeSize < 1e15) {
                    console.log("Trade size too small, stopping correction attempts");
                    break;
                }

                vm.roll(block.number + 1);
                vm.warp(block.timestamp + advanceTimeBy);

                console.log("Correction attempt", attempt + 1);
                console.log("completed, tick:", int256(currentTick));
                console.log("target:", int256(tickIni));
            }
        }

        (, int24 tick,,,,,) = pool.slot0();
        console.log("tick after trading:", int256(tick));
        vm.stopPrank();
    }
}
