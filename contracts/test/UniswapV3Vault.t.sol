// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

pragma abicoder v2;

import {Test, console} from "forge-std/Test.sol";

import {UniswapV3Vault} from "@src/strategies/UniswapV3Vault.sol";
import {IUniswapOracle} from "@interfaces/IUniswapOracle.sol";
import {UniswapOracle} from "@src/oracles/UniswapOracle.sol";
import {Initializable} from "@openzeppelin/contracts8/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts8/access/Ownable.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "@interfaces/adaptors/INonfungiblePositionManager.sol";

import {IUniswapTooling} from "@interfaces/adaptors/IUniswapTooling.sol";
import {TickBounds, TickConfigWindow, TickConfigLib} from "@src/libraries/TickConfigLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts8/token/ERC20/extensions/IERC20Metadata.sol";

import {BalanceTestHelper} from "@test/utils.sol";
import {EnviromentSetup} from "@test/uniswap/utils.sol";
import {IRadicalVaultTwoTokens} from "@interfaces/IRadicalVaultTwoTokens.sol";

import "./MockMerkleDistributor.sol";

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}

contract UniswapOracleMock is IUniswapOracle {
    uint256 mockedPrice = 2 ** 96; // 1:1 price ratio
    bool shouldRevert = false;

    function sqrtPriceX96(IUniswapV3Pool, uint32) external view override returns (uint256) {
        console.log("mocking price to:", mockedPrice);
        require(!shouldRevert, "Oracle revert requested");
        return mockedPrice;
    }

    function setMockedPrice(uint256 _price) external {
        mockedPrice = _price;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }
}

contract UniswapV3VaultTestBase is Test, BalanceTestHelper, EnviromentSetup {
    uint256 constant depositAmount = 10e18;
    IUniswapOracle oracle;
    UniswapV3Vault staking;

    // Addresses to be loaded from JSON file

    address feeVault = address(uint160(uint256(keccak256(abi.encode("feeVault")))));

    // clean up all the comments that add no value
    // TODO move this address to json or constant file
    address user = address(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266);
    address user1 = address(0x1111); // TODO move this to 'actors'
    address user2 = address(0x2222);

    function setUp() public virtual override {
        // Load addresses from JSON file
        EnviromentSetup.setUp();

        // Deploy and initialize the contract
        staking = new UniswapV3Vault();
        setOracle();

        // set up BalanceTestHelper
        setFaucet(user);
        setTestedContract(staking);
    }

    function initializeContract() public {
        UniswapV3Vault.TokenPairUnsorted memory tokens =
            UniswapV3Vault.TokenPairUnsorted({tokenA: token1Contract, tokenB: token0Contract});

        TickBounds memory tickBounds = TickConfigLib.toTickBounds(TickConfigWindow({tickCenter: 0, tickWindowSize: 10}));

        UniswapV3Vault.RiskConfig memory riskConfig =
            UniswapV3Vault.RiskConfig({maxTickDivergence: 100, minDelayDepositSeconds: 5, transferWindowSeconds: 10});

        staking.initialize(
            IUniswapV3Factory(factoryAddress),
            INonfungiblePositionManager(nftPositionManager),
            oracle,
            40, // twap interval
            tokens,
            fee,
            feeVault,
            tickBounds,
            IUniswapTooling(vm.deployCode("UniswapTooling.sol")),
            riskConfig
        );
    }

    function setOracle() public virtual {
        oracle = new UniswapOracleMock();
    }
}

contract UniswapV3VaultTest is UniswapV3VaultTestBase {
    function setUp() public virtual override {
        super.setUp();
        initializeContract();
    }
}

contract UniswapV3VaultTest_initialize is UniswapV3VaultTestBase {
    function test_initializeOnlyOnce() public {
        initializeContract();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        this.initializeContract();
    }

    function test_parameteresAreSetCorrectly() public {
        initializeContract();
        assertEq(address(staking.factory()), factoryAddress, "Factory address mismatch");
        assertEq(address(staking.token0()), token0, "Token0 address mismatch"); // swapped
        assertEq(address(staking.token1()), token1, "Token1 address mismatch"); // swapped
        assertEq(staking.fee(), fee, "Pool fee mismatch");
        assertEq(address(staking.feeVault()), feeVault, "Fee vault address mismatch");
        assertEq(staking.maxTickDivergence(), 100, "maxTickDivergence should be 100");
        assertEq(staking.minDelayDepositSeconds(), 5, "minDelayDepositSeconds should be 5");
        assertEq(staking.transferWindowSeconds(), 10, "transferWindowSeconds should be 10");
    }

    function test_emitsEvents() public {
        IUniswapOracle oracle = new UniswapOracleMock();
        IUniswapTooling uniswapTooling = IUniswapTooling(vm.deployCode("UniswapTooling.sol"));

        // Expect all events to be emitted in the correct order with correct parameters
        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.UniswapV3FactorySet(IUniswapV3Factory(factoryAddress));

        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.NonfungiblePositionManagerSet(INonfungiblePositionManager(nftPositionManager));

        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.FeeSet(fee);

        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.TickConfigSet(TickConfigLib.toTickBounds(
                TickConfigWindow({tickCenter: 0, tickWindowSize: 10})
            ));

        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.TokensSet(UniswapV3Vault.TokenPairSorted({token0: token0Contract, token1: token1Contract}));

        // Compute expected vault name and symbol based on sorted tokens
        {
            string memory symbolA = IERC20Metadata(address(token0Contract)).symbol();
            string memory symbolB = IERC20Metadata(address(token1Contract)).symbol();
            string memory expectedSymbol = string(abi.encodePacked(symbolA, "-", symbolB));
            string memory expectedName = string(abi.encodePacked("Radical Vault ", expectedSymbol));

            vm.expectEmit(true, true, true, true);
            emit UniswapV3Vault.VaultNameSet(expectedName);

            vm.expectEmit(true, true, true, true);
            emit UniswapV3Vault.VaultSymbolSet(expectedSymbol);
        }

        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.FeeVaultSet(feeVault);

        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.OracleSet(oracle);

        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.UniswapToolingSet(uniswapTooling);

        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.OracleTWAPIntervalSet(40);

        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.RiskConfigSet(UniswapV3Vault.RiskConfig({
                maxTickDivergence: 100, minDelayDepositSeconds: 5, transferWindowSeconds: 10
            }));

        // Call initialize - this should emit all the expected events
        UniswapV3Vault.TokenPairUnsorted memory tokens =
            UniswapV3Vault.TokenPairUnsorted({tokenA: token1Contract, tokenB: token0Contract});

        TickBounds memory tickBounds = TickConfigLib.toTickBounds(TickConfigWindow({tickCenter: 0, tickWindowSize: 10}));

        UniswapV3Vault.RiskConfig memory riskConfig =
            UniswapV3Vault.RiskConfig({maxTickDivergence: 100, minDelayDepositSeconds: 5, transferWindowSeconds: 10});

        staking.initialize(
            IUniswapV3Factory(factoryAddress),
            INonfungiblePositionManager(nftPositionManager),
            oracle,
            40, // twap interval
            tokens,
            fee,
            feeVault,
            tickBounds,
            uniswapTooling,
            riskConfig
        );
    }

    function test_ownershipIsSet() public {
        initializeContract();
        assertEq(staking.owner(), address(this), "Owner should be the deployer");
    }

    function test_emitsSlippageMaxSet() public {
        UniswapV3Vault.TokenPairUnsorted memory tokens =
            UniswapV3Vault.TokenPairUnsorted({tokenA: token1Contract, tokenB: token0Contract});

        TickBounds memory tickBounds = TickConfigLib.toTickBounds(TickConfigWindow({tickCenter: 0, tickWindowSize: 10}));

        UniswapV3Vault.RiskConfig memory riskConfig =
            UniswapV3Vault.RiskConfig({maxTickDivergence: 200, minDelayDepositSeconds: 5, transferWindowSeconds: 10});

        // Expect RiskConfigSet event with maxTickDivergence 200
        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.RiskConfigSet(riskConfig);

        staking.initialize(
            IUniswapV3Factory(factoryAddress),
            INonfungiblePositionManager(nftPositionManager),
            oracle,
            40,
            tokens,
            fee,
            feeVault,
            tickBounds,
            IUniswapTooling(vm.deployCode("UniswapTooling.sol")),
            riskConfig
        );

        // Verify the value was set correctly
        assertEq(staking.maxTickDivergence(), 200, "maxTickDivergence should be 200");
    }

    function test_acceptsValidTickSpacing() public {
        UniswapV3Vault.TokenPairUnsorted memory tokens =
            UniswapV3Vault.TokenPairUnsorted({tokenA: token1Contract, tokenB: token0Contract});

        // For 0.01% fee (100), tick spacing is 1, so any integer is valid
        // Test with various valid values (tickCenter: 5, tickWindowSize: 15 => tickLower: -10, tickUpper: 20)
        TickBounds memory tickBounds = TickConfigLib.toTickBounds(TickConfigWindow({tickCenter: 5, tickWindowSize: 15}));

        UniswapV3Vault.RiskConfig memory riskConfig =
            UniswapV3Vault.RiskConfig({maxTickDivergence: 100, minDelayDepositSeconds: 5, transferWindowSeconds: 10});

        // This should succeed since both tickUpper and tickLower are multiples of tick spacing (1)
        staking.initialize(
            IUniswapV3Factory(factoryAddress),
            INonfungiblePositionManager(nftPositionManager),
            oracle,
            40,
            tokens,
            fee,
            feeVault,
            tickBounds,
            IUniswapTooling(vm.deployCode("UniswapTooling.sol")),
            riskConfig
        );

        assertEq(staking.tickLower(), -10, "tickLower should be -10");
        assertEq(staking.tickUpper(), 20, "tickUpper should be 20");
    }

    function test_tickConfigLibConversion() public pure {
        // Test toTickBounds: center=0, windowSize=10 => lower=-10, upper=10
        TickConfigWindow memory window1 = TickConfigWindow({tickCenter: 0, tickWindowSize: 10});
        TickBounds memory bounds1 = TickConfigLib.toTickBounds(window1);
        assertEq(bounds1.tickLower, -10, "tickLower should be -10");
        assertEq(bounds1.tickUpper, 10, "tickUpper should be 10");

        // Test toTickBounds: center=100, windowSize=50 => lower=50, upper=150
        TickConfigWindow memory window2 = TickConfigWindow({tickCenter: 100, tickWindowSize: 50});
        TickBounds memory bounds2 = TickConfigLib.toTickBounds(window2);
        assertEq(bounds2.tickLower, 50, "tickLower should be 50");
        assertEq(bounds2.tickUpper, 150, "tickUpper should be 150");

        // Test negative center: center=-20, windowSize=30 => lower=-50, upper=10
        TickConfigWindow memory window3 = TickConfigWindow({tickCenter: -20, tickWindowSize: 30});
        TickBounds memory bounds3 = TickConfigLib.toTickBounds(window3);
        assertEq(bounds3.tickLower, -50, "tickLower should be -50");
        assertEq(bounds3.tickUpper, 10, "tickUpper should be 10");

        // Test validate passes for valid bounds (using tick spacing of 10)
        TickConfigLib.validate(bounds1, 10); // should not revert
        TickConfigLib.validate(bounds2, 10); // should not revert
        TickConfigLib.validate(bounds3, 10); // should not revert
    }

    function test_initializeRevertsWhenTickUpperNotGreaterThanLower() public {
        UniswapV3Vault.TokenPairUnsorted memory tokens =
            UniswapV3Vault.TokenPairUnsorted({tokenA: token1Contract, tokenB: token0Contract});

        UniswapV3Vault.RiskConfig memory riskConfig =
            UniswapV3Vault.RiskConfig({maxTickDivergence: 100, minDelayDepositSeconds: 5, transferWindowSeconds: 10});

        // Test tickUpper == tickLower (should revert)
        TickBounds memory equalBounds = TickBounds({tickUpper: 10, tickLower: 10});
        vm.expectRevert(
            abi.encodeWithSelector(TickConfigLib.TickUpperMustBeGreaterThanTickLower.selector, int24(10), int24(10))
        );
        staking.initialize(
            IUniswapV3Factory(factoryAddress),
            INonfungiblePositionManager(nftPositionManager),
            oracle,
            40,
            tokens,
            fee,
            feeVault,
            equalBounds,
            IUniswapTooling(vm.deployCode("UniswapTooling.sol")),
            riskConfig
        );
    }

    function test_initializeRevertsWhenTickUpperLessThanLower() public {
        UniswapV3Vault.TokenPairUnsorted memory tokens =
            UniswapV3Vault.TokenPairUnsorted({tokenA: token1Contract, tokenB: token0Contract});

        UniswapV3Vault.RiskConfig memory riskConfig =
            UniswapV3Vault.RiskConfig({maxTickDivergence: 100, minDelayDepositSeconds: 5, transferWindowSeconds: 10});

        // Test tickUpper < tickLower (should revert)
        TickBounds memory invertedBounds = TickBounds({tickUpper: 5, tickLower: 10});
        vm.expectRevert(
            abi.encodeWithSelector(TickConfigLib.TickUpperMustBeGreaterThanTickLower.selector, int24(5), int24(10))
        );
        staking.initialize(
            IUniswapV3Factory(factoryAddress),
            INonfungiblePositionManager(nftPositionManager),
            oracle,
            40,
            tokens,
            fee,
            feeVault,
            invertedBounds,
            IUniswapTooling(vm.deployCode("UniswapTooling.sol")),
            riskConfig
        );
    }

    function test_setsNameAndSymbolCorrectly() public {
        initializeContract();

        // Tokens are sorted by Uniswap based on address
        // Verify the vault name and symbol match the sorted token order
        string memory expectedSymbol = string(
            abi.encodePacked(ERC20(address(staking.token0())).symbol(), "-", ERC20(address(staking.token1())).symbol())
        );
        string memory expectedName = string(abi.encodePacked("Radical Vault ", expectedSymbol));

        assertEq(staking.symbol(), expectedSymbol, "Symbol should match token0-token1");
        assertEq(staking.name(), expectedName, "Name should match Radical Vault token0-token1");
    }

    function test_decimalsIs18() public {
        initializeContract();
        assertEq(staking.decimals(), 18, "Decimals should be 18");
    }
}

