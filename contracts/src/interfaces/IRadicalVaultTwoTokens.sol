pragma solidity ^0.8.20;

interface IRadicalVaultTwoTokens {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function positionBalancesInToken0(address account) external view returns (uint256 token0Deposited);
    function balanceToLiquidERC20Balance(uint256 balance)
        external
        view
        returns (uint256 token0Owed, uint256 token1Owed);
    function getTotalValueInToken0() external view returns (uint256 totalInToken0);
    function getOraclePricePerUnitToken0(uint256 amountToken1) external view returns (uint256 amountToken0);
    function depositExact(uint256 toDepositToken0, uint256 toDepositToken1) external;
    function withdraw(uint256 balance) external;
    function collectFeesAndWithdraw(uint256 balance) external;
    function collectFees() external;
    function collectFeesAndReinvest() external returns (uint256 newLiquidity);
}
