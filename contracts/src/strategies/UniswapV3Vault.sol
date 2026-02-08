// SPDX-License-Identifier: CC-BY-NC-4.0

// THERE IS NO WARRANTY FOR THE PROGRAM, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN OTHERWISE STATED IN WRITING
// THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES PROVIDE THE PROGRAM “AS IS” WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED,
// INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE ENTIRE RISK AS
// TO THE QUALITY AND PERFORMANCE OF THE PROGRAM IS WITH YOU. SHOULD THE PROGRAM PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL NECESSARY SERVICING, REPAIR OR CORRECTION.

// IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MODIFIES AND/OR CONVEYS THE PROGRAM AS PERMITTED
// ABOVE, BE LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE THE PROGRAM (INCLUDING
// BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A FAILURE OF THE PROGRAM TO OPERATE WITH ANY OTHER PROGRAMS),
// EVEN IF SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.

pragma solidity ^0.8.20;

pragma abicoder v2;

import {SafeERC20} from "@openzeppelin/contracts8/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts8/utils/math/Math.sol";

// parent contracts
import {Initializable} from "@openzeppelin/contracts8/proxy/utils/Initializable.sol";
import {Ownable} from "@openzeppelin/contracts8/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts8/utils/ReentrancyGuard.sol";

// dependencies interfaces
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "@interfaces/adaptors/INonfungiblePositionManager.sol"; // COPY this
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC721Receiver} from "@openzeppelin/contracts8/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts8/token/ERC20/IERC20.sol";

// local interfaces of external projects
import {IMerkleCollector} from "@interfaces/external/IMerkleCollector.sol";
import {IUniswapOracle} from "@interfaces/IUniswapOracle.sol";
import {IRadicalVaultTwoTokens} from "@interfaces/IRadicalVaultTwoTokens.sol";

import {IUniswapTooling} from "@interfaces/adaptors/IUniswapTooling.sol";

// This is meant as a proof-of-concept of Radical on-chain strategies
// It is meant to be safe, that is, no user should be exposed to loss of funds
// However, it has known issues:
// * if the price is outside of the range, fees are not collected
// * the contract can not rebalance
// * is some scenarios, depending on timing, or doing calls in the wrong order, users can lose right to some rewards