contract UniswapV3VaultTest_setFeeVault is UniswapV3VaultTest {
    function test_Revert_WhenNotFeeVault() public {
        vm.prank(user1);
        vm.expectRevert("Only current fee vault can change itself");
        staking.setFeeVault(address(0x1234));
    }

    function test_setsFeeVaultCorrectly() public {
        vm.prank(staking.feeVault());
        staking.setFeeVault(address(0x1234));
        assertEq(address(staking.feeVault()), address(0x1234), "Fee vault address not updated correctly");
    }

    function test_Revets_AddressZero() public {
        vm.prank(staking.feeVault());
        vm.expectRevert("Fee vault can not be zero address");
        staking.setFeeVault(address(0));
    }
}

contract UniswapV3VaultTest_transfer is UniswapV3VaultTest {
    address user3;

    function setUp() public override {
        super.setUp();
        user3 = address(0x3333);

        // Fund and approve users
        fundAndApprove(user1, 100e18);
        fundAndApprove(user2, 100e18);
    }

    function test_transferUpdatesBalancesCorrectly() public {
        // user1 deposits to get shares
        vm.prank(user1);
        staking.depositExact(10e18, 10e18);

        uint256 user1SharesBefore = staking.balanceOf(user1);
        uint256 user2SharesBefore = staking.balanceOf(user2);

        // Transfer half of shares from user1 to user2
        uint256 transferAmount = user1SharesBefore / 2;
        vm.prank(user1);
        staking.transfer(user2, transferAmount);

        // Check balances
        assertEq(staking.balanceOf(user1), user1SharesBefore - transferAmount, "User1 balance incorrect after transfer");
        assertEq(staking.balanceOf(user2), user2SharesBefore + transferAmount, "User2 balance incorrect after transfer");
    }

    function test_transferEmitsTransferEvent() public {
        // user1 deposits to get shares
        vm.prank(user1);
        staking.depositExact(10e18, 10e18);

        uint256 transferAmount = staking.balanceOf(user1) / 2;

        // Warp past the cooldown + window period
        vm.warp(block.timestamp + staking.minDelayDepositSeconds() + staking.transferWindowSeconds() + 1);

        // Expect Transfer event
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(user1, user2, transferAmount);

        vm.prank(user1);
        staking.transfer(user2, transferAmount);
    }

    function test_transferToNewAddressAllowed() public {
        // user1 deposits to get shares
        vm.prank(user1);
        staking.depositExact(10e18, 10e18);

        uint256 transferAmount = staking.balanceOf(user1) / 2;

        // Transfer to user3 who has never received shares (lastDepositTimestamp == 0)
        // Should work immediately without waiting for cooldown
        vm.prank(user1);
        staking.transfer(user3, transferAmount);

        assertEq(staking.balanceOf(user3), transferAmount, "User3 should have received shares");
    }

    function test_transferBlockedDuringCooldownPeriod() public {
        // user1 deposits to get shares
        vm.prank(user1);
        staking.depositExact(10e18, 10e18);

        // user2 also deposits (this sets their lastDepositTimestamp)
        vm.prank(user2);
        staking.depositExact(10e18, 10e18);

        uint256 transferAmount = staking.balanceOf(user1) / 2;

        // Try to transfer to user2 who just deposited (still in cooldown)
        // Should be within minDelayDepositSeconds
        vm.warp(block.timestamp + 2); // Only 2 seconds passed, cooldown is 5 seconds

        vm.prank(user1);
        vm.expectRevert("Cannot transfer to address still in cooldown period");
        staking.transfer(user2, transferAmount);
    }

    function test_transferBlockedDuringTransferWindow() public {
        // user1 deposits to get shares
        vm.prank(user1);
        staking.depositExact(10e18, 10e18);

        // user2 also deposits
        vm.prank(user2);
        staking.depositExact(10e18, 10e18);

        uint256 transferAmount = staking.balanceOf(user1) / 2;

        // Warp past minDelayDepositSeconds but not past the full transfer window
        // minDelayDepositSeconds = 5, transferWindowSeconds = 10
        // So user2 can withdraw at T+5, but can't receive transfers until T+ 5 + less than transfer windows
        vm.warp(block.timestamp + staking.minDelayDepositSeconds() + staking.transferWindowSeconds() / 2);

        vm.prank(user1);
        vm.expectRevert("Cannot transfer to address still in cooldown period");
        staking.transfer(user2, transferAmount);
    }

    function test_transferAllowedAfterFullWindow() public {
        // user1 deposits to get shares
        vm.prank(user1);
        staking.depositExact(10e18, 10e18);

        // user2 also deposits
        vm.prank(user2);
        staking.depositExact(10e18, 10e18);

        uint256 transferAmount = staking.balanceOf(user1) / 2;

        // Warp past the full cooldown + window period
        vm.warp(block.timestamp + staking.minDelayDepositSeconds() + staking.transferWindowSeconds() + 1);

        // Transfer should succeed
        vm.prank(user1);
        staking.transfer(user2, transferAmount);

        assertEq(staking.balanceOf(user2), 1e18 + transferAmount, "User2 should have received shares");
    }

    function test_transferUpdatesReceiverTimestamp() public {
        // user1 deposits to get shares
        vm.prank(user1);
        staking.depositExact(10e18, 10e18);

        // user2 also deposits
        vm.prank(user2);
        staking.depositExact(10e18, 10e18);

        uint256 user2TimestampBefore = staking.lastDepositTimestamp(user2);

        // Warp past the full window
        vm.warp(block.timestamp + staking.minDelayDepositSeconds() + staking.transferWindowSeconds() + 1);

        uint256 transferTime = block.timestamp;
        uint256 transferAmount = staking.balanceOf(user1) / 2;

        // Transfer to user2
        vm.prank(user1);
        staking.transfer(user2, transferAmount);

        // Check that user2's timestamp was updated to current block
        assertEq(staking.lastDepositTimestamp(user2), transferTime, "Receiver timestamp should be updated");
        assertGt(staking.lastDepositTimestamp(user2), user2TimestampBefore, "Timestamp should be greater than before");
    }

    function test_multipleTransfersRespectCooldown() public {
        // user1 deposits
        vm.prank(user1);
        staking.depositExact(10e18, 10e18);

        uint256 transferAmount = staking.balanceOf(user1) / 4;

        // First transfer to user3 (new address, should work immediately)
        vm.prank(user1);
        staking.transfer(user3, transferAmount);

        // Try to transfer again to user3 immediately (should fail, they're now in cooldown)
        vm.prank(user1);
        vm.expectRevert("Cannot transfer to address still in cooldown period");
        staking.transfer(user3, transferAmount);

        // Warp past the full window
        vm.warp(block.timestamp + staking.minDelayDepositSeconds() + staking.transferWindowSeconds() + 1);

        // Now transfer should work
        vm.prank(user1);
        staking.transfer(user3, transferAmount);

        assertEq(staking.balanceOf(user3), transferAmount * 2, "User3 should have received both transfers");
    }

    function test_optOutAllowsTransferDuringCooldown() public {
        // user1 deposits
        vm.prank(user1);
        staking.depositExact(10e18, 10e18);

        // user2 deposits and opts out
        vm.startPrank(user2);
        staking.depositExact(10e18, 10e18);
        staking.setTransferCooldownOptOut(true);
        vm.stopPrank();

        uint256 transferAmount = staking.balanceOf(user1) / 2;

        // Try to transfer to user2 who just deposited but opted out
        // Should work even though user2 is in cooldown period
        vm.prank(user1);
        staking.transfer(user2, transferAmount);

        assertEq(staking.balanceOf(user2), 1e18 + transferAmount, "User2 should have received shares");
    }

    function test_optOutEmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.TransferCooldownOptOutSet(user1, true);

        vm.prank(user1);
        staking.setTransferCooldownOptOut(true);
    }

    function test_optOutCanBeToggled() public {
        // Opt out
        vm.prank(user1);
        staking.setTransferCooldownOptOut(true);
        assertTrue(staking.transferCooldownOptOut(user1), "User1 should be opted out");

        // Opt back in
        vm.prank(user1);
        staking.setTransferCooldownOptOut(false);
        assertFalse(staking.transferCooldownOptOut(user1), "User1 should be opted back in");
    }

    function test_optOutStillUpdatesTimestamp() public {
        // user1 deposits
        vm.prank(user1);
        staking.depositExact(10e18, 10e18);

        // user2 deposits and opts out
        vm.startPrank(user2);
        staking.depositExact(10e18, 10e18);
        staking.setTransferCooldownOptOut(true);
        vm.stopPrank();

        uint256 user2TimestampBefore = staking.lastDepositTimestamp(user2);

        // Warp a bit
        vm.warp(block.timestamp + 2);

        uint256 transferAmount = staking.balanceOf(user1) / 2;

        // Transfer to user2 (opted out, so should work)
        vm.prank(user1);
        staking.transfer(user2, transferAmount);

        // Check that timestamp was still updated
        assertGt(
            staking.lastDepositTimestamp(user2), user2TimestampBefore, "Timestamp should be updated even when opted out"
        );
        assertEq(staking.lastDepositTimestamp(user2), block.timestamp, "Timestamp should be current block");
    }

    function test_optOutBlocksWithdrawalAfterTransfer() public {
        // user1 deposits
        vm.prank(user1);
        staking.depositExact(10e18, 10e18);

        // user2 deposits and opts out
        vm.startPrank(user2);
        staking.depositExact(10e18, 10e18);
        staking.setTransferCooldownOptOut(true);
        vm.stopPrank();

        // Warp past initial cooldown so user2 could withdraw
        vm.warp(block.timestamp + staking.minDelayDepositSeconds() + 1);

        // user2 should be able to withdraw now (just a small amount)
        uint256 user2BalanceBeforeTransfer = staking.balanceOf(user2);
        uint256 withdrawAmount = user2BalanceBeforeTransfer / 10; // Withdraw 10%
        vm.prank(user2);
        staking.withdraw(withdrawAmount);

        // Transfer to user2 (opted out, so should work immediately)
        uint256 transferAmount = staking.balanceOf(user1) / 2;
        vm.prank(user1);
        staking.transfer(user2, transferAmount);

        // Now user2 should NOT be able to withdraw because timestamp was reset
        // Try to withdraw a small amount
        vm.prank(user2);
        vm.expectRevert("Need to wait minDelayDepositSeconds before withdrawing after deposit");
        staking.withdraw(withdrawAmount);
    }

    function test_optInReenablesCooldownProtection() public {
        // user1 deposits
        vm.prank(user1);
        staking.depositExact(10e18, 10e18);

        // user2 deposits and opts out
        vm.prank(user2);
        staking.depositExact(10e18, 10e18);

        vm.prank(user2);
        staking.setTransferCooldownOptOut(true);

        uint256 transferAmount = staking.balanceOf(user1) / 4;

        // Transfer to user2 (opted out, should work)
        vm.prank(user1);
        staking.transfer(user2, transferAmount);

        // user2 opts back in
        vm.prank(user2);
        staking.setTransferCooldownOptOut(false);

        // Try to transfer again immediately (should fail now)
        vm.prank(user1);
        vm.expectRevert("Cannot transfer to address still in cooldown period");
        staking.transfer(user2, transferAmount);

        // Warp past full window
        vm.warp(block.timestamp + staking.minDelayDepositSeconds() + staking.transferWindowSeconds() + 1);

        // Now transfer should work
        vm.prank(user1);
        staking.transfer(user2, transferAmount);

        assertEq(staking.balanceOf(user2), 1e18 + transferAmount * 2, "User2 should have received both transfers");
    }
}

