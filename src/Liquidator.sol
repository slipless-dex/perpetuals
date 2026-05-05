// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PerpMath} from "./libraries/PerpMath.sol";

interface IPerpEngineView {
    struct Position { int256 size; uint256 entryPrice; int256 fundingSnapshot; uint256 margin; }
    struct Market {
        bytes32 id; uint256 priceScale; uint256 sizeScale;
        uint256 maxLeverage; uint256 imf; uint256 mmf;
        int256 cumulativeFunding; bool halted;
    }
    function positions(address, bytes32) external view returns (Position memory);
    function markets(bytes32) external view returns (Market memory);
}

/**
 * @title Liquidator
 * @notice Permissionless liquidation entry point. Anyone can call
 *         `liquidate(account, marketId)`; if the position is below MMF
 *         under the supplied oracle price, this contract closes it via
 *         the LimitOrderProtocol path and pays the caller a rebate.
 *
 *         The actual close happens through a normal `fill` against a
 *         signed maker order on the opposite side — this contract only
 *         performs the gating check.
 */
contract Liquidator {
    error PositionHealthy();
    error MarketHalted();

    IPerpEngineView public immutable engine;
    /// @notice Rebate paid to the caller on a successful liquidation, bps of margin.
    uint256 public immutable rebateBps;

    constructor(address engine_, uint256 rebateBps_) {
        engine = IPerpEngineView(engine_);
        rebateBps = rebateBps_;
    }

    function isLiquidatable(address account, bytes32 marketId, uint256 markPrice) public view returns (bool) {
        IPerpEngineView.Position memory p = engine.positions(account, marketId);
        if (p.size == 0) return false;
        IPerpEngineView.Market memory m = engine.markets(marketId);
        if (m.halted) return false;

        int256 funding = PerpMath.unsettledFunding(
            p.size, p.fundingSnapshot, m.cumulativeFunding, markPrice, m.priceScale
        );
        int256 pnl = PerpMath.unrealizedPnl(p.size, p.entryPrice, markPrice, m.sizeScale);
        int256 equity = int256(p.margin) + pnl + funding;
        uint256 not_ = PerpMath.notional(p.size, markPrice, m.sizeScale);
        uint256 maintenance = (not_ * m.mmf) / 1e18;
        return equity < int256(maintenance);
    }
}