contract UniswapV3Vault is IRadicalVaultTwoTokens, Initializable, Ownable, IERC721Receiver, ReentrancyGuard {
    uint256 public constant minDelayDepositSeconds = 5;

    // params
    IUniswapV3Factory public factory;
    INonfungiblePositionManager public nonfungiblePositionManager;
    IERC20 public token0;
    IERC20 public token1;
    uint24 public fee;
    address public feeVault;
    IUniswapOracle public oracleContract;
    uint32 public oracleTwapInterval;
    int24 public tickerWindow;
    int24 public tickerCenter;
    IUniswapTooling public uniswapTooling;

    // state
    uint256 public positionTokenId;

    mapping(address => uint256) public balances; // balance in shares
    uint256 public supply; // total shares issuesd
    uint256 public constant FIRST_SHARE = 1e18; // first deposit, arbitrary, gets one share

    mapping(address => uint256) public lastDepositTimestamp;

    // events
    event Deposited(address indexed user, uint256 token0, uint256 token1, uint256 balance);
    event Withdrawn(address indexed user, uint256 balance, uint256 amount0, uint256 amount1);

    event UniswapV3FactorySet(IUniswapV3Factory factory);
    event NonfungiblePositionManagerSet(INonfungiblePositionManager positionManager);
    event FeeSet(uint24 fee);
    event FeeVaultSet(address feeVault);
    event TickerCenterSet(int24 tickerCenter);
    event TickerWindowSet(int24 tickerWindow);
    event TokensSet(IERC20 token0, IERC20 token1);
    event OracleSet(IUniswapOracle oracle);
    event OracleTWAPIntervalSet(uint32 oracleTwapInterval);
    event UniswapToolingSet(IUniswapTooling uniswapTooling);

    event FeesCollected(uint256 amount0, uint256 amount1);
    event FeesReinvested();
    event OperatorFeesCollected();
    event PositionTokenIdSet(uint256 tokenId);

    event CallResult(bool success, bytes data);

    struct TokenPair {
        IERC20 tokenA;
        IERC20 tokenB;
    }

    struct TickerConfig {
        int24 tickerCenter;
        int24 tickerWindow;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() Ownable(msg.sender) {
        // Proxy pattern not implemented yet
        // _disableInitializers();
    }

    function initialize(
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        IUniswapOracle _oracle,
        uint32 _oracleTwapInterval,
        TokenPair calldata _tokens,
        uint24 _fee,
        address _feeVault,
        TickerConfig calldata _tickerConfig,
        IUniswapTooling _uniswapTooling
    ) external initializer onlyOwner {
        // Set and emit all configuration
        _setUniswapContracts(_factory, _nonfungiblePositionManager);
        fee = _fee;
        emit FeeSet(_fee);
        tickerWindow = _tickerConfig.tickerWindow;
        emit TickerWindowSet(_tickerConfig.tickerWindow);
        tickerCenter = _tickerConfig.tickerCenter;
        emit TickerCenterSet(_tickerConfig.tickerCenter);

        IUniswapV3Pool pool = getPool(_tokens.tokenA, _tokens.tokenB);
        // sort tokens in the same way uniswap would
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        emit TokensSet(token0, token1);

        _setFeeVault(_feeVault);

        // infinite approval to uniswap, so we don't have to do in every trade
        SafeERC20.forceApprove(token0, address(nonfungiblePositionManager), type(uint256).max);
        SafeERC20.forceApprove(token1, address(nonfungiblePositionManager), type(uint256).max);

        oracleContract = _oracle;
        emit OracleSet(_oracle);

        uniswapTooling = _uniswapTooling;
        emit UniswapToolingSet(_uniswapTooling);
        oracleTwapInterval = _oracleTwapInterval;
        emit OracleTWAPIntervalSet(oracleTwapInterval);
    }

    function _setFeeVault(address _feeVault) internal {
        feeVault = _feeVault;
        emit FeeVaultSet(_feeVault);
    }

    function _setUniswapContracts(IUniswapV3Factory _factory, INonfungiblePositionManager _nonfungiblePositionManager)
        internal
    {
        factory = _factory;
        emit UniswapV3FactorySet(_factory);

        nonfungiblePositionManager = _nonfungiblePositionManager;
        emit NonfungiblePositionManagerSet(_nonfungiblePositionManager);
    }

    // balances represent shares of the pool
    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function totalSupply() external view returns (uint256) {
        return supply;
    }

    function balanceToLiquidERC20Balance(uint256 balance)
        external
        view
        returns (uint256 token0Owed, uint256 token1Owed)
    {
        (token0Owed, token1Owed) = _balanceToLiquidERC20Balance(balance);
    }

    function _balanceToLiquidERC20Balance(uint256 balance)
        internal
        view
        returns (uint256 token0Owed, uint256 token1Owed)
    {
        if (balance == 0) {
            return (0, 0);
        }
        (token0Owed, token1Owed) = balanceOfBothTokens();
        token0Owed = (token0Owed * balance) / supply;
        token1Owed = (token1Owed * balance) / supply;
    }

    function getTotalValueInToken0() external view returns (uint256 totalInToken0) {
        uint256 sqrtPriceX96 = getOraclePrice();
        return _getTotalValueInToken0(sqrtPriceX96);
    }

    function _getTotalValueInToken0(uint256 sqrtPriceX96) internal view returns (uint256 totalInToken0) {
        (uint256 token0InPool, uint256 token1InPool) = getUnderlyingUniswapPositionBalances();
        (uint256 liquidToken0, uint256 liquidToken1) = balanceOfBothTokens();
        uint256 totalToken0 = token0InPool + liquidToken0;
        uint256 totalToken1 = token1InPool + liquidToken1;
        uint256 totalToken1InToken0 = sqrtX96ToToken1PerToken0(sqrtPriceX96, totalToken1);
        return totalToken0 + totalToken1InToken0;
    }

    function getOraclePricePerUnitToken0(uint256 _token1) external view returns (uint256) {
        return sqrtX96ToToken1PerToken0(getOraclePrice(), _token1);
    }

    function _getOraclePricePerUnitToken0(uint256 _token1) internal view returns (uint256) {
        return sqrtX96ToToken1PerToken0(getOraclePrice(), _token1);
    }

    function depositExact(uint256 toDepositToken0, uint256 toDepositToken1) external nonReentrant {
        // need to claim the fees first, because if not a user can get a flashloa and claim fees, of everyone
        _collectFees();

        lastDepositTimestamp[msg.sender] = block.timestamp;
        if (toDepositToken0 == 0 && toDepositToken1 == 0) {
            return;
        }

        SafeERC20.safeTransferFrom(token0, msg.sender, address(this), toDepositToken0);
        SafeERC20.safeTransferFrom(token1, msg.sender, address(this), toDepositToken1);

        // save a copy of the balance, in case that there's balance that can mess up the amounts and make revert
        (uint256 balanceToken0Before, uint256 balanceToken1Before) = balanceOfBothTokens();

        // at this point, the funds are balanced and ready to be deposited
        // add liquidity
        // liquidity is liquidity added

        // attempt to deposit as much as possible
        addLiquidity(balanceToken0Before, balanceToken1Before);

        (uint256 balanceToken0After, uint256 balanceToken1After) = balanceOfBothTokens();

        uint256 refundToken1;
        uint256 refundToken0;

        // refund the user everything that's not been deposited

        uint256 actuallyDepositedToken0 = Math.min(balanceToken0Before - balanceToken0After, toDepositToken0);

        if (toDepositToken0 > actuallyDepositedToken0) {
            refundToken0 = toDepositToken0 - actuallyDepositedToken0;
        }

        uint256 actuallyDepositedToken1 = Math.min(balanceToken1Before - balanceToken1After, toDepositToken1);

        if (toDepositToken1 > actuallyDepositedToken1) {
            refundToken1 = toDepositToken1 - actuallyDepositedToken1;
        }

        if (refundToken0 > 0) {
            SafeERC20.safeTransfer(token0, msg.sender, refundToken0);
        }

        if (refundToken1 > 0) {
            SafeERC20.safeTransfer(token1, msg.sender, refundToken1);
        }

        issueShareToUsers(actuallyDepositedToken0, actuallyDepositedToken1);
    }

    function withdraw(uint256 balance) external {
        _withdraw(balance);
    }

    // function that users should use, otherwise they can leave fees unclaimed
    function collectFeesAndWithdraw(uint256 balance) external {
        _collectFees();
        _withdraw(balance);
        _investLiquidtokens();
    }

    function _withdraw(uint256 sharesToWithdraw) internal {
        _withdraw(sharesToWithdraw, msg.sender);
    }

    function _withdraw(uint256 sharesToWithdraw, address receiver) internal {
        require(sharesToWithdraw <= balances[receiver], "Withdraw exceeds balance");
        // Radical is meant to be an end-user product, not a fundamental DeFi primitive
        // For that reason same-block manipulations should not be allowed as a security measure

        require(
            block.timestamp >= lastDepositTimestamp[receiver] + minDelayDepositSeconds,
            "Need to wait minDelayDepositSeconds before withdrawing after deposit"
        );

        uint128 poolLiquidity = _sharesToUnderlyingLiquidity(sharesToWithdraw);

        (uint256 liquidtoken0, uint256 liquidtoken1) = _balanceToLiquidERC20Balance(sharesToWithdraw);

        balances[receiver] -= sharesToWithdraw;
        supply -= sharesToWithdraw;

        // send proportional of token:
        SafeERC20.safeTransfer(token0, receiver, liquidtoken0);
        SafeERC20.safeTransfer(token1, receiver, liquidtoken1);

        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
            tokenId: positionTokenId,
            liquidity: poolLiquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });

        // tokens owned to the user
        (uint256 amount0ToBeCollected, uint256 amount1ToBeCollected) =
            nonfungiblePositionManager.decreaseLiquidity(params);

        INonfungiblePositionManager.CollectParams memory colectParams = INonfungiblePositionManager.CollectParams({
            tokenId: positionTokenId,
            recipient: receiver,
            amount0Max: uint128(amount0ToBeCollected),
            amount1Max: uint128(amount1ToBeCollected)
        });

        (uint256 actuallyCollected0, uint256 actuallyCollected1) = nonfungiblePositionManager.collect(colectParams);

        if (supply == 0) {
            _setTokenID(0);
        }

        emit Withdrawn(msg.sender, sharesToWithdraw, amount0ToBeCollected, amount1ToBeCollected);
    }

    function returnFunds(address user) external onlyOwner {
        uint256 balance = balances[user];
        require(balance > 0, "User has no balance");
        _withdraw(balance, user);
    }

    function setFeeVault(address _feeVault) external {
        require(msg.sender == feeVault, "Only current fee vault can change itself");
        require(_feeVault != address(0), "Fee vault can not be zero address");
        _setFeeVault(_feeVault);
    }

    // returns the total underlying position of the contract
    function getUnderlyingUniswapPositionBalances()
        public
        view
        returns (uint256 token0Deposited, uint256 token1Deposited)
    {
        require(positionTokenId != 0, "No position exists");

        (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidity,,,,) =
            nonfungiblePositionManager.positions(positionTokenId);

        (uint160 sqrtPriceX96,,,,,,) = getPool().slot0();

        uint160 sqrtRatioA = uniswapTooling.TickMath_getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioB = uniswapTooling.TickMath_getSqrtRatioAtTick(tickUpper);

        token0Deposited = uniswapTooling.LiquidityAmounts_getAmount0ForLiquidity(sqrtPriceX96, sqrtRatioB, liquidity);
        token1Deposited = uniswapTooling.LiquidityAmounts_getAmount1ForLiquidity(sqrtRatioA, sqrtPriceX96, liquidity);
    }

    function _sharesToUnderlyingLiquidity(uint256 balance) internal view returns (uint128) {
        if (positionTokenId == 0 || balance == 0) {
            return 0;
        }

        (,,,,,,, uint128 liquidity,,,,) = nonfungiblePositionManager.positions(positionTokenId);

        return uint128((liquidity * balance) / supply);
    }

    function sharesToUnderlyingLiquidity(uint256 balance) external view returns (uint128) {
        return _sharesToUnderlyingLiquidity(balance);
    }

    /**
     * @notice Convert a liquidity amount to token amounts without supply division
     * @param liquidityAmount The liquidity amount to convert
     * @return token0Amount The amount of token0
     * @return token1Amount The amount of token1
     */
    function liquidityAmountToTokens(uint256 liquidityAmount)
        public
        view
        returns (uint256 token0Amount, uint256 token1Amount)
    {
        require(positionTokenId != 0, "No position exists");

        // Get position info
        (,,,,, int24 tickLower, int24 tickUpper,,,,,) = nonfungiblePositionManager.positions(positionTokenId);

        (uint160 sqrtPriceX96,,,,,,) = getPool().slot0();

        uint160 sqrtRatioA = uniswapTooling.TickMath_getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioB = uniswapTooling.TickMath_getSqrtRatioAtTick(tickUpper);

        // Get token amounts for this portion of liquidity
        token0Amount =
            uniswapTooling.LiquidityAmounts_getAmount0ForLiquidity(sqrtPriceX96, sqrtRatioB, uint128(liquidityAmount));
        token1Amount =
            uniswapTooling.LiquidityAmounts_getAmount1ForLiquidity(sqrtRatioA, sqrtPriceX96, uint128(liquidityAmount));
    }

    // this doesn't include unclaimed fees.
    // those fees can't be calculated on-chain https://ethereum.stackexchange.com/questions/125594/how-can-i-read-the-unclaimed-fees-by-uniswap-v3-liquidity-providing-through-anot
    function positionBalances(address account) public view returns (uint256 token0Deposited, uint256 token1Deposited) {
        if (supply == 0) {
            return (0, 0);
        }
        uint256 balance = balances[account];

        uint256 liquidityOfUser = _sharesToUnderlyingLiquidity(balance);

        (token0Deposited, token1Deposited) = liquidityAmountToTokens(liquidityOfUser);

        // Add liquid ERC20 balances proportionally
        (uint256 liquidtoken0, uint256 liquidtoken1) = _balanceToLiquidERC20Balance(balance);

        token0Deposited += liquidtoken0;
        token1Deposited += liquidtoken1;
    }

    function positionBalancesInToken0(address account) external view returns (uint256 token0Deposited) {
        (uint256 token0Amount, uint256 token1Amount) = positionBalances(account);

        return token0Amount + _getOraclePricePerUnitToken0(token1Amount);
    }

    function getPool(IERC20 tokenA, IERC20 tokenB) public view returns (IUniswapV3Pool pool) {
        address poolAddress = factory.getPool(address(tokenA), address(tokenB), fee);
        require(poolAddress != address(0), "Pool not found");
        return IUniswapV3Pool(poolAddress);
    }

    function getPool() public view returns (IUniswapV3Pool pool) {
        return getPool(token0, token1);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function getOraclePrice() public view returns (uint256) {
        return oracleContract.sqrtPriceX96(getPool(), oracleTwapInterval);
    }

    function sqrtX96ToToken1PerToken0(uint256 sqrtX96, uint256 _token1) public pure returns (uint256) {
        return (((_token1 * sqrtX96) / (2 ** 96)) ** 2) / _token1;
    }

    function balanceOfBothTokens() internal view returns (uint256 token0Balance, uint256 token1Balance) {
        token0Balance = token0.balanceOf(address(this));
        token1Balance = token1.balanceOf(address(this));
    }

    function issueShareToUsers(uint256 depositedToken0, uint256 depositedToken1) internal {
        uint256 sharesToMint;
        if (supply == 0) {
            sharesToMint = FIRST_SHARE; // arbitrary first share
        } else {
            uint256 sqrtPriceX96 = getOraclePrice();
            uint256 totalValueInContract = _getTotalValueInToken0(sqrtPriceX96);

            uint256 totalValueOfDeposit = depositedToken0 + sqrtX96ToToken1PerToken0(sqrtPriceX96, depositedToken1);

            // uint256 totalValueOfDeposit = depositedToken0 + depositedToken1;
            // it's worksome to calculate how much the user will actually deposit into the pool
            // so we calculate how much the total value was before the deposit
            // at this point everything that was left uninvested must have been returned to the user
            sharesToMint = (totalValueOfDeposit * supply) / (totalValueInContract - totalValueOfDeposit);
        }

        supply = supply + sharesToMint;
        balances[msg.sender] += sharesToMint;
        emit Deposited(msg.sender, depositedToken0, depositedToken1, sharesToMint);
    }

    function collectFeesAndReinvest() external returns (uint256 newLiquidity) {
        return _collectFeesAndReinvest();
    }

    function _collectFeesAndReinvest() internal returns (uint256 newLiquidity) {
        _collectFees();

        newLiquidity = _investLiquidtokens();
        emit FeesReinvested();
    }

    function collectFees() external nonReentrant {
        // this withdraws everything that has not been collected
        // as drcreaseLiquidity has not been called before, it only collects fees
        require(positionTokenId != 0, "Can't collect fees without a position");
        _collectFees();
    }

    function _collectFees() internal {
        // so that one doesn't need to check this gain in external collectFees
        if (positionTokenId == 0) {
            return;
        }

        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: positionTokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (uint256 amount0, uint256 amount1) = nonfungiblePositionManager.collect(params);
        emit FeesCollected(amount0, amount1);
    }

    function _investLiquidtokens() internal nonReentrant returns (uint256 newLiquidity) {
        // Check for any tokens available in the contract
        (uint256 toReinvestToken0, uint256 toReinvestToken1) = balanceOfBothTokens();

        if (toReinvestToken0 == 0 || toReinvestToken1 == 0) {
            return 0;
        }

        // try depositing as much as possible into Uniswap
        newLiquidity = addLiquidity(toReinvestToken0, toReinvestToken1);
    }

    function _setTokenID(uint256 tokenId) internal {
        positionTokenId = tokenId;
        emit PositionTokenIdSet(positionTokenId);
    }

    // the input of this is from the script
    // this is not really deposit, this is addLiquidity
    // this function DOES NOT refund
    function addLiquidity(uint256 amount0ToMint, uint256 amount1ToMint) internal returns (uint256 liquidity) {
        uint256 amount0;
        uint256 amount1;

        if (positionTokenId == 0) {
            // theres no position, either the contract is new or it has been drained
            INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
                token0: address(token0),
                token1: address(token1),
                fee: fee,
                tickLower: -tickerWindow,
                tickUpper: tickerWindow,
                amount0Desired: amount0ToMint,
                amount1Desired: amount1ToMint,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            });

            uint256 tokenId;

            (tokenId, liquidity, amount0, amount1) = nonfungiblePositionManager.mint(params);

            _setTokenID(tokenId);
        } else {
            // there's a position already
            // before adding the position, we need to claim the position back
            INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
                .IncreaseLiquidityParams({
                tokenId: positionTokenId,
                amount0Desired: amount0ToMint,
                amount1Desired: amount1ToMint,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });

            (liquidity, amount0, amount1) = nonfungiblePositionManager.increaseLiquidity(params);
        }
    }

    // TODO move this to a composable contract
    function claimMerkleFees(
        address distributorContract,
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external nonReentrant {
        // before claiming rewards, store the balance of the tokens to be claimed
        uint256[] memory balancesBefore = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balancesBefore[i] = IERC20(tokens[i]).balanceOf(address(this));
        }

        IMerkleCollector(distributorContract).claim(users, tokens, amounts, proofs);

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 amountToTransfer = IERC20(tokens[i]).balanceOf(address(this)) - balancesBefore[i];
            SafeERC20.safeTransfer(IERC20(tokens[i]), feeVault, amountToTransfer);
        }
    }
}