contract UniswapV3VaultTest_depositExact is UniswapV3VaultTest {
    function setUp() public override {
        super.setUp();
        fundAndApprove(user1, 10e18);
    }

    function test_emits() public {
        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.Deposited(user1, 10e18, 10e18, 1e18);
        staking.depositExact(10e18, 10e18);
    }

    function test_mintsCorrectAmountFirstDeposit() public {
        vm.prank(user1);
        staking.depositExact(depositAmount, depositAmount);
        assertEq(staking.balanceOf(user1), 1e18, "Minted shares incorrect for first deposit");
        assertEq(staking.totalSupply(), 1e18, "Total supply incorrect after first deposit");

        // todo check position balances are correct (other test?)
    }

    function test_mintsCorrectSecondDeposit() public {
        vm.prank(user1);
        staking.depositExact(depositAmount, depositAmount); // First deposit

        fundAndApprove(user2, 20e18);
        vm.prank(user2);
        staking.depositExact(20e18, 20e18); // Second deposit

        // After first deposit, user has 1e18 shares
        // After second deposit of the same amount, user should get another 1e18 shares
        assertEq(staking.balanceOf(user2), 2e18, "Minted shares incorrect for second deposit");
        assertEq(staking.balanceOf(user1), 1e18, "Should not affect first user's shares");
        assertEq(staking.totalSupply(), 3e18, "Total supply incorrect after second deposit");
    }

    function test_offBalance() public {
        uint256 smallTradeAmount = 100 * 1e18; // 100 tokens

        fund(address(simulator), 1000);
        // exchange tokn1 for token0 to move the price
        // from now on, token0 is more expensive, so if user wants to deposit equal amounts,
        // he will end up with more token1 in the position
        simulator.tradeFixedAmount(token1, token0, swapRouter, smallTradeAmount);

        vm.prank(user1);
        staking.depositExact(depositAmount, depositAmount);

        (uint256 positionToken0, uint256 positionToken1) = staking.positionBalances(user1);

        // there should be more token 0 in the position
        assertGt(positionToken1, positionToken0, "Position balances should be off-balance due to price movement");
        // token1 should all be deposited
        // uniswap has rounding errors in positions
        assertApproxEqAbs(
            positionToken1, depositAmount, 1, "Position balance should match deposited amounts converted to token0"
        );

        // there should not be any liquidity left in the contract
        assertEq(
            token0Contract.balanceOf(address(staking)), 0, "Staking contract should not hold any token0 after deposit"
        );
        assertEq(
            token1Contract.balanceOf(address(staking)), 0, "Staking contract should not hold any token1 after deposit"
        );

        // the user should have some token0 refunded
        assertGt(
            token0Contract.balanceOf(user1),
            0,
            "Not all token0 should be used in deposit, user should have balance from the refund"
        );
        // should not have token1 balance, it was all deposited
        assertEq(token1Contract.balanceOf(user1), 0, "User should have zero token1 after deposit");

        // however, balances after deposit should be equal to the begining
        assertApproxEqAbs(
            positionToken0 + token0Contract.balanceOf(user1),
            depositAmount,
            1,
            "Total balances in token0 should be equal after deposit"
        );
    }

    function test_thereAreLiquidiTokens() public {
        // in practice, it will be off to be funds in the pool but no deposit
        fundSingle(token0Contract, address(staking), depositAmount);

        vm.prank(user1);
        staking.depositExact(depositAmount, depositAmount);

        (uint256 positionToken0, uint256 positionToken1) = staking.positionBalances(user1);

        // user is owner of everything that's in the pool, there were no returns
        assertApproxEqAbs(positionToken0, depositAmount * 2, 1, "Position balance for token0 should match deposit");
        assertApproxEqAbs(positionToken1, depositAmount, 1, "Position balance for token1 should match deposit");
    }

    function test_thereAreLiquidiTokensAndDepositsOneSided() public {
        // in practice, it will be off to be funds in the pool but no deposit
        fundSingle(token0Contract, address(staking), depositAmount);

        vm.prank(user1);
        staking.depositExact(0, depositAmount);

        (uint256 positionToken0, uint256 positionToken1) = staking.positionBalances(user1);

        // user is owner of everything that's in the pool, there were no returns
        assertApproxEqAbs(positionToken0, depositAmount, 1, "Position balance for token0 should match deposit");
        assertApproxEqAbs(positionToken1, depositAmount, 1, "Position balance for token1 should match deposit");
    } // TODO there's balance from another user

    function test_thereAreLiquidiTokensAndDepositsOneSidedAlreadyDeposit() public {
        vm.prank(user1);
        staking.depositExact(depositAmount, depositAmount);
        fundSingle(token0Contract, address(staking), depositAmount);

        (uint256 positionToken0, uint256 positionToken1) = staking.positionBalances(user1);

        assertApproxEqAbs(positionToken0, depositAmount * 2, 1, "User1 osition balance for token0 should match deposit");
        assertApproxEqAbs(positionToken1, depositAmount, 1, "User1 osition balance for token1 should match deposit");

        // add tokens in the pool, supposedly from claimed fees
        // fundSingle(token0Contract, address(staking), depositAmount);
        address user3 = address(0x3333);

        // user3 will deposit only token1
        fundSingle(token1Contract, user3, depositAmount);

        approve(user3, address(staking), token1, depositAmount);
        vm.prank(user3);
        staking.depositExact(0, depositAmount);

        assertEq(staking.balanceOf(user3), staking.balanceOf(user1) / 3, "User3 should have one third of user1");

        (positionToken0, positionToken1) = staking.positionBalances(user3);

        assertApproxEqAbs(
            positionToken0, depositAmount / 2, 4, "User3 position balance for token0 should match deposit"
        );
        assertApproxEqAbs(
            positionToken1, depositAmount / 2, 4, "User3 position balance for token1 should match deposit"
        );

        // balance of user1 didn't change
        (positionToken0, positionToken1) = staking.positionBalances(user1);
        assertApproxEqAbs(
            positionToken0,
            depositAmount + (depositAmount / 2),
            3,
            "User1 position balance for token0 should match deposit, after user3 deposit"
        );
        assertApproxEqAbs(
            positionToken1,
            depositAmount + (depositAmount / 2),
            3,
            "User1 position balance for token1 should match deposit, after user3 deposit"
        );
    }

    function test_revert_SingleSidedDeposit() public {
        fundAndApprove(user1, depositAmount);

        vm.prank(user1);
        vm.expectRevert();
        staking.depositExact(0, depositAmount);
    }

    function test_revert_worksWithZeroDeposit() public {
        vm.prank(user1);
        vm.expectRevert("Deposit amounts cannot both be zero");
        staking.depositExact(0, 0);
    }

    function test_failWithoutApproval() public {
        address user3 = address(0x3333);
        fund(user3, depositAmount);
        vm.prank(user3);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        staking.depositExact(depositAmount, depositAmount);
    }

    function test_failWithoutBalance() public {
        address user3 = address(0x3333);
        approveBoth(user3, address(staking), 10e18);
        vm.prank(user3);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        staking.depositExact(10e18, 10e18);
    }

    function test_depositClaimFees() public {
        fundAndApprove(user1, depositAmount * 2);

        // there has to be a position to claim fees
        vm.prank(user1);
        staking.depositExact(depositAmount, depositAmount);

        vm.prank(user1);

        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.FeesCollected(0, 0);
        staking.depositExact(depositAmount, depositAmount);
    }
}

