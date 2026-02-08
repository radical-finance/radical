pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts8/token/ERC20/IERC20.sol";

interface IRadicalVaultTwoTokens is IERC20 {
    function positionBalancesInToken0WithOracle(address account) external view returns (uint256 token0Deposited);
    function balanceToLiquidERC20Balance(uint256 balance) external view returns (uint256 token0Owed, uint256 token1Owed);
    function getTotalValueInToken0() external view returns (uint256 totalInToken0);
    function getOraclePricePerUnitToken0(uint256 amountToken1) external view returns (uint256 amountToken0);
    function depositExact(uint256 toDepositToken0, uint256 toDepositToken1) external;
    function depositExact(uint256 toDepositToken0, uint256 toDepositToken1, uint256 amount0Min, uint256 amount1Min)
        external;
    function withdraw(uint256 balance) external;
    function withdraw(uint256 balance, uint256 amount0Min, uint256 amount1Min) external;
    function collectFeesAndWithdraw(uint256 balance) external;
    function collectFees() external;
    function collectFeesAndReinvest() external returns (uint256 newLiquidity);
}
