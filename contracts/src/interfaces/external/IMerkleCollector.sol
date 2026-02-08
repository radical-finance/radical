pragma solidity >=0.5.13 <0.9.0;

pragma abicoder v2;

interface IMerkleCollector {
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}