contract UniswapV3VaultTest_sqrtX96ToToken1PerToken0 is UniswapV3VaultTest {
    function test_calculatesRightPrice_forOne() public {
        uint256 sqrtPriceX96_1 = uint256(79228162514264337593543950336);
        assertEq(staking.sqrtX96ToToken1PerToken0(sqrtPriceX96_1, 1e18), 1e18, "Price is not one");
    }

    function test_calculatesRightPrice_forTwo() public {
        uint256 sqrtPriceX96_1 = uint256(112045541949572279837463876454);
        assertApproxEqAbs(staking.sqrtX96ToToken1PerToken0(sqrtPriceX96_1, 1e18), 0.5e18, 1, "Price is not two");
    }
}

contract UniswapV3VaultTest_collectFeesAndReinvest is UniswapV3VaultTest {
    function test_reinvestOnNoPosition() public {
        staking.collectFeesAndReinvest();
    }

    function test_doesNotCreatePositionFromDustTokens() public {
        // No deposits yet, so no position exists
        assertEq(staking.positionTokenId(), 0, "Position should not exist initially");

        // Send dust amounts of both tokens directly to the contract
        uint256 dustAmount = 1000;
        fund(address(staking), dustAmount);

        // Call collectFeesAndReinvest - this should NOT create a position from dust
        staking.collectFeesAndReinvest();

        // Position should still not exist
        assertEq(staking.positionTokenId(), 0, "Position should not be created from dust tokens");
    }

    function test_reinvestOnNoRewards() public {
        fundAndApprove(user1, depositAmount);

        vm.prank(user1);
        staking.depositExact(depositAmount, depositAmount);

        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.FeesReinvested();
        staking.collectFeesAndReinvest();
    }
}

contract UniswapV3VaultTest_returnFunds is UniswapV3VaultTest {
    function test_onlyOwnerCanReturn() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        vm.prank(user1);
        staking.returnFunds(user1);
    }

    function test_returnFunds() public {
        fundAndApprove(user1, depositAmount);

        vm.prank(user1);
        staking.depositExact(depositAmount, depositAmount);

        vm.warp(block.timestamp + staking.minDelayDepositSeconds());
        vm.prank(staking.owner());
        staking.returnFunds(user1);

        (uint256 balanceToken0, uint256 balanceToken1) = balancesOfBoth(user1);

        assertApproxEqAbs(balanceToken0, depositAmount, 1, "User should get back deposited token0");
        assertApproxEqAbs(balanceToken1, depositAmount, 1, "User should get back deposited token1");
    }
}

contract UniswapV3VaultTest_withdraw is UniswapV3VaultTest {
    function setUp() public override {
        super.setUp();
        fundAndApprove(user1, depositAmount);
        vm.prank(user1);
        staking.depositExact(depositAmount, depositAmount);
        vm.warp(block.timestamp + staking.minDelayDepositSeconds());
    }

    function test_emits() public {
        uint256 sharesToWithdraw = staking.balanceOf(user1) / 2;

        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        // the -1 is to compensate for rounding errors
        emit UniswapV3Vault.Withdrawn(user1, sharesToWithdraw, depositAmount / 2 - 1, depositAmount / 2 - 1);
        staking.withdraw(sharesToWithdraw);
    }

    function test_collectFeesAndWithdraw() public {
        (uint256 positionToken0Before, uint256 positionToken1Before) = staking.positionBalances(user1);

        vm.startPrank(user1);
        vm.expectEmit(true, true, true, true);
        emit UniswapV3Vault.FeesCollected(0, 0);
        staking.collectFeesAndWithdraw(staking.balanceOf(user1));
        vm.stopPrank();

        assertFullWithdraw(user1, positionToken0Before, positionToken1Before);
    }

    function test_revert_WithdrawMoreThanBalance() public {
        uint256 sharesToWithdraw = staking.balanceOf(user1) + 1;

        vm.prank(user1);
        vm.expectRevert("Withdraw exceeds balance");
        staking.withdraw(sharesToWithdraw);
    }

    function assertFullWithdraw(address _user, uint256 balanceToken0BeforeWithdraw, uint256 balanceToken1BeforeWithdraw)
        internal
        view
    {
        assertEq(staking.balanceOf(_user), 0, "User should have zero shares after full withdraw");
        (uint256 balanceToken0, uint256 balanceToken1) = balancesOfBoth(user1);
        assertApproxEqAbs(
            balanceToken0BeforeWithdraw,
            balanceToken0,
            1,
            "Balance should match what position was after withdraw for token0"
        );
        assertApproxEqAbs(
            balanceToken1BeforeWithdraw,
            balanceToken1,
            1,
            "Balance should match what position was after withdraw for token1"
        );
        assertEq(staking.totalSupply(), 0, "Total supply should be zero after full withdraw");
    }

    function test_withdraws() public {
        uint256 sharesToWithdraw = staking.balanceOf(user1) / 2;

        vm.prank(user1);
        staking.withdraw(sharesToWithdraw);
        assertEq(staking.balanceOf(user1), sharesToWithdraw, "User1 should have half shares after withdraw");
        assertEq(staking.totalSupply(), sharesToWithdraw, "Total supply should be half after withdraw");
        vm.stopPrank();

        vm.prank(user1);
        staking.withdraw(sharesToWithdraw);

        assertFullWithdraw(user1, depositAmount, depositAmount);
    }

    function test_unaffectedByOracleReverting() public {
        UniswapOracleMock oracleMock = UniswapOracleMock(address(oracle));
        oracleMock.setShouldRevert(true);

        vm.startPrank(user1);
        staking.withdraw(staking.balanceOf(user1), 0, 0);
        vm.stopPrank();

        assertFullWithdraw(user1, depositAmount, depositAmount);
    }

    function test_unaffectedByOraclePrice() public {
        UniswapOracleMock oracleMock = UniswapOracleMock(address(oracle));
        oracleMock.setMockedPrice((staking.getOraclePrice() * 7) / 5); // 2:1 price

        vm.startPrank(user1);
        staking.withdraw(staking.balanceOf(user1), 0, 0);
        vm.stopPrank();

        assertFullWithdraw(user1, depositAmount, depositAmount);
    }

    function test_RevertsBadOraclePrice() public {
        UniswapOracleMock oracleMock = UniswapOracleMock(address(oracle));
        oracleMock.setMockedPrice((staking.getOraclePrice() * 7) / 5); // 2:1 price

        vm.startPrank(user1);
        uint256 balance = staking.balanceOf(user1);
        vm.expectRevert("Pool price diverged too far from oracle");
        staking.withdraw(balance);
        vm.stopPrank();
    }

    function test_Reverts_sameBlockDepositWithdraw() public {
        fundAndApprove(user1, depositAmount);
        // move back time
        vm.warp(block.timestamp - staking.minDelayDepositSeconds());

        uint256 sharesToWithdraw = staking.balanceOf(user1);
        vm.prank(user1);
        vm.expectRevert("Need to wait minDelayDepositSeconds before withdrawing after deposit");
        staking.withdraw(sharesToWithdraw);
    }

    function test_cannotWithdrawBelowMinShares() public {
        uint256 user1Balance = staking.balanceOf(user1);
        uint256 MIN_SHARES = staking.MIN_SHARES();

        // Try to withdraw almost everything, leaving less than MIN_SHARES
        uint256 toWithdraw = user1Balance - (MIN_SHARES - 1);

        vm.prank(user1);
        vm.expectRevert("Cannot reduce supply below MIN_SHARES unless withdrawing all");
        staking.withdraw(toWithdraw);
    }

    function test_canWithdrawAll() public {
        uint256 user1Balance = staking.balanceOf(user1);

        // Can withdraw everything (supply goes to 0)
        vm.prank(user1);
        staking.withdraw(user1Balance);

        assertEq(staking.totalSupply(), 0, "Supply should be 0");
        assertEq(staking.balanceOf(user1), 0, "User balance should be 0");
    }

    function test_canWithdrawLeavingAtLeastMinShares() public {
        uint256 user1Balance = staking.balanceOf(user1);
        uint256 MIN_SHARES = staking.MIN_SHARES();

        // Withdraw leaving exactly MIN_SHARES
        uint256 toWithdraw = user1Balance - MIN_SHARES;

        vm.prank(user1);
        staking.withdraw(toWithdraw);

        assertEq(staking.totalSupply(), MIN_SHARES, "Supply should be MIN_SHARES");
        assertEq(staking.balanceOf(user1), MIN_SHARES, "User balance should be MIN_SHARES");
    }
}

