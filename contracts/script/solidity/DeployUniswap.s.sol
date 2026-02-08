// SPDX-License-Identifier: MIT
pragma solidity <0.8.20; // TODO make this work with Solidity 0.8.20

pragma abicoder v2;

import "forge-std/Script.sol";
import "forge-std/Test.sol";
// import "forge-std/StdUtils.sol"; // Add import for StdUtils which might contain toAsciiString
import {UniswapV3Factory} from "v3-core/contracts/UniswapV3Factory.sol";
import {SwapRouter} from "@uniswap/v3-periphery/contracts/SwapRouter.sol";
import {WETH10} from "weth10/contracts/WETH10.sol";
import {
    NonfungibleTokenPositionDescriptor
} from "@uniswap/v3-periphery/contracts/NonfungibleTokenPositionDescriptor.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import {NonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/NonfungiblePositionManager.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {UniswapV3Pool} from "@uniswap/v3-core/contracts/UniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

// Mintable ERC20 implementation with public mint
contract MintableERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract DeployUniswap is Script {
    uint24 constant fee = 100;

    function run() external {
        vm.startBroadcast();

        // Deploy WETH10
        WETH10 weth10 = new WETH10();

        // Deploy UniswapV3Factory
        UniswapV3Factory factory = new UniswapV3Factory();
        factory.enableFeeAmount(fee, 1);

        // Deploy NFTDescriptor library
        // NFTDescriptor nftDescriptor = new NFTDescriptor();

        // Deploy NonfungibleTokenPositionDescriptor (link NFTDescriptor)
        NonfungibleTokenPositionDescriptor positionDescriptor =
            new NonfungibleTokenPositionDescriptor(address(weth10), bytes32("ETH"));

        // Deploy NonfungiblePositionManager
        NonfungiblePositionManager positionManager =
            new NonfungiblePositionManager(address(factory), address(weth10), address(positionDescriptor));

        // Deploy SwapRouter
        SwapRouter router = new SwapRouter(address(factory), address(weth10));

        // Print addresses
        console.log("WETH10: ", address(weth10));
        console.log("UniswapV3Factory: ", address(factory));
        // console.log("NFTDescriptor: ", address(nftDescriptor));
        console.log("NonfungibleTokenPositionDescriptor: ", address(positionDescriptor));
        console.log("NonfungiblePositionManager: ", address(positionManager));
        console.log("SwapRouter: ", address(router));

        // code hash in /Users/martinvol/radical/radical-monorepo/contracts/lib/v3-periphery/contracts/libraries/PoolAddress.sol
        //         commit e3589b192d0be27e100cd0daaf6c97204fdb1899 (HEAD, tag: v1.0.0)
        // Author: Moody Salem <moody.salem@gmail.com>
        // Date:   Tue May 4 11:46:59 2021 -0500

        //     1.0.0
        console.log("Ethereum address of UniswapV3Pool creation code hash: ");
        bytes32 actualHash = keccak256(abi.encodePacked(type(UniswapV3Pool).creationCode));
        console.logBytes32(actualHash);

        // Check if the hash matches what's in PoolAddress.sol
        bytes32 expectedHash = PoolAddress.POOL_INIT_CODE_HASH; // From PoolAddress.sol
        require(
            actualHash == expectedHash,
            string(
                abi.encodePacked(
                    "POOL_INIT_CODE_HASH mismatch! ",
                    "Expected: ",
                    vm.toString(actualHash),
                    ", ",
                    "Got: ",
                    vm.toString(expectedHash),
                    ". ",
                    "Update POOL_INIT_CODE_HASH in patches/PoolAddress.sol line 6 and apply the patch (install will do)."
                )
            )
        );

        (address token0, address token1) = deployTokens();

        address poolAddress = deployPool(token0, token1, address(positionManager), payable(address(factory)));
        // this makes sure the token addresses are in the right order
        token0 = IUniswapV3Pool(poolAddress).token0();
        token1 = IUniswapV3Pool(poolAddress).token1();

        mintBothTokens(token0, token1); // Mint tokens to the contract address

        vm.stopBroadcast();

        // Write addresses to JSON file
        writeEnvironmentParamsToJson(
            address(weth10),
            address(factory),
            address(positionDescriptor),
            address(positionManager),
            address(router),
            token0,
            token1,
            fee
        );
    }

    function buildJSONSegmentLast(string memory json, string memory identifier, address address_)
        internal
        returns (string memory)
    {
        return buildJSONSegment(json, identifier, address_, true);
    }

    function buildJSONSegment(string memory json, string memory identifier, address address_)
        internal
        pure
        returns (string memory)
    {
        return buildJSONSegment(json, identifier, address_, false);
    }

    function buildJSONSegment(string memory json, string memory identifier, address address_, bool last)
        internal
        pure
        returns (string memory)
    {
        string memory ending = last ? '"\n' : '",';
        return string(abi.encodePacked(json, '  "', identifier, '": "', vm.toString(address_), ending));
    }

    function writeEnvironmentParamsToJson(
        address weth10,
        address factory,
        address positionDescriptor,
        address positionManager,
        address router,
        address token0,
        address token1,
        uint24 fee
    ) internal {
        string memory jsonPath = "./artifacts/uniswap_addresses_dev.json";
        address caller = msg.sender; // Use msg.sender to get the caller address

        // Create JSON object
        string memory json = "{\n";

        json = buildJSONSegment(json, "caller", caller);
        json = buildJSONSegment(json, "WETH10", weth10);
        json = buildJSONSegment(json, "UniswapV3Factory", factory);
        json = buildJSONSegment(json, "NonfungibleTokenPositionDescriptor", positionDescriptor);
        json = buildJSONSegment(json, "NonfungiblePositionManager", positionManager);
        json = buildJSONSegment(json, "SwapRouter", router);
        json = buildJSONSegment(json, "token0", token0);
        // can't use buildJSONSegment because fee is uint24
        json = string(abi.encodePacked(json, '  "', "fee", '": "', vm.toString(uint256(fee)), '",'));
        json = buildJSONSegmentLast(json, "token1", token1);

        json = string(abi.encodePacked(json, "}\n"));
        console.log("json", json);

        vm.writeJson(json, jsonPath);
        console.log("Addresses written to %s", jsonPath);
    }

    function mintBothTokens(address token0, address token1) public {
        console.log("Minting tokens...");
        address caller = msg.sender; // Use msg.sender to get the caller address
        // Mint tokens
        uint256 mintAmount = 1000000 * 10 ** 18; // 1 million tokens
        MintableERC20(token0).mint(caller, mintAmount);
        MintableERC20(token1).mint(caller, mintAmount);
        // vm.stopBroadcast();
    }

    function deployTokens() public returns (address token0, address token1) {
        console.log("Deploying tokens...");
        // Deploy two MintableERC20 tokens
        token0 = deployERC20Token("TokenA", 18);
        token1 = deployERC20Token("TokenB", 18);

        mintBothTokens(token0, token1);
    }

    function deployERC20Token(string memory name, uint8 decimals) public returns (address token0ddress) {
        // vm.startBroadcast();
        // Deploy a new MintableERC20 token
        MintableERC20 token = new MintableERC20(name, name, decimals);
        // vm.stopBroadcast();
        token0ddress = address(token);
    }

    function deployPool(
        address token0,
        address token1,
        address payable _nonfungiblePositionManager,
        address payable _uniswapV3Factory
    ) public returns (address poolAddress) {
        console.log("Deploying Uniswap V3 Pool...");
        // address caller = address(this);
        address caller = msg.sender; // Use msg.sender to get the caller address

        // Ensure token0 address is less than token1 for Uniswap V3 convention
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        // Get factory and position manager
        UniswapV3Factory factory = UniswapV3Factory(_uniswapV3Factory); // Replace with actual address
        NonfungiblePositionManager positionManager = NonfungiblePositionManager(_nonfungiblePositionManager); // Replace with actual address

        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee});
        address poolAddressCalculated = PoolAddress.computeAddress(address(_uniswapV3Factory), poolKey);
        console.log("poolAddressCalculated", poolAddressCalculated);

        poolAddress =
            positionManager.createAndInitializePoolIfNecessary(token0, token1, fee, TickMath.getSqrtRatioAtTick(0));
        console.log("poolAddress", poolAddress);

        // Create a pool with 0.3% fee tier (3000)
        // address poolAddress = factory.createPool(token0, token1, 3000);

        // // Initialize the pool with a price
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddressCalculated);
        pool.token0(); // check that it doesn't fail, address is valid

        console.log("Increase observation cardinality...");
        pool.increaseObservationCardinalityNext(50); // increase oracle to 5 observations

        console.log("Pool in factory:", factory.getPool(token0, token1, fee));
        require(factory.getPool(token0, token1, fee) != address(0), "Address not created"); // Ensure the pool is created

        // uint160 sqrtPriceX96 = ; // 1:1 ratio
        // TickMath.getSqrtRatioAtTick(0)
        // pool.initialize(sqrtPriceX96);
        // pool.slot0(); // Ensure the pool is initialized

        // console.log("Pool address:", poolAddress);
        // require(poolAddress != address(0), "Pool not created");

        // After initialization, verify state
        // (uint160 sqrtPriceX961, int24 tick, , , , , bool unlocked) = pool.slot0();
        // console.log("Pool initialized with sqrtPriceX96:", sqrtPriceX961);
        // console.log("Pool initialized with tick:", tick);
        // console.log("Pool unlocked status:", unlocked);

        // Approve tokens to position manager
        console.log("1");
        uint256 mintAmount = MintableERC20(token0).balanceOf(caller);
        console.log("2");
        MintableERC20(token0).approve(address(positionManager), mintAmount);
        console.log("3");
        MintableERC20(token1).approve(address(positionManager), mintAmount);
        console.log("4");

        // console.log("  token0 address:", token0);
        // console.log("  token1 address:", token1);
        // console.log("  caller address:", caller);
        // console.log("  contract address:", address(this));
        // console.log("  token0 balance of caller:", MintableERC20(token0).balanceOf(caller));
        // console.log("  token1 balance of caller:", MintableERC20(token1).balanceOf(caller));
        // console.log("  token0 balance of contract:", MintableERC20(token0).balanceOf(address(this)));
        // console.log("  token1 balance of contract:", MintableERC20(token1).balanceOf(address(this)));
        // console.log("  token0 allowance from caller:", MintableERC20(token0).allowance(caller, address(positionManager)));
        // console.log("  token1 allowance from caller:", MintableERC20(token1).allowance(caller, address(positionManager)));
        // console.log("  token0 allowance from contract:", MintableERC20(token0).allowance(address(this), address(positionManager)));
        // console.log("  token1 allowance from contract:", MintableERC20(token1).allowance(address(this), address(positionManager)));

        // Before creating the position parameters:
        // int24 tickSpacing = 60; // For 0.3% fee tier

        // Create position parameters
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            fee: fee,
            // TODO make this the full range
            // tickLower: (TickMath.MIN_TICK / tickSpacing) * tickSpacing, // TODO change this for a real tick
            // tickUpper: (TickMath.MAX_TICK / tickSpacing) * tickSpacing,
            tickLower: TickMath.MIN_TICK, // TODO change this for a real tick
            tickUpper: TickMath.MAX_TICK,
            amount0Desired: mintAmount,
            amount1Desired: mintAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: caller,
            deadline: block.timestamp + 15 minutes
        });

        // Add liquidity
        (uint256 tokenId, uint128 liquidity,,) = positionManager.mint(params);

        console.log("Position minted with tokenId:", tokenId);
        console.log("Liquidity added:", uint256(liquidity));

        console.log("Liquidity added");

        // // Log results
        // console.log("Pool created at:", poolAddress);
        // console.log("Token A:", token0);
        // console.log("Token B:", token1);
        // console.log("NFT Position ID:", tokenId);
        // console.log("Liquidity added:", uint256(liquidity));
        // console.log("Token A deposited:", amount0);
        // console.log("Token B deposited:", amount1);
    }
}

//  Invalid implicit conversion from
//  struct INonfungiblePositionManager.MintParams memory
//  struct INonfungiblePositionManager.MintParams memory requested.
