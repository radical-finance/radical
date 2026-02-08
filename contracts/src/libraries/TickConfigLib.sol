// SPDX-License-Identifier: CC-BY-NC-4.0
pragma solidity ^0.8.20;

struct TickBounds {
    int24 tickUpper;
    int24 tickLower;
}

struct TickConfigWindow {
    int24 tickCenter;
    uint24 tickWindowSize;
}

library TickConfigLib {
    error TickUpperMustBeGreaterThanTickLower(int24 tickUpper, int24 tickLower);
    error TickUpperNotMultipleOfSpacing(int24 tickUpper, int24 tickSpacing);
    error TickLowerNotMultipleOfSpacing(int24 tickLower, int24 tickSpacing);

    function toTickBounds(TickConfigWindow memory window) internal pure returns (TickBounds memory) {
        int24 tickLower = window.tickCenter - int24(window.tickWindowSize);
        int24 tickUpper = window.tickCenter + int24(window.tickWindowSize);

        return TickBounds({tickUpper: tickUpper, tickLower: tickLower});
    }

    function validate(TickBounds memory bounds, int24 tickSpacing) internal pure {
        _validateBounds(bounds);
        _checkTickSpacing(bounds, tickSpacing);
    }

    function _validateBounds(TickBounds memory bounds) private pure {
        if (bounds.tickUpper <= bounds.tickLower) {
            revert TickUpperMustBeGreaterThanTickLower(bounds.tickUpper, bounds.tickLower);
        }
    }

    function _checkTickSpacing(TickBounds memory bounds, int24 tickSpacing) private pure {
        if (bounds.tickUpper % tickSpacing != 0) {
            revert TickUpperNotMultipleOfSpacing(bounds.tickUpper, tickSpacing);
        }
        if (bounds.tickLower % tickSpacing != 0) {
            revert TickLowerNotMultipleOfSpacing(bounds.tickLower, tickSpacing);
        }
    }
}