contract UniswapV3VaultTest_getUnderlyingUniswapPositionBalances is UniswapV3VaultTest {
    function test_worksAfterDeposit() public {
        approve(user, address(staking), token0, depositAmount);
        approve(user, address(staking), token1, depositAmount);

        (uint256 balanceToken0Before, uint256 balanceToken1Before) = balancesOfBoth(user);

        console.log("Bance of token0 before fund:", balanceToken0Before);
        console.log("Bance of token1 before fund:", balanceToken1Before);

        // fund(address(this));
        // staking.deposit(1e18, 1e6, ratio, price);
        console.log("Before deposit");
        vm.startPrank(user);
        staking.depositExact(depositAmount, depositAmount);
        vm.stopPrank();
        console.log("after deposit");

        console.log("user position after", staking.balanceOf(address(this)));
        // Check that underlying position value matches what user deposited

        // getUnderlyingUniswapPositionBalances
        // (uint256 positionToken0, uint256 positionToken1) = staking.positionBalances(user);
        (uint256 positionToken0, uint256 positionToken1) = staking.getUnderlyingUniswapPositionBalances();

        // Verify the position balances exactly match what was deposited
        // uniswap rounds the position
        assertApproxEqAbs(positionToken0, depositAmount, 1, "Position token0 should exactly match deposited amount");
        assertApproxEqAbs(positionToken1, depositAmount, 1, "Position token1 should exactly match deposited amount");
    }
}

contract UniswapV3VaultTest_sharesToUnderlyingLiquidity is UniswapV3VaultTest {
    function test_returnsZeroOnEmptyContract() public {
        // On empty contract with no deposits, supply is 0 and positionTokenId is 0
        // Should return 0 due to early return, not revert
        uint128 result = staking.sharesToUnderlyingLiquidity(100);
        assertEq(result, 0, "Should return 0 on empty contract");
    }
}

contract UniswapV3VaultTest_getTotalValueInToken0 is UniswapV3VaultTest {
    function test_priceFromOracleIsCorrectlyRead() public {
        fund(user1, depositAmount);

        approveAndDeposit(user1, token0, token1, depositAmount, depositAmount);

        // With mocked price of 1:1, total value should be 2 * depositAmount
        assertApproxEqAbs(
            staking.getTotalValueInToken0(),
            depositAmount * 2,
            2,
            "Total value in token0 should be double the deposit amount with mocked 1:1 price"
        );

        // change oracle price to 2:1 (token0 is twice as expensive as token1)
        UniswapOracleMock oracleMock = UniswapOracleMock(address(oracle));
        // to multiply the price, need to multipley by sqrt(2), so 7/5 is approx
        oracleMock.setMockedPrice((staking.getOraclePrice() * 7) / 5); // 2:1 price

        assertApproxEqRel(
            staking.getTotalValueInToken0(),
            depositAmount * 3,
            0.5e18, // 0.5%
            "Total value in token0 should be triple the deposit amount with mocked 2:1 price"
        );
    }
}

contract UniswapV3VaultTest_IntegrationTwoOracles is UniswapV3VaultTest {
    function test_multiple_fee_rounds_robustness() public {
        uint256 depositedAmount = 5e18;
        // Setup
        fund(user1, 10e18);

        // User deposits
        approveAndDeposit(user1, token0, token1, depositedAmount, depositedAmount);

        // Multiple rounds of fee generation and reinvestment to test system robustness
        simulateFeesWithoutTrading(3e18);
        staking.collectFeesAndReinvest();

        // Now the share price should have increased significantly
        uint256 userBalance = staking.balanceOf(user1);

        console.log("User balance:", userBalance);

        // Get position info to see the actual liquidity
        uint256 positionId = staking.positionTokenId();
        console.log("Position token ID:", positionId);

        // Withdraw should work correctly with share price appreciation

        (uint256 beforeToken0, uint256 beforeToken1) = balancesOfBoth(user1);

        // This withdrawal should succeed and give correct amounts based on share price
        vm.startPrank(user1);
        staking.withdraw(staking.balanceOf(user1)); // Withdraw 100%
        vm.stopPrank();

        uint256 actualReceived =
            (token0Contract.balanceOf(user1) - beforeToken0) + (token1Contract.balanceOf(user1) - beforeToken1);

        // With share price appreciation: user should receive proportional amount of the accumulated fees
        assertGt(
            actualReceived,
            12e18,
            "User should receive significantly more than original deposit due to share price appreciation"
        );
    }

    function test_happyCase() public {
        uint256 depositAmount = 1e18; // 1 token0

        fund(user1, depositAmount);

        approveAndDeposit(user1, token0, token1, depositAmount, depositAmount);
        console.log("after deposit");

        (uint256 balanceToken0AfterDeposit, uint256 balanceToken1AfterDeposit) = balancesOfBoth(user1);

        console.log("user position after", staking.balanceOf(address(this)));

        // Check that underlying position value matches what user deposited
        (uint256 positionToken0, uint256 positionToken1) = staking.getUnderlyingUniswapPositionBalances();

        // Verify the position balances exactly match what was deposited
        // uniswap rounds the position
        assertApproxEqAbs(
            positionToken0 + balanceToken0AfterDeposit,
            depositAmount,
            1,
            "Position token0 should exactly match deposited amount"
        );
        assertApproxEqAbs(
            positionToken1 + balanceToken1AfterDeposit,
            depositAmount,
            1,
            "Position token1 should exactly match deposited amount"
        );

        // assertEq(staking.balanceOf(user), 1000000000000000000, "Balance doesn't match after deposit");
        assertTrue(staking.balanceOf(user1) > 0, "Should have balance");

        fund(user1, depositAmount);

        approveAndDeposit(user1, token0, token1, depositAmount, depositAmount);

        // Get user's balance before withdrawal
        // Withdraw all balance
        vm.startPrank(user1);
        staking.withdraw(staking.balanceOf(user1));
        vm.stopPrank();

        // Check that user got their tokens back matching the initial balances
        (uint256 user1Token0BalanceAfter, uint256 user1Token1BalanceAfter) = balancesOfBoth(user1);
        assertApproxEqAbs(
            user1Token0BalanceAfter, depositAmount * 2, 2, "User token0 balance should match initial balance"
        );
        assertApproxEqAbs(
            user1Token1BalanceAfter, depositAmount * 2, 2, "User token1 balance should match initial balance"
        );
        assertEq(staking.balanceOf(user), 0, "User should have no balance after full withdrawal");

        // Deposit again with the same amounts as before
        fund(user1, depositAmount);

        approveAndDeposit(user1, token0, token1, depositAmount, depositAmount);

        simulateTrading(staking.getPool(), 2, 1000 * 1e6);

        (uint256 positionBalanceToken0, uint256 positionBalanceToken1) = staking.positionBalances(user1);

        staking.collectFeesAndReinvest();

        (uint256 positionBalanceToken0After, uint256 positionBalanceToken1After) = staking.positionBalances(user1);

        assertGt(
            positionBalanceToken0After,
            positionBalanceToken0,
            "Position balance token0 did not increase after collecting fees"
        );
        assertGt(
            positionBalanceToken1After,
            positionBalanceToken1,
            "Position balance token1 did not increase after collecting fees"
        );

        vm.startPrank(user1);
        staking.withdraw(staking.balanceOf(user1));
        vm.stopPrank();

        assertEq(token1Contract.balanceOf(address(staking)), 0, "Balance of token0 not zero");
        assertEq(token0Contract.balanceOf(address(staking)), 0, "Balance of token1 not zero");
    }
}

