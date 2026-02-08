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

// parent contracts (upgradeable versions)
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

// dependencies interfaces
import {IUniswapV3Factory} from "v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "@interfaces/adaptors/INonfungiblePositionManager.sol"; // COPY this
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC721Receiver} from "@openzeppelin/contracts8/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts8/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts8/token/ERC20/extensions/IERC20Metadata.sol";

// local interfaces of external projects
import {IMerkleCollector} from "@interfaces/external/IMerkleCollector.sol";
import {IUniswapOracle} from "@interfaces/IUniswapOracle.sol";
import {IRadicalVaultTwoTokens} from "@interfaces/IRadicalVaultTwoTokens.sol";

import {IUniswapTooling} from "@interfaces/adaptors/IUniswapTooling.sol";
import {TickConfigLib, TickBounds} from "../libraries/TickConfigLib.sol";

// leaving here for easy aacess
// import {console} from "forge-std/Test.sol";

// This is meant as a proof-of-concept of Radical on-chain strategies
// It is meant to be safe, that is, no user should be exposed to loss of funds
// However, it has known issues:
// * if the price is outside of the range, fees are not collected
// * the contract can not rebalance
// * is some scenarios, depending on timing, or doing calls in the wrong order, users can lose right to some rewards

contract UniswapV3Vault is
    IRadicalVaultTwoTokens,
    OwnableUpgradeable,
    IERC721Receiver,
    ReentrancyGuardUpgradeable,
    ERC20Upgradeable
{
    uint256 public constant FIRST_SHARE = 1e18; // first deposit, arbitrary, gets one share
    uint256 public constant MIN_SHARES = 1e6; // minimum shares that must remain in pool (unless going to 0)
    uint160 public constant sqrtRatioAtTick0 = 1 << 96;

    RiskConfig internal _riskConfig;

    // params
    IUniswapV3Factory public factory;
    INonfungiblePositionManager public nonfungiblePositionManager;
    TokenPairSorted internal _tokens;
    uint24 public fee;
    address public feeVault;
    IUniswapOracle public oracleContract;
    uint32 public oracleTwapInterval;
    TickBounds internal _tickConfig;
    IUniswapTooling public uniswapTooling;

    // state
    uint256 public positionTokenId;

    mapping(address => uint256) public lastDepositTimestamp;
    mapping(address => bool) public transferCooldownOptOut;

    // events
    event Deposited(address indexed user, uint256 token0, uint256 token1, uint256 balance);
    event Withdrawn(address indexed user, uint256 balance, uint256 amount0, uint256 amount1);
    event TransferCooldownOptOutSet(address indexed user, bool optedOut);

    event UniswapV3FactorySet(IUniswapV3Factory factory);
    event NonfungiblePositionManagerSet(INonfungiblePositionManager positionManager);
    event FeeSet(uint24 fee);
    event FeeVaultSet(address feeVault);
    event TickConfigSet(TickBounds tickConfig);
    event TokensSet(TokenPairSorted tokens);
    event OracleSet(IUniswapOracle oracle);
    event OracleTWAPIntervalSet(uint32 oracleTwapInterval);
    event UniswapToolingSet(IUniswapTooling uniswapTooling);
    event RiskConfigSet(RiskConfig riskConfig);

    event VaultNameSet(string vaultName);
    event VaultSymbolSet(string vaultSymbol);

    event FeesCollected(uint256 amount0, uint256 amount1);
    event FeesReinvested();
    event OperatorFeesCollected();
    event PositionTokenIdSet(uint256 tokenId);

    event CallResult(bool success, bytes data);

    struct TokenPairUnsorted {
        IERC20 tokenA;
        IERC20 tokenB;
    }

    struct TokenPairSorted {
        IERC20 token0;
        IERC20 token1;
    }

    struct RiskConfig {
        uint24 maxTickDivergence; // max tick divergence between pool and oracle (e.g., 100 = ~1%)
        uint256 minDelayDepositSeconds; // minimum seconds between deposit and withdraw
        uint256 transferWindowSeconds; // additional seconds after minDelay before transfers allowed (gives user time to withdraw)
    }

    function initialize(
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        IUniswapOracle _oracle,
        uint32 _oracleTwapInterval,
        TokenPairUnsorted calldata _tokenPair,
        uint24 _fee,
        address _feeVault,
        TickBounds calldata tickBoundsParam,
        IUniswapTooling _uniswapTooling,
        RiskConfig calldata riskConfigParam
    ) external initializer {
        // Set and emit all configuration
        _setUniswapContracts(_factory, _nonfungiblePositionManager);

        fee = _fee;
        emit FeeSet(_fee);
        // Validate tickBounds (reverts if tickUpper <= tickLower)

        IUniswapV3Pool pool = getPool(_tokenPair.tokenA, _tokenPair.tokenB);

        _tickConfig = tickBoundsParam;
        // Validate tick configuration valid and against pool's tick spacing
        TickConfigLib.validate(tickBoundsParam, pool.tickSpacing());
        emit TickConfigSet(_tickConfig);

        // sort tokens in the same way uniswap would
        _tokens.token0 = IERC20(pool.token0());
        _tokens.token1 = IERC20(pool.token1());
        emit TokensSet(_tokens);

        {
            (string memory vaultName, string memory vaultSymbol) = _getNameAndSymbol(_tokens.token0, _tokens.token1);
            emit VaultNameSet(vaultName);
            emit VaultSymbolSet(vaultSymbol);
            __ERC20_init(vaultName, vaultSymbol);
        }

        _setFeeVault(_feeVault);

        // infinite approval to uniswap, so we don't have to do in every trade
        SafeERC20.forceApprove(_tokens.token0, address(nonfungiblePositionManager), type(uint256).max);
        SafeERC20.forceApprove(_tokens.token1, address(nonfungiblePositionManager), type(uint256).max);

        oracleContract = _oracle;
        emit OracleSet(_oracle);

        uniswapTooling = _uniswapTooling;
        emit UniswapToolingSet(_uniswapTooling);
        oracleTwapInterval = _oracleTwapInterval;
        emit OracleTWAPIntervalSet(oracleTwapInterval);

        _setRiskConfig(riskConfigParam);
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
    }

    function _setRiskConfig(RiskConfig calldata riskConfigParam) internal {
        _riskConfig = riskConfigParam;
        emit RiskConfigSet(_riskConfig);
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

    function _getNameAndSymbol(IERC20 tokenA, IERC20 tokenB)
        internal
        view
        returns (string memory vaultName, string memory vaultSymbol)
    {
        string memory symbolA = IERC20Metadata(address(tokenA)).symbol();
        string memory symbolB = IERC20Metadata(address(tokenB)).symbol();

        vaultSymbol = string(abi.encodePacked(symbolA, "-", symbolB));
        vaultName = string(abi.encodePacked("Radical Vault ", vaultSymbol));
    }

    function token0() public view returns (IERC20) {
        return _tokens.token0;
    }

    function token1() public view returns (IERC20) {
        return _tokens.token1;
    }

    function tickUpper() public view returns (int24) {
        return _tickConfig.tickUpper;
    }

    function tickLower() public view returns (int24) {
        return _tickConfig.tickLower;
    }

    function maxTickDivergence() public view returns (uint24) {
        return _riskConfig.maxTickDivergence;
    }

    function minDelayDepositSeconds() public view returns (uint256) {
        return _riskConfig.minDelayDepositSeconds;
    }

    function transferWindowSeconds() public view returns (uint256) {
        return _riskConfig.transferWindowSeconds;
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
        (token0Owed, token1Owed) = _balanceOfBothTokens();
        token0Owed = (token0Owed * balance) / totalSupply();
        token1Owed = (token1Owed * balance) / totalSupply();
    }

    function getTotalValueInToken0() external view returns (uint256 totalInToken0) {
        uint256 sqrtPriceX96 = getOraclePrice();
        return _getTotalValueInToken0(sqrtPriceX96);
    }

    function _getTotalValueInToken0(uint256 sqrtPriceX96) internal view returns (uint256 totalInToken0) {
        (uint256 token0InPool, uint256 token1InPool) = getUnderlyingUniswapPositionBalances();
        (uint256 liquidToken0, uint256 liquidToken1) = _balanceOfBothTokens();
        uint256 totalToken0 = token0InPool + liquidToken0;
        uint256 totalToken1 = token1InPool + liquidToken1;
        uint256 totalToken1InToken0 = sqrtX96ToToken1PerToken0(sqrtPriceX96, totalToken1);
        return totalToken0 + totalToken1InToken0;
    }

    function getOraclePricePerUnitToken0(uint256 _token1) external view returns (uint256) {
        return _getOraclePricePerUnitToken0(_token1);
    }

    function _getOraclePricePerUnitToken0(uint256 _token1) internal view returns (uint256) {
        return sqrtX96ToToken1PerToken0(getOraclePrice(), _token1);
    }

    function depositExact(uint256 toDepositToken0, uint256 toDepositToken1, uint256 amount0Min, uint256 amount1Min)
        external
        nonReentrant
    {
        _depositExact(toDepositToken0, toDepositToken1, amount0Min, amount1Min);
    }

    function depositExact(uint256 toDepositToken0, uint256 toDepositToken1) external nonReentrant {
        // automatically calculate slippage limits
        _depositExact(toDepositToken0, toDepositToken1, 0, 0);
    }

    function _depositExact(uint256 toDepositToken0, uint256 toDepositToken1, uint256 amount0Min, uint256 amount1Min)
        internal
    {
        getValidatedPoolPriceWithOracle();
        require(toDepositToken0 != 0 || toDepositToken1 != 0, "Deposit amounts cannot both be zero");
        // need to claim the fees first, because if not a user can get a flashloan and claim fees, of everyone
        _collectFees();

        _updateDepositTimestamp(msg.sender);

        SafeERC20.safeTransferFrom(_tokens.token0, msg.sender, address(this), toDepositToken0);
        SafeERC20.safeTransferFrom(_tokens.token1, msg.sender, address(this), toDepositToken1);

        // save a copy of the balance, in case that there's balance that can mess up the amounts and make revert
        (uint256 balanceToken0Before, uint256 balanceToken1Before) = _balanceOfBothTokens();

        // at this point, the funds are balanced and ready to be deposited

        // attempt to deposit as much as possible
        _addLiquidity(balanceToken0Before, balanceToken1Before, amount0Min, amount1Min);

        (uint256 balanceToken0After, uint256 balanceToken1After) = _balanceOfBothTokens();

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
            SafeERC20.safeTransfer(_tokens.token0, msg.sender, refundToken0);
        }

        if (refundToken1 > 0) {
            SafeERC20.safeTransfer(_tokens.token1, msg.sender, refundToken1);
        }

        _issueShareToUsers(actuallyDepositedToken0, actuallyDepositedToken1);
    }

    function withdraw(uint256 balance, uint256 amount0Min, uint256 amount1Min) external nonReentrant {
        _withdraw(balance, msg.sender, amount0Min, amount1Min, false);
    }

    function withdraw(uint256 balance) external nonReentrant {
        _withdraw(balance, msg.sender, 0, 0, true);
    }

    // function that users should use, otherwise they can leave fees unclaimed
    function collectFeesAndWithdraw(uint256 balance) external nonReentrant {
        _collectFees();
        _withdraw(balance, msg.sender, 0, 0, true);
        _investLiquidtokens();
    }

    function _withdraw(
        uint256 sharesToWithdraw,
        address receiver,
        uint256 amount0Min,
        uint256 amount1Min,
        bool validateOracle
    ) internal {
        if (validateOracle) getValidatedPoolPriceWithOracle();

        require(sharesToWithdraw <= balanceOf(receiver), "Withdraw exceeds balance");
        // Radical is meant to be an end-user product, not a fundamental DeFi primitive
        // For that reason same-block manipulations should not be allowed as a security measure

        require(
            block.timestamp >= lastDepositTimestamp[receiver] + _riskConfig.minDelayDepositSeconds,
            "Need to wait minDelayDepositSeconds before withdrawing after deposit"
        );

        uint128 poolLiquidity = _sharesToUnderlyingLiquidity(sharesToWithdraw);

        (uint256 liquidtoken0, uint256 liquidtoken1) = _balanceToLiquidERC20Balance(sharesToWithdraw);

        _burn(receiver, sharesToWithdraw);

        // Prevent supply from being reduced below MIN_SHARES (unless going to 0)
        // This protects against share inflation attacks
        require(
            totalSupply() == 0 || totalSupply() >= MIN_SHARES,
            "Cannot reduce supply below MIN_SHARES unless withdrawing all"
        );

        // send proportional of token:
        SafeERC20.safeTransfer(_tokens.token0, receiver, liquidtoken0);
        SafeERC20.safeTransfer(_tokens.token1, receiver, liquidtoken1);

        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: positionTokenId,
                liquidity: poolLiquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
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

        nonfungiblePositionManager.collect(colectParams);

        if (totalSupply() == 0) {
            _setTokenID(0);
        }

        emit Withdrawn(msg.sender, sharesToWithdraw, amount0ToBeCollected, amount1ToBeCollected);
    }

    function returnFunds(address user) external onlyOwner {
        uint256 balance = balanceOf(user);
        require(balance > 0, "User has no balance");
        _withdraw(balance, user, 0, 0, true);
    }

    /**
     * @notice Allows users to opt-out of transfer cooldown protection
     * @dev When opted out, users can receive transfers at any time, but their cooldown timestamp still updates
     *      This means they will be blocked from withdrawing for longer periods when receiving transfers
     * @param optOut True to opt-out of cooldown protection, false to opt-in (default)
     */
    function setTransferCooldownOptOut(bool optOut) external {
        transferCooldownOptOut[msg.sender] = optOut;
        emit TransferCooldownOptOutSet(msg.sender, optOut);
    }

    /**
     * @notice Override ERC20 update hook to enforce cooldown on transfers
     * @dev Implements transfer-based cooldown tracking to prevent griefing attacks
     *      This hook is called by _transfer, _mint, and _burn
     * @param from Address sending the shares (address(0) for mints)
     * @param to Address receiving the shares (address(0) for burns)
     * @param value Amount of shares being transferred/minted/burned
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        // Only apply transfer-specific logic for actual transfers (not mints/burns)
        if (from != address(0) && to != address(0)) {
            // Check cooldown only if receiver has NOT opted out
            // If opted out, they can receive transfers at any time (but timestamp still updates)
            if (!transferCooldownOptOut[to]) {
                // Prevent griefing attack: only allow transfers to addresses that have passed the full transfer window
                // This prevents attackers from spamming transfers to lock someone's funds indefinitely
                // The transfer window gives users time to withdraw after their minDelayDepositSeconds expires
                // Allow if: receiver is new (timestamp == 0) OR full window (minDelay + transferWindow) has passed
                require(
                    lastDepositTimestamp[to] == 0
                        || block.timestamp
                            >= lastDepositTimestamp[to] + _riskConfig.minDelayDepositSeconds
                                + _riskConfig.transferWindowSeconds,
                    "Cannot transfer to address still in cooldown period"
                );
            }

            // Update receiver's deposit timestamp to current block
            // This resets their withdrawal cooldown period
            // NOTE: This happens even if user opted out, so they will be blocked from withdrawing
            _updateDepositTimestamp(to);
        }

        // Execute the update (transfer/mint/burn) after all checks pass
        super._update(from, to, value);
    }

    /**
     * @notice Updates the deposit timestamp for an account
     * @dev Used to track cooldown period for withdrawals
     * @param account Address to update timestamp for
     */
    function _updateDepositTimestamp(address account) internal {
        lastDepositTimestamp[account] = block.timestamp;
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

        (,,,,, int24 posTickLower, int24 posTickUpper, uint128 liquidity,,,,) =
            nonfungiblePositionManager.positions(positionTokenId);

        (uint160 sqrtPriceX96,,,,,,) = getPool().slot0();

        uint160 sqrtRatioA = uniswapTooling.TickMath_getSqrtRatioAtTick(posTickLower);
        uint160 sqrtRatioB = uniswapTooling.TickMath_getSqrtRatioAtTick(posTickUpper);

        (token0Deposited, token1Deposited) =
            uniswapTooling.LiquidityAmounts_getAmountsForLiquidity(sqrtPriceX96, sqrtRatioA, sqrtRatioB, liquidity);
    }

    function _sharesToUnderlyingLiquidity(uint256 balance) internal view returns (uint128) {
        if (positionTokenId == 0 || balance == 0) {
            return 0;
        }

        require(totalSupply() > 0, "Total supply must be greater than zero");

        (,,,,,,, uint128 liquidity,,,,) = nonfungiblePositionManager.positions(positionTokenId);

        return uint128((liquidity * balance) / totalSupply());
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
        (uint160 sqrtPriceX96,,,,,,) = getPool().slot0();

        (token0Amount, token1Amount) = liquidityAmountToTokens(liquidityAmount, sqrtPriceX96);
    }

    function liquidityAmountToTokensUsingOracle(uint256 liquidityAmount)
        public
        view
        returns (uint256 token0Amount, uint256 token1Amount)
    {
        uint160 sqrtPriceX96 = uint160(getOraclePrice());

        (token0Amount, token1Amount) = liquidityAmountToTokens(liquidityAmount, sqrtPriceX96);
    }

    function getTickerRange() public view returns (int24, int24) {
        return (_tickConfig.tickLower, _tickConfig.tickUpper);
    }

    function liquidityAmountToTokens(uint256 liquidityAmount, uint160 sqrtPriceX96)
        public
        view
        returns (uint256 token0Amount, uint256 token1Amount)
    {
        require(positionTokenId != 0, "No position exists");

        (int24 lowerTick, int24 upperTick) = getTickerRange();
        uint160 sqrtRatioA = uniswapTooling.TickMath_getSqrtRatioAtTick(lowerTick);
        uint160 sqrtRatioB = uniswapTooling.TickMath_getSqrtRatioAtTick(upperTick);

        // Get token amounts for this portion of liquidity
        token0Amount =
            uniswapTooling.LiquidityAmounts_getAmount0ForLiquidity(sqrtPriceX96, sqrtRatioB, uint128(liquidityAmount));
        token1Amount =
            uniswapTooling.LiquidityAmounts_getAmount1ForLiquidity(sqrtRatioA, sqrtPriceX96, uint128(liquidityAmount));
    }

    // this doesn't include unclaimed fees.
    // those fees can't be calculated on-chain https://ethereum.stackexchange.com/questions/125594/how-can-i-read-the-unclaimed-fees-by-uniswap-v3-liquidity-providing-through-anot
    function positionBalances(address account) public view returns (uint256 token0Deposited, uint256 token1Deposited) {
        if (totalSupply() == 0) {
            return (0, 0);
        }
        uint256 balance = balanceOf(account);

        uint256 liquidityOfUser = _sharesToUnderlyingLiquidity(balance);

        (token0Deposited, token1Deposited) = liquidityAmountToTokens(liquidityOfUser);

        // Add liquid ERC20 balances proportionally
        (uint256 liquidtoken0, uint256 liquidtoken1) = _balanceToLiquidERC20Balance(balance);

        token0Deposited += liquidtoken0;
        token1Deposited += liquidtoken1;
    }

    function positionBalancesInToken0WithOracle(address account) external view returns (uint256 token0Deposited) {
        (uint256 token0Amount, uint256 token1Amount) = positionBalances(account);

        return token0Amount + _getOraclePricePerUnitToken0(token1Amount);
    }

    function getPool(IERC20 tokenA, IERC20 tokenB) public view returns (IUniswapV3Pool pool) {
        address poolAddress = factory.getPool(address(tokenA), address(tokenB), fee);
        require(poolAddress != address(0), "Pool not found");
        return IUniswapV3Pool(poolAddress);
    }

    function getPool() public view returns (IUniswapV3Pool pool) {
        return getPool(_tokens.token0, _tokens.token1);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function getOraclePrice() public view returns (uint256) {
        return oracleContract.sqrtPriceX96(getPool(), oracleTwapInterval);
    }

    function getPoolPrice() public view returns (uint160) {
        (uint160 sqrtPriceX96,,,,,,) = getPool().slot0();
        return sqrtPriceX96;
    }

    /**
     * @notice Gets the pool price and validates it against oracle price
     * @dev Reverts if pool price diverges from oracle by more than maxTickDivergence
     * @return sqrtPriceX96 The pool's current sqrtPriceX96
     */
    function getValidatedPoolPriceWithOracle() public view returns (uint160 sqrtPriceX96) {
        sqrtPriceX96 = getPoolPrice();
        uint256 oracleSqrtPriceX96 = getOraclePrice();

        // Calculate the multiplier for maxTickDivergence ticks
        // Upper bound: oracle * (sqrtRatioAtTickD / sqrtRatioAtTick0)
        // Lower bound: oracle * (sqrtRatioAtTick0 / sqrtRatioAtTickD)
        require(
            sqrtPriceX96
                    >= (oracleSqrtPriceX96 * sqrtRatioAtTick0)
                        / uniswapTooling.TickMath_getSqrtRatioAtTick(int24(_riskConfig.maxTickDivergence))
                && sqrtPriceX96
                    <= (oracleSqrtPriceX96
                            * uniswapTooling.TickMath_getSqrtRatioAtTick(int24(_riskConfig.maxTickDivergence)))
                        / sqrtRatioAtTick0,
            "Pool price diverged too far from oracle"
        );

        return sqrtPriceX96;
    }

    function sqrtX96ToToken1PerToken0(uint256 sqrtX96, uint256 _token1) public pure returns (uint256) {
        if (_token1 == 0) {
            return 0;
        }
        return (((_token1 * (2 ** 96)) / sqrtX96) ** 2) / _token1;
    }

    function _balanceOfBothTokens() internal view returns (uint256 token0Balance, uint256 token1Balance) {
        token0Balance = _tokens.token0.balanceOf(address(this));
        token1Balance = _tokens.token1.balanceOf(address(this));
    }

    function _issueShareToUsers(uint256 depositedToken0, uint256 depositedToken1) internal {
        uint256 sharesToMint;
        if (totalSupply() == 0) {
            sharesToMint = FIRST_SHARE; // arbitrary first share
        } else {
            // Use pool price (validated against oracle) instead of pure oracle price
            // This ensures we use current liquidity conditions while protecting against manipulation
            uint256 sqrtPriceX96 = getValidatedPoolPriceWithOracle();
            uint256 totalValueInContract = _getTotalValueInToken0(sqrtPriceX96);

            uint256 totalValueOfDeposit = depositedToken0 + sqrtX96ToToken1PerToken0(sqrtPriceX96, depositedToken1);

            // uint256 totalValueOfDeposit = depositedToken0 + depositedToken1;
            // it's worksome to calculate how much the user will actually deposit into the pool
            // so we calculate how much the total value was before the deposit
            // at this point everything that was left uninvested must have been returned to the user
            sharesToMint = (totalValueOfDeposit * totalSupply()) / (totalValueInContract - totalValueOfDeposit);
        }

        require(sharesToMint > 0, "Cannot mint zero shares");

        _mint(msg.sender, sharesToMint);
        emit Deposited(msg.sender, depositedToken0, depositedToken1, sharesToMint);
    }

    function collectFeesAndReinvest() external nonReentrant returns (uint256 newLiquidity) {
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

    function _investLiquidtokens() internal returns (uint256 newLiquidity) {
        if (totalSupply() == 0) return 0;
        // Check for any tokens available in the contract
        (uint256 toReinvestToken0, uint256 toReinvestToken1) = _balanceOfBothTokens();

        if (toReinvestToken0 == 0 && toReinvestToken1 == 0) {
            return 0;
        }

        getValidatedPoolPriceWithOracle();

        // Try depositing into Uniswap with oracle-based minimums
        // If pool price is manipulated, this will revert with "Price slippage check"
        newLiquidity = _addLiquidity(toReinvestToken0, toReinvestToken1, 0, 0);
    }

    function _setTokenID(uint256 tokenId) internal {
        positionTokenId = tokenId;
        emit PositionTokenIdSet(positionTokenId);
    }

    // the input of this is from the script
    // this is not really deposit, this is addLiquidity
    // this function DOES NOT refund
    function _addLiquidity(uint256 amount0ToMint, uint256 amount1ToMint, uint256 amount0Min, uint256 amount1Min)
        internal
        returns (uint256 liquidity)
    {
        uint256 amount0;
        uint256 amount1;

        if (positionTokenId == 0) {
            // theres no position, either the contract is new or it has been drained
            (int24 lowerTick, int24 upperTick) = getTickerRange();
            INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
                token0: address(_tokens.token0),
                token1: address(_tokens.token1),
                fee: fee,
                tickLower: lowerTick,
                tickUpper: upperTick,
                amount0Desired: amount0ToMint,
                amount1Desired: amount1ToMint,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                recipient: address(this),
                deadline: block.timestamp
            });

            uint256 tokenId;

            (tokenId, liquidity, amount0, amount1) = nonfungiblePositionManager.mint(params);

            _setTokenID(tokenId);
        } else {
            // there's a position already
            // before adding the position, we need to claim the position back
            INonfungiblePositionManager.IncreaseLiquidityParams memory params =
                INonfungiblePositionManager.IncreaseLiquidityParams({
                    tokenId: positionTokenId,
                    amount0Desired: amount0ToMint,
                    amount1Desired: amount1ToMint,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
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
