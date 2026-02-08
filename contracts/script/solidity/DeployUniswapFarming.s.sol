// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {UniswapV3Vault} from "@src/strategies/UniswapV3Vault.sol";
import {UniswapOracle} from "@src/oracles/UniswapOracle.sol";
import {IUniswapTooling} from "@interfaces/adaptors/IUniswapTooling.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "@interfaces/adaptors/INonfungiblePositionManager.sol";
import {IERC20} from "@openzeppelin/contracts8/token/ERC20/IERC20.sol";

// run this script with
// `forge script script/solidity/PATH.s.sol --rpc-url https://forno.celo.org --private-key $PK --broadcast`

contract DeployUniswapFarming is Script {
    address factoryAddress = 0xAfE208a311B21f13EF87E33A90049fC17A7acDEc;
    address nftPositionManager = 0x3d79EdAaBC0EaB6F08ED885C05Fc0B014290D95A;

    address token0 = 0x48065fbBE25f71C9282ddf5e1cD6D6A887483D5e; //USDT
    address token1 = 0xcebA9300f2b948710d2653dD7B07f33A8B32118C; // USDC
    uint24 fees = 100;
    address feeVault = address(0xCa2d387AFb0C1b816b33A81001D4DE797A5424f0);
    uint32 oracleTwapInterval = 300;

    address uniswapToolingAddressCache = 0x1A94453A4a5aA102933b5f1FdA7558030cc35c66;

    function setUp() public {}

    function create2deploy(bytes32 salt, bytes memory initCode) internal returns (address) {
        address deployedAddress;
        assembly {
            deployedAddress := create2(0, add(initCode, 32), mload(initCode), salt)
            if iszero(extcodesize(deployedAddress)) { revert(0, 0) }
        }
        return deployedAddress;
    }

    function deployUniswapTooling() internal returns (address) {
        if (uniswapToolingAddressCache != address(0)) {
            console.log("UniswapTooling not deployed, implementation provided", uniswapToolingAddressCache);
            return uniswapToolingAddressCache;
        }
        bytes memory implementationBytecode = vm.getCode("UniswapTooling.sol");

        // address uniswapToolingAddress = vm.deployCode("UniswapTooling.sol");
        bytes memory initialCode = abi.encodePacked(implementationBytecode);

        return create2deploy(bytes32(0), initialCode);
    }

    function run() public {
        // TODO open this form a json
        // config

        vm.startBroadcast();

        // TODO make upgradable

        // TransparentUpgradeableProxy (OZ)

        IUniswapTooling uniswapTooling = IUniswapTooling(deployUniswapTooling());

        // Deploy the implementation contract
        UniswapV3Vault implementation = new UniswapV3Vault();

        // Deploy the proxy and initialize
        UniswapV3Vault staking = UniswapV3Vault(address(implementation));

        UniswapOracle oracle = new UniswapOracle();
        oracle.initialize(uniswapTooling);

        UniswapV3Vault.TokenPair memory tokens =
            UniswapV3Vault.TokenPair({tokenA: IERC20(token0), tokenB: IERC20(token1)});

        UniswapV3Vault.TickerConfig memory tickerConfig =
            UniswapV3Vault.TickerConfig({tickerCenter: 0, tickerWindow: 10});

        staking.initialize(
            IUniswapV3Factory(factoryAddress),
            INonfungiblePositionManager(nftPositionManager),
            oracle,
            oracleTwapInterval,
            tokens,
            fees,
            feeVault,
            tickerConfig,
            uniswapTooling
        );

        address deployedTo = address(staking);
        console.log("Deployed to: %s", deployedTo);

        vm.stopBroadcast();
    }
}