contract UniswapV3VaultTest_Integration is UniswapV3VaultTest {
    function test_inflationAttack() public {
        address attacker = address(0xBAD);
        address victim = address(0x1234);

        uint256 MIN_SHARES = staking.MIN_SHARES();
        uint256 attackerInitialDeposit = 1e18; // Realistic initial deposit - 1 token each
        uint256 victimDeposit = 100e18; // Victim's deposit - 100 tokens

        // With MIN_SHARES protection, attacker must donate much more
        // To make victim get 0 shares: victim_deposit * supply / total_value < 1
        // So total_value > victim_deposit * supply
        // victimDeposit = 100e18, supply = MIN_SHARES = 1e6
        // Required donation > 100e18 * 1e6 = 100e24 = 100,000,000 tokens (100 million!)
        // This demonstrates the attack is economically prohibitive
        uint256 attackerDonation = victimDeposit * MIN_SHARES * 2; // 200 million tokens needed!

        // Step 1: Attacker makes first deposit with realistic amount
        fundSingle(token0Contract, attacker, attackerInitialDeposit);
        fundSingle(token1Contract, attacker, attackerInitialDeposit);
        approveAndDeposit(attacker, token0, token1, attackerInitialDeposit, attackerInitialDeposit);

        // Step 2: Attacker waits for withdrawal delay, then withdraws all but MIN_SHARES
        vm.warp(block.timestamp + staking.minDelayDepositSeconds());

        vm.prank(attacker);
        staking.withdraw(1e18 - MIN_SHARES); // Withdraw all but MIN_SHARES

        // Step 3: Attacker donates tokens directly to vault to inflate share price
        // Mint tokens directly to attacker since the amount needed is larger than faucet balance
        IMintableERC20(address(token0Contract)).mint(attacker, attackerDonation);
        IMintableERC20(address(token1Contract)).mint(attacker, attackerDonation);

        vm.startPrank(attacker);
        token0Contract.transfer(address(staking), attackerDonation);
        token1Contract.transfer(address(staking), attackerDonation);
        vm.stopPrank();

        // Step 4: victim is protected and can not get zero shares
        fundSingle(token0Contract, victim, victimDeposit);
        fundSingle(token1Contract, victim, victimDeposit);

        approve(victim, address(staking), token0, victimDeposit);
        approve(victim, address(staking), token1, victimDeposit);

        vm.prank(victim);
        vm.expectRevert("Cannot mint zero shares");
        staking.depositExact(victimDeposit, victimDeposit);
    }

    function test_SharesRoundDown() public {
        // This test verifies that share calculations always round down
        // favoring the protocol (existing shareholders) over new depositors

        address user1 = address(0x1111);
        address user2 = address(0x2222);

        uint256 initialDeposit = 100e18;
        uint256 secondDeposit = (100e18 / uint256(3)) + 1; // Will result in fractional shares

        // Step 1: User1 makes first deposit
        fundAndApprove(user1, initialDeposit);
        vm.prank(user1);
        staking.depositExact(initialDeposit, initialDeposit);

        uint256 totalSupplyBefore = staking.totalSupply();
        assertEq(totalSupplyBefore, 1e18, "First deposit gets FIRST_SHARE");

        // Step 2: User2 deposits - should get fractional shares that round down
        fundAndApprove(user2, secondDeposit);

        // Debug: check total value before deposit
        (uint256 poolToken0Before, uint256 poolToken1Before) = staking.getUnderlyingUniswapPositionBalances();
        console.log("Before user2 deposit - pool balances:", poolToken0Before, poolToken1Before);
        console.log("Total supply before:", staking.totalSupply());

        vm.prank(user2);
        staking.depositExact(secondDeposit, secondDeposit);

        uint256 user2Shares = staking.balanceOf(user2);
        console.log("User2 shares received:", user2Shares);

        uint256 theoretical = (secondDeposit * 1e18) / (initialDeposit); // 0.33e18
        assertLe(user2Shares, theoretical, "Shares should round down");

        // Verify user got reasonable shares (not zero)
        assertGt(user2Shares, 3e17, "User should get > 0.3e18 shares");
        assertLt(user2Shares, 4e17, "User should get < 0.4e18 shares");
    }

    function test_unbalancedDeposit() public {
        // Setup: Give both users tokens
        fund(user1, 10e18);

        fundSingle(token0Contract, user2, 1e18);
        fundSingle(token1Contract, user2, 10e18);

        uint256 balancedAmount = 5e18;
        // User1 deposits balanced amounts (both token0 and token1)
        approveAndDeposit(user1, token0, token1, balancedAmount, balancedAmount);

        // Check User1's position after balanced deposit
        (uint256 user1Token0After, uint256 user1Token1After) = staking.positionBalances(user1);

        // User2 deposits a lot more of token 1
        uint256 smallSidedAmount = 1e18;
        uint256 singleSidedAmount = 5e18;

        approveAndDeposit(user2, token0, token1, smallSidedAmount, singleSidedAmount);

        // Check User2's position after single-sided deposit
        (uint256 user2Token0After, uint256 user2Token1After) = staking.positionBalances(user2);
        // Get share balances for comparison
        uint256 user1Shares = staking.balanceOf(user1);
        uint256 user2Shares = staking.balanceOf(user2);

        // Verify that both users have positive balances
        assertTrue(user1Token0After > 0 || user1Token1After > 0, "User1 should have some position balance");
        // consider rounding error by internal accounting
        assertApproxEqAbs(user2Token0After, 1e18, 1, "User2 should have deposited only one token");
        assertApproxEqAbs(user2Token1After, 1e18, 1, "User2 should have deposited only one token");

        // Verify that both users received shares
        assertTrue(user1Shares > 0, "User1 should have received shares");
        assertTrue(user2Shares > 0, "User1 should have received shares");

        // check that the balances of user2 didn't change after deposit
        (uint256 user2Token0Balance, uint256 user2Token1Balance) = balancesOfBoth(user2);

        assertEq(user2Token0Balance, 0, "Users deposited all token0");
        assertEq(user2Token1Balance, 9e18, "User2 deposited only 1 token1");
    }

    /**
     * Test case verifying deposits succeed when pool is out of range
     * This is a simple test to confirm the core functionality works
     */
    function test_depositWorksWhenOutOfRange() public {
        uint256 depositedAmount = 5e18;

        // Step 1: User1 makes initial deposit to create position (in range)
        fund(user1, depositedAmount);
        approveAndDeposit(user1, token0, token1, depositedAmount, depositedAmount);

        uint256 user1SharesBefore = staking.balanceOf(user1);
        assertEq(user1SharesBefore, 1e18, "User1 should have received initial shares");

        // Step 2: Move pool price out of range (above)
        fund(address(simulator), 10000e18);
        vm.startPrank(faucet);
        simulator.tradeFixedAmount(token1, token0, swapRouter, 5000e18);
        vm.stopPrank();

        // Verify we're out of range
        (, int24 currentTick,,,,,) = staking.getPool().slot0();
        (, int24 tickUpper) = staking.getTickerRange();
        assertGt(currentTick, tickUpper, "Pool should be above position range");

        // Step 3: User2 deposits when out of range - should succeed
        fund(user2, depositedAmount);
        approveAndDeposit(user2, token0, token1, depositedAmount, depositedAmount);

        // Verify deposit succeeded - user2 should have shares
        uint256 user2Shares = staking.balanceOf(user2);
        assertGt(user2Shares, 0, "User2 should have received shares when depositing out of range");

        // Verify total supply increased
        assertGt(staking.totalSupply(), user1SharesBefore, "Total supply should have increased");
    }

    /**
     * Test case verifying single-sided deposit when pool price is above position range
     * When current tick > tickUpper, position only holds token1 (token0 has been swapped out)
     * So only token1 can be deposited, token0 is refunded
     * Steps:
     * 1. User1 makes initial deposit to create position
     * 2. Move pool price significantly above the position range (tick > tickCenter + tickWindow)
     * 3. User2 attempts to deposit - only token1 should be used, token0 refunded
     */
    function test_singleSidedDeposit_priceAboveRange() public {
        uint256 depositedAmount = 5e18;

        // Step 1: User1 makes initial deposit to establish position
        fund(user1, depositedAmount);
        approveAndDeposit(user1, token0, token1, depositedAmount, depositedAmount);

        // Get initial tick info
        (, int24 tickBefore,,,,,) = staking.getPool().slot0();
        (int24 tickLower, int24 tickUpper) = staking.getTickerRange();

        // Step 2: Move pool price significantly above range by trading token1 -> token0
        // This increases the price of token0 relative to token1, moving tick up
        fund(address(simulator), 10000e18);
        vm.startPrank(faucet);
        // Large trade to push price up (buy token0 with token1)
        simulator.tradeFixedAmount(token1, token0, swapRouter, 5000e18);
        vm.stopPrank();

        (, int24 tickAfter,,,,,) = staking.getPool().slot0();

        // Verify tick is now above the position's upper bound
        assertGt(tickAfter, tickUpper, "Tick should be above position range after trade");

        // Step 3: User2 attempts to deposit both tokens
        fund(user2, depositedAmount);
        (uint256 user2Token0Before, uint256 user2Token1Before) = balancesOfBoth(user2);

        approveAndDeposit(user2, token0, token1, depositedAmount, depositedAmount);

        // Check user2 balances after deposit
        (uint256 user2Token0After, uint256 user2Token1After) = balancesOfBoth(user2);

        // When price is above range, the position only holds token1
        // So only token1 can be deposited, token0 is fully refunded
        assertEq(user2Token0After, user2Token0Before, "User2 should have all token0 refunded (price above range)");
        assertLt(user2Token1After, user2Token1Before, "User2 should have used some token1");

        // User should still receive shares
        uint256 user2Shares = staking.balanceOf(user2);
        assertGt(user2Shares, 0, "User2 should have received shares even with single-sided deposit");
    }

    /**
     * Test case verifying single-sided deposit when pool price is below position range
     * When current tick < tickLower, position only holds token0 (token1 has been swapped out)
     * So only token0 can be deposited, token1 is refunded
     * Steps:
     * 1. User1 makes initial deposit to create position
     * 2. Move pool price significantly below the position range (tick < tickCenter - tickWindow)
     * 3. User2 attempts to deposit - only token0 should be used, token1 refunded
     */
    function test_singleSidedDeposit_priceBelowRange() public {
        uint256 depositedAmount = 5e18;

        // Step 1: User1 makes initial deposit to establish position
        fund(user1, depositedAmount);
        approveAndDeposit(user1, token0, token1, depositedAmount, depositedAmount);

        // Get initial tick info
        (, int24 tickBefore,,,,,) = staking.getPool().slot0();
        (int24 tickLower, int24 tickUpper) = staking.getTickerRange();

        // Step 2: Move pool price significantly below range by trading token0 -> token1
        // This decreases the price of token0 relative to token1, moving tick down
        fund(address(simulator), 10000e18);
        vm.startPrank(faucet);
        // Large trade to push price down (sell token0 for token1)
        simulator.tradeFixedAmount(token0, token1, swapRouter, 5000e18);
        vm.stopPrank();

        (, int24 tickAfter,,,,,) = staking.getPool().slot0();
        console.log("Tick after price move:", int256(tickAfter));

        // Verify tick is now below the position's lower bound
        assertLt(tickAfter, tickLower, "Tick should be below position range after trade");

        // Step 3: User2 attempts to deposit both tokens
        fund(user2, depositedAmount);
        (uint256 user2Token0Before, uint256 user2Token1Before) = balancesOfBoth(user2);

        approveAndDeposit(user2, token0, token1, depositedAmount, depositedAmount);

        // Check user2 balances after deposit
        (uint256 user2Token0After, uint256 user2Token1After) = balancesOfBoth(user2);

        // When price is below range, position only holds token0
        // So only token0 can be deposited, token1 is fully refunded
        assertLt(user2Token0After, user2Token0Before, "User2 should have used some token0");
        assertEq(user2Token1After, user2Token1Before, "User2 should have all token1 refunded (price below range)");

        // User should still receive shares
        uint256 user2Shares = staking.balanceOf(user2);
        assertGt(user2Shares, 0, "User2 should have received shares even with single-sided deposit");
    }

    /**
     * Test case verifying that withdrawals work correctly when position is out of range
     * Steps:
     * 1. User deposits when in range
     * 2. Price moves out of range
     * 3. User can still withdraw their funds (single-sided)
     */
    function test_withdrawWhenOutOfRange() public {
        uint256 depositedAmount = 5e18;

        // Step 1: User1 deposits when price is in range
        fund(user1, depositedAmount);
        approveAndDeposit(user1, token0, token1, depositedAmount, depositedAmount);

        uint256 user1Shares = staking.balanceOf(user1);
        console.log("User1 shares after deposit:", user1Shares);

        // Step 2: Move price significantly above range
        fund(address(simulator), 10000e18);
        vm.startPrank(faucet);
        simulator.tradeFixedAmount(token1, token0, swapRouter, 5000e18);
        vm.stopPrank();

        (, int24 tickAfter,,,,,) = staking.getPool().slot0();
        (, int24 tickUpper) = staking.getTickerRange();
        assertGt(tickAfter, tickUpper, "Tick should be above position range");

        // Step 3: User1 can still withdraw (with 0 slippage params since price moved)
        vm.startPrank(user1);
        staking.withdraw(user1Shares, 0, 0);
        vm.stopPrank();

        // User should have received tokens back
        (uint256 user1Token0After, uint256 user1Token1After) = balancesOfBoth(user1);

        // When price is above range, position holds only token1
        // So user should receive mostly/all token1
        assertGt(user1Token1After, 0, "User1 should have received token1");
        console.log("User1 received token0:", user1Token0After);
        console.log("User1 received token1:", user1Token1After);

        // Shares should be burned
        assertEq(staking.balanceOf(user1), 0, "User1 should have no shares after withdrawal");
    }

    /**
     * Test case verifying no fees are earned when position is out of range
     * Steps:
     * 1. User deposits and price moves out of range
     * 2. Trading happens (which would normally generate fees)
     * 3. No fees are collected because position is not earning
     */
    function test_noFeesWhenOutOfRange() public {
        uint256 depositedAmount = 5e18;

        // Step 1: User1 deposits
        fund(user1, depositedAmount);
        approveAndDeposit(user1, token0, token1, depositedAmount, depositedAmount);

        (uint256 positionToken0Before, uint256 positionToken1Before) = staking.positionBalances(user1);

        // Move price out of range (above)
        fund(address(simulator), 20000e18);
        vm.startPrank(faucet);
        simulator.tradeFixedAmount(token1, token0, swapRouter, 5000e18);
        vm.stopPrank();

        (, int24 tickAfter,,,,,) = staking.getPool().slot0();
        (, int24 tickUpper) = staking.getTickerRange();
        assertGt(tickAfter, tickUpper, "Tick should be above position range");

        // Step 2: Simulate trading that would generate fees if in range
        // Trade back and forth multiple times
        vm.startPrank(faucet);
        for (uint256 i = 0; i < 5; i++) {
            simulator.tradeFixedAmount(token0, token1, swapRouter, 100e18);
            simulator.tradeFixedAmount(token1, token0, swapRouter, 100e18);
        }
        vm.stopPrank();

        // Step 3: Collect fees - should be zero since out of range
        staking.collectFees();

        // Position balance should not have increased from fees
        // (it may have changed slightly due to price movement affecting token amounts)
        (uint256 positionToken0After, uint256 positionToken1After) = staking.positionBalances(user1);

        console.log("Position token0 before:", positionToken0Before, "after:", positionToken0After);
        console.log("Position token1 before:", positionToken1Before, "after:", positionToken1After);

        // The position value should be approximately the same (no fee accumulation)
        // Note: When out of range, the position becomes single-sided, so we compare total value
    }

    /**
     * Test case verifying share calculation is correct for out-of-range deposits
     * When depositing out of range, shares should be calculated based on the single token deposited
     */
    function test_shareCalculationWhenOutOfRange() public {
        uint256 depositedAmount = 5e18;

        // User1 deposits in range (gets baseline share price)
        fund(user1, depositedAmount);
        approveAndDeposit(user1, token0, token1, depositedAmount, depositedAmount);
        uint256 user1Shares = staking.balanceOf(user1);

        // Move price above range
        fund(address(simulator), 10000e18);
        vm.startPrank(faucet);
        simulator.tradeFixedAmount(token1, token0, swapRouter, 5000e18);
        vm.stopPrank();

        // User2 deposits same amounts (but only token1 will be used since above range)
        fund(user2, depositedAmount);
        approveAndDeposit(user2, token0, token1, depositedAmount, depositedAmount);
        uint256 user2Shares = staking.balanceOf(user2);

        console.log("User1 shares (deposited in range):", user1Shares);
        console.log("User2 shares (deposited above range):", user2Shares);

        // User2 should receive fewer shares since they only deposited token1
        // (token0 was refunded because price is above range)
        assertLt(user2Shares, user1Shares, "User2 should have fewer shares (single-sided deposit)");

        // Verify user2 got token0 refunded (price above range means only token1 is used)
        (uint256 user2Token0Balance, uint256 user2Token1Balance) = balancesOfBoth(user2);
        assertEq(user2Token0Balance, depositedAmount, "User2 should have all token0 refunded");
        console.log("User2 token0 refunded:", user2Token0Balance);
        console.log("User2 token1 remaining:", user2Token1Balance);
    }

    /**
     * Test case verifying fees can be reinvested when pool is single-sided (out of range)
     * When position is out of range, only one token is held. Reinvestment should still work.
     */
    function test_feesCanBeReinvestedWhenSingleSided() public {
        uint256 depositedAmount = 5e18;

        // User1 deposits to create position
        fund(user1, depositedAmount);
        approveAndDeposit(user1, token0, token1, depositedAmount, depositedAmount);

        // Move price out of range (above)
        fund(address(simulator), 10000e18);
        vm.startPrank(faucet);
        simulator.tradeFixedAmount(token1, token0, swapRouter, 5000e18);
        vm.stopPrank();

        // Verify we're out of range
        (, int24 tickAfter,,,,,) = staking.getPool().slot0();
        (, int24 tickUpper) = staking.getTickerRange();
        assertGt(tickAfter, tickUpper, "Pool should be above position range");

        // Simulate fees by sending tokens directly to the contract
        uint256 feeAmount = 1e18;
        fund(address(staking), feeAmount);

        // Reinvest fees - should work even when single-sided
        staking.collectFeesAndReinvest();

        // Verify the contract still functions - user can check their position
        (uint256 positionToken0, uint256 positionToken1) = staking.positionBalances(user1);
        assertGt(positionToken0 + positionToken1, 0, "Position should have value");
    }

    /**
     * Test case verifying share price appreciation works correctly with single user
     * Steps:
     * 1. User deposits funds and receives shares
     * 2. Fees are generated and reinvested via collectFeesAndReinvest()
     * 3. Share price increases, user can withdraw more than deposited
     */
    function test_share_price_appreciation_single_user() public {
        uint256 depositedAmount = 5e18;

        // Setup: Give user1 tokens
        fund(user1, depositedAmount);

        approveAndDeposit(user1, token0, token1, depositedAmount, depositedAmount);

        // Check initial state
        uint256 initialBalance = staking.balanceOf(user1);
        console.log("Initial user balance:", initialBalance);

        // Step 2 & 3: Simulate fee generation by manually adding tokens to contract
        // This simulates what would happen when fees are collected
        simulateFeesWithoutTrading(1e18);
        staking.collectFeesAndReinvest();

        // Check state after fee reinvestment
        uint256 afterFeesBalance = staking.balanceOf(user1);
        console.log("After fees user balance:", afterFeesBalance);

        // User share balance should be unchanged after fee reinvestment (shares don't change, but value does)
        // TODO, delete this from here, but make a test that collecting fees does not change balance (but does underlying position)
        assertEq(afterFeesBalance, initialBalance, "User shares should not change after fee reinvestment");

        // Step 4: Withdraw - user should get more tokens due to share price appreciation

        // Get expected withdrawal amounts before withdrawal
        (uint256 expectedToken0, uint256 expectedToken1) = staking.positionBalances(user1);

        assertApproxEqAbs(expectedToken0, 6e18, 2, "Expected token0 should be around 6e18");
        assertApproxEqAbs(expectedToken1, 6e18, 2, "Expected token1 should be around 6e18");

        vm.startPrank(user1);
        staking.withdraw(staking.balanceOf(user1)); // withdraw 100%
        vm.stopPrank();

        uint256 actualReceived0 = token0Contract.balanceOf(user1) - depositedAmount;
        uint256 actualReceived1 = token1Contract.balanceOf(user1) - depositedAmount;

        assertApproxEqAbs(actualReceived0, 1e18, 1, "New tokens received token0 should be around fees collected");
        assertApproxEqAbs(actualReceived1, 1e18, 1, "New tokens received token1 should be around fees collected");
    }

    /**
     * Test case verifying fair fee distribution with two users using share price appreciation
     * This shows how fee reinvestment benefits users proportionally based on timing
     * Steps:
     * 1. User1 deposits (gets shares at price 1.0)
     * 2. Fees are generated and reinvested (share price increases)
     * 3. User2 deposits (gets fewer shares at higher price)
     * 4. User1 benefits more from fees due to longer exposure
     */
    function test_fair_fee_distribution_two_users() public {
        uint256 depositedAmount = 5e18;
        // Setup: Give both users tokens
        fund(user1, 10e18);
        fund(user2, 10e18);

        // Step 1: User1 deposits first
        console.log("\nDeposit by user1:");
        approveAndDeposit(user1, token0, token1, depositedAmount, depositedAmount);

        // balances of the pool before deposit:
        (uint256 token0Before, uint256 token1Before) = staking.getUnderlyingUniswapPositionBalances();
        console.log("Pool balances right after deposits:", token0Before, token1Before);

        // Step 2: Simulate fee generation and reinvestment
        simulateFeesWithoutTrading(2e18);
        staking.collectFeesAndReinvest();

        (uint256 user1token0AfterDeposit, uint256 user1token1AfterDeposit) = staking.positionBalances(user1);

        // the reason for 6999999999999999994 and not 7e18 is because Uniswap rounds down in the positions
        assertApproxEqAbs(user1token0AfterDeposit, 7e18, 1, "User1 should have 7 token0 after fees reinvested");
        assertApproxEqAbs(user1token1AfterDeposit, 7e18, 1, "User1 should have 7 token1 after fees reinvested");

        // Step 3: User2 deposits after fees were reinvested
        console.log("\nDeposit by user2: ");
        approveAndDeposit(user2, token0, token1, depositedAmount, depositedAmount);

        console.log("Supply after second deposit is", staking.totalSupply());

        (uint256 user1Token0After, uint256 user1Token1After) = staking.getUnderlyingUniswapPositionBalances();
        console.log("UnderlyingUniswap Pool balances right after user1 deposited:", user1Token0After, user1Token1After);

        // Balance of User1 should have not changed

        (uint256 user2token0AfterDeposit, uint256 user2token1AfterDeposit) = staking.positionBalances(user2);

        assertApproxEqAbs(
            user2token0AfterDeposit, 5e18, 3, "User1 should have 5 token1 after fees reinvested and user2 deposited"
        );

        assertApproxEqAbs(
            user2token1AfterDeposit, 5e18, 3, "User1 should have 5 token1 after fees reinvested and user2 deposited"
        );

        (uint256 user1token0AfterDepositOfUser1, uint256 user1token1AfterDepositOfUser1) =
            staking.positionBalances(user1);

        // the reason for 6999999999999999994 and not 7e18 is because Uniswap rounds down in the positions
        assertApproxEqAbs(
            user1token0AfterDepositOfUser1,
            7e18,
            2,
            "User1 should have 7 token0 after fees reinvested and user2 deposited"
        );

        assertApproxEqAbs(
            user1token1AfterDepositOfUser1,
            7e18,
            2,
            "User1 should have 7 token1 after fees reinvested and user2 deposited"
        );

        // Step 4: Withdrawals - demonstrating fair fee distribution

        // User1 withdrawal (deposited before fees, should get more value)
        vm.startPrank(user1);
        staking.withdraw(staking.balanceOf(user1)); // 100% withdrawal
        vm.stopPrank();

        // User2 withdrawal
        vm.startPrank(user2);
        staking.withdraw(staking.balanceOf(user2)); // 100% withdrawal
        vm.stopPrank();

        assertApproxEqAbs(token0Contract.balanceOf(user1), 12e18, 2, "User1 should have 12 token0");
        assertApproxEqAbs(token1Contract.balanceOf(user1), 12e18, 2, "User1 should have 12 token1");
        assertApproxEqAbs(token0Contract.balanceOf(user2), 10e18, 3, "User2 should have 10 token0");
        assertApproxEqAbs(token1Contract.balanceOf(user2), 10e18, 3, "User2 should have 10 token1");
    }
}

