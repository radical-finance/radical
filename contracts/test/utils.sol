pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts8/token/ERC20/IERC20.sol";
import {IRadicalVaultTwoTokens} from "@interfaces/IRadicalVaultTwoTokens.sol";

contract TokenTest {
    IERC20 token0Contract;
    IERC20 token1Contract;
    address token0;
    address token1;
}

contract BalanceTestHelper is Test, TokenTest {
    address public faucet;
    IRadicalVaultTwoTokens testedContract;

    function setFaucet(address _faucet) public {
        faucet = _faucet;
    }

    function setTestedContract(IRadicalVaultTwoTokens radicalContract) public {
        testedContract = radicalContract;
    }

    // TPDP generalize this to an address

    function fundSingle(IERC20 token, address receiver, uint256 amounts) internal {
        vm.startPrank(faucet);
        token.transfer(receiver, amounts);
        vm.stopPrank();
    }

    function fund(address receiver, uint256 amounts) internal {
        fundSingle(token0Contract, receiver, amounts);
        fundSingle(token1Contract, receiver, amounts);
    }

    // TODO move this to helper
    function balancesOfBoth(address account) internal view returns (uint256 balanceToken0, uint256 balanceToken1) {
        balanceToken0 = token0Contract.balanceOf(account);
        balanceToken1 = token1Contract.balanceOf(account);
    }

    function balancesOfBothToToken0(address account) public view returns (uint256 balaceInToken0) {
        (uint256 balanceToken0, uint256 balanceToken1) = balancesOfBoth(account);
        return balanceToken0 + testedContract.getOraclePricePerUnitToken0(balanceToken1);
    }

    function approveBoth(address _user, address spender, uint256 amount) internal {
        approve(_user, spender, token0, amount);
        approve(_user, spender, token1, amount);
    }

    function fundAndApprove(address receiver, uint256 amounts) internal {
        fund(receiver, amounts);
        approveBoth(receiver, address(testedContract), amounts);
    }

    function approve(address _user, address spender, address token, uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        vm.startPrank(_user);
        IERC20(token).approve(spender, amount);
        vm.stopPrank();
    }

    function approveAndDeposit(address _user, address _token0, address _token1, uint256 amount0, uint256 amount1)
        internal
    {
        approve(_user, address(testedContract), _token0, amount0);
        approve(_user, address(testedContract), _token1, amount1);

        vm.startPrank(_user);
        testedContract.depositExact(amount0, amount1);
        vm.stopPrank();
        vm.warp(block.timestamp + 5);
    }
}
