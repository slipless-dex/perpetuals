// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title PerpMath
 * @notice Position math: notional, unrealised PnL, funding accrual,
 *         liquidation price. Mirrors `@slipless/sdk` math/* — one of these
 *         is wrong if and only if the other is.
 */
library PerpMath {
    int256 internal constant ONE_E18 = 1e18;

    /// @notice abs(size) * price / sizeScale.
    function notional(int256 size, uint256 price, uint256 sizeScale) internal pure returns (uint256) {
        uint256 abs = size < 0 ? uint256(-size) : uint256(size);
        return (abs * price) / sizeScale;
    }

    /// @notice ((mark - entry) * size) / sizeScale.
    function unrealizedPnl(int256 size, uint256 entry, uint256 mark, uint256 sizeScale)
        internal pure returns (int256)
    {
        return ((int256(mark) - int256(entry)) * size) / int256(sizeScale);
    }

    /// @notice Funding accrued since `snapshot`. Negative => owed.
    ///         owed = -size * (cumNow - cumSnap) * mark / (1e18 * priceScale)
    function unsettledFunding(
        int256 size,
        int256 cumSnap,
        int256 cumNow,
        uint256 mark,
        uint256 priceScale
    )
        internal pure returns (int256)
    {
        int256 delta = cumNow - cumSnap;
        int256 numerator = -(size * delta * int256(mark));
        return numerator / (ONE_E18 * int256(priceScale));
    }
}