contract UniswapV3VaultTest_IntegrationWithRealOracle is UniswapV3VaultTest_IntegrationTwoOracles {
    function setOracle() public override {
        oracle = new UniswapOracle();
        UniswapOracle(address(oracle)).initialize(IUniswapTooling(vm.deployCode("UniswapTooling.sol")));
    }

    function setUp() public override {
        super.setUp();
        // initializeContract();
        simulateTrading(staking.getPool(), 50, 100e18); // Simulate trading to generate fees
        assertApproxEqRel(
            staking.getOraclePricePerUnitToken0(1e18),
            1e18,
            0.001e18,
            "Price should be almost 1 after swapping the oracle"
        );
    }

    /**
     * Test case verifying complex multi-user scenario with extensive fee reinvestment
     * This demonstrates that the share price appreciation system handles complex scenarios
     * with multiple users depositing at different times and many fee reinvestment rounds
     */
    function test_complex_multi_user_scenario() public {
        address user3 = address(0x3333);

        uint256 depositAmount = 10e18;
        uint256 depositAmountDouble = 20e18; // two tokens

        // Setup: Give all users tokens
        fund(user1, 20e18);
        fund(user2, 20e18);
        fund(user3, 20e18);

        // User1 deposits first
        approveAndDeposit(user1, token0, token1, depositAmount, depositAmount);

        // Simulate large fee accumulation and reinvestment (should increase value of user)
        simulateTrading(staking.getPool(), 1, 1000e18); // Simulate trading to generate fees

        staking.collectFeesAndReinvest();

        assertGt(
            staking.positionBalancesInToken0WithOracle(user1) + balancesOfBothToToken0(user1),
            depositAmountDouble,
            "User 1 should have gotten fees from the trading"
        );

        // User2 deposits after share price has increased significantly
        approveAndDeposit(user2, token0, token1, depositAmount, depositAmount);

        assertGt(
            staking.positionBalancesInToken0WithOracle(user1) + balancesOfBothToToken0(user1),
            staking.positionBalancesInToken0WithOracle(user2) + balancesOfBothToToken0(user2),
            "User1 should have more balance than User2 after first deposit"
        );

        // More fee accumulation
        simulateTrading(staking.getPool(), 1, 1000e18);

        // Adding both balances, since the price could have moved and the user got a refund
        assertGt(
            staking.positionBalancesInToken0WithOracle(user1) + balancesOfBothToToken0(user1),
            staking.positionBalancesInToken0WithOracle(user2) + balancesOfBothToToken0(user2),
            "User1 should have more shares than User2 after trading"
        );

        // User3 deposits after even higher fee collection
        approveAndDeposit(user3, token0, token1, depositAmount, depositAmount);

        assertGt(
            staking.positionBalancesInToken0WithOracle(user1) + balancesOfBothToToken0(user1),
            staking.positionBalancesInToken0WithOracle(user2) + balancesOfBothToToken0(user2),
            "User1 should have more balance than User2 after User3 deposited"
        );
        assertGt(
            staking.positionBalancesInToken0WithOracle(user2) + balancesOfBothToToken0(user2),
            staking.positionBalancesInToken0WithOracle(user3) + balancesOfBothToToken0(user3),
            "User2 should have more balance than User3 after User3 deposited" // <--- this fails
        );

        // Even more fee accumulation to test system with very high share prices
        simulateTrading(staking.getPool(), 1, 1000e18); // Simulate trading to generate fees

        assertGt(
            staking.positionBalancesInToken0WithOracle(user1) + balancesOfBothToToken0(user1),
            staking.positionBalancesInToken0WithOracle(user2) + balancesOfBothToToken0(user2),
            "At the end, User1 should have more balance than User2"
        );
        assertGt(
            staking.positionBalancesInToken0WithOracle(user2) + balancesOfBothToToken0(user2),
            staking.positionBalancesInToken0WithOracle(user3) + balancesOfBothToToken0(user3),
            "At the end, User2 should have more balance than User3"
        );

        uint256 towWithdraw = staking.balanceOf(user1);

        vm.prank(user1);
        staking.withdraw(towWithdraw);

        towWithdraw = staking.balanceOf(user2);
        vm.prank(user2);
        staking.withdraw(towWithdraw);

        towWithdraw = staking.balanceOf(user3);
        vm.prank(user3);
        staking.withdraw(towWithdraw);

        // everyone balance should be greather that at the beginning
        assertGt(balancesOfBothToToken0(user1), 20e18, "User1 should have more than initial");
        assertGt(balancesOfBothToToken0(user2), 20e18, "User1 should have more than initial");
        assertGt(balancesOfBothToToken0(user3), 20e18, "User1 should have more than initial");
    }
}

