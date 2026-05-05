// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PerpMath} from "../src/libraries/PerpMath.sol";

contract PerpMathTest is Test {
    uint256 constant SIZE = 1e18;
    uint256 constant PRICE = 1e8;

    function test_notional_signless() external pure {
        uint256 a = PerpMath.notional(int256(2 * SIZE), 3000 * PRICE, SIZE);
        uint256 b = PerpMath.notional(-int256(2 * SIZE), 3000 * PRICE, SIZE);
        assertEq(a, b);
        assertEq(a, 6000 * PRICE);
    }

    function test_pnl_long_profits_above_entry() external pure {
        int256 pnl = PerpMath.unrealizedPnl(int256(SIZE), 3000 * PRICE, 3100 * PRICE, SIZE);
        assertEq(pnl, int256(100 * PRICE));
    }

    function test_pnl_short_profits_below_entry() external pure {
        int256 pnl = PerpMath.unrealizedPnl(-int256(SIZE), 3000 * PRICE, 2900 * PRICE, SIZE);
        assertEq(pnl, int256(100 * PRICE));
    }

    function test_funding_long_owes_when_rate_positive() external pure {
        int256 owed = PerpMath.unsettledFunding(int256(SIZE), 0, 1e15, 3000 * PRICE, PRICE);
        assertLt(owed, 0);
    }
}
