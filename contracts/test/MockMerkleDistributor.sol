// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

pragma abicoder v2;

import "@openzeppelin/contracts8/token/ERC20/ERC20.sol";

/**
 * Mock ERC20 token for testing
 */
contract MockToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * Mock Merkle distributor that simply mints and sends tokens when claim is called
 * This simulates receiving rewards from the actual Merkle distributor
 */
contract MockMerkleDistributor {
    /**
     * Mock claim function that mints tokens to the caller
     * In a real distributor, this would verify proofs and transfer pre-existing tokens
     * @param tokens Array of token addresses to mint
     * @param amounts Array of amounts to mint for each token
     */
    function claim(address[] calldata, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata)
        external
    {
        require(tokens.length == amounts.length, "Array length mismatch");

        // In the mock, we mint tokens directly to the caller (the staking contract)
        for (uint256 i = 0; i < tokens.length; i++) {
            if (amounts[i] > 0) {
                // send less tokens as in practice this is often the case
                MockToken(tokens[i]).mint(msg.sender, amounts[i] - 1);
            }
        }
    }
}