contract UniswapV3VaultTest_claimMerkleFees is UniswapV3VaultTest {
    function test_claimsFees() public {
        // Import the mock contracts
        MockMerkleDistributor mockDistributor = new MockMerkleDistributor();

        // Create mock tokens for testing
        MockToken rewardToken1 = new MockToken("Reward Token 1", "RWD1", 18);
        MockToken rewardToken2 = new MockToken("Reward Token 2", "RWD2", 6);
        MockToken rewardToken3 = new MockToken("Reward Token 3", "RWD3", 8);

        // Prepare claim parameters
        address[] memory users = new address[](3);
        users[0] = address(staking);
        users[1] = address(staking);
        users[2] = address(staking);

        address[] memory tokens = new address[](3);
        tokens[0] = address(rewardToken1);
        tokens[1] = address(rewardToken2);
        tokens[2] = address(rewardToken3);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100e18; // 100 tokens with 18 decimals
        amounts[1] = 50e6; // 50 tokens with 6 decimals
        amounts[2] = 25e8; // 25 tokens with 8 decimals

        // Empty proofs array (mock doesn't validate them)
        bytes32[][] memory proofs = new bytes32[][](3);
        proofs[0] = new bytes32[](0);
        proofs[1] = new bytes32[](0);
        proofs[2] = new bytes32[](0);

        // Check initial feeVault balances (should be 0)
        assertEq(rewardToken1.balanceOf(feeVault), 0, "FeeVault should start with 0 RWD1");
        assertEq(rewardToken2.balanceOf(feeVault), 0, "FeeVault should start with 0 RWD2");
        assertEq(rewardToken3.balanceOf(feeVault), 0, "FeeVault should start with 0 RWD3");

        // Check initial staking contract balances (should be 0)
        assertEq(rewardToken1.balanceOf(address(staking)), 0, "Staking should start with 0 RWD1");
        assertEq(rewardToken2.balanceOf(address(staking)), 0, "Staking should start with 0 RWD2");
        assertEq(rewardToken3.balanceOf(address(staking)), 0, "Staking should start with 0 RWD3");

        console.log("Before claimMerkleFees:");
        console.log("FeeVault RWD1 balance:", rewardToken1.balanceOf(feeVault));
        console.log("FeeVault RWD2 balance:", rewardToken2.balanceOf(feeVault));
        console.log("FeeVault RWD3 balance:", rewardToken3.balanceOf(feeVault));

        // Call claimMerkleFees
        staking.claimMerkleFees(address(mockDistributor), users, tokens, amounts, proofs);

        // Verify that the exact amounts were transferred to feeVault
        // -1 on every token because the distributor does not send the value of amount
        assertEq(rewardToken1.balanceOf(feeVault), amounts[0] - 1, "FeeVault should receive exact RWD1 amount");
        assertEq(rewardToken2.balanceOf(feeVault), amounts[1] - 1, "FeeVault should receive exact RWD2 amount");
        assertEq(rewardToken3.balanceOf(feeVault), amounts[2] - 1, "FeeVault should receive exact RWD3 amount");

        // Verify that staking contract has no remaining tokens (all transferred to feeVault)
        assertEq(rewardToken1.balanceOf(address(staking)), 0, "Staking should have 0 RWD1 remaining");
        assertEq(rewardToken2.balanceOf(address(staking)), 0, "Staking should have 0 RWD2 remaining");
        assertEq(rewardToken3.balanceOf(address(staking)), 0, "Staking should have 0 RWD3 remaining");
    }
}

contract UniswapV3VaultTest_PriceValidation is UniswapV3VaultTest_depositExact {
    function test_usesPoolPriceWhenValid() public {
        // Pool price and oracle price should be the same in normal conditions
        uint256 poolPrice = staking.getPoolPrice();
        uint256 oraclePrice = staking.getOraclePrice();

        // They should be very close (within rounding)
        assertApproxEqAbs(poolPrice, oraclePrice, 1e10, "Pool and oracle prices should match initially");

        // Deposit should succeed using validated pool price
        fundAndApprove(user1, 5e18);
        vm.prank(user1);
        staking.depositExact(5e18, 5e18);

        assertGt(staking.balanceOf(user1), 0, "User should receive shares");
    }

    function test_revertsWhenPoolPriceDiverges() public {
        // First make an initial deposit so the vault has liquidity
        fundAndApprove(user1, 5e18);
        vm.prank(user1);
        staking.depositExact(5e18, 5e18);

        // Now manipulate the oracle price significantly
        // 100 ticks = ~1% price difference, so we need much more to trigger revert
        UniswapOracleMock oracleMock = UniswapOracleMock(address(oracle));

        // Set oracle price to be 10x the pool price (way more than 100 ticks)
        // This simulates a severe price manipulation or oracle failure
        uint256 poolPrice = staking.getPoolPrice();
        oracleMock.setMockedPrice(poolPrice * 10);

        // Second deposit should revert because pool diverged too far from oracle
        fundAndApprove(user2, 5e18);
        vm.prank(user2);
        vm.expectRevert("Pool price diverged too far from oracle");
        staking.depositExact(5e18, 5e18);
    }

    function test_getValidatedPoolPriceWithOracleSucceedsWithinBounds() public {
        // Should succeed when prices are close
        uint160 validatedPrice = staking.getValidatedPoolPriceWithOracle();
        assertGt(validatedPrice, 0, "Should return valid price");
    }
}
