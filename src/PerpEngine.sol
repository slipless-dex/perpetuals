// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PerpMath} from "./libraries/PerpMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PerpEngine
 * @notice The settlement engine LimitOrderProtocol calls into. Owns
 *         positions, collateral, funding indices, and is the only contract
 *         allowed to mutate them.
 *
 *         Architecture mirrors dYdX v4: positions are stored as deltas
 *         against a per-market funding index; funding is applied lazily on
 *         next position-touch; liquidations are external and rebated.
 */
contract PerpEngine is ReentrancyGuard, Ownable {
    error MarketNotRegistered();
    error CallerNotProtocol();
    error InsufficientMargin();
    error MarketHalted();

    struct Market {
        bytes32 id;
        uint256 priceScale;       // 10**priceDecimals
        uint256 sizeScale;        // 10**sizeDecimals
        uint256 maxLeverage;      // integer multiplier (e.g. 50)
        uint256 imf;              // initial-margin fraction, 1e18 fp
        uint256 mmf;              // maintenance-margin fraction, 1e18 fp
        int256 cumulativeFunding; // accrued via updateFundingIndex
        bool halted;
    }

    struct Position {
        int256 size;
        uint256 entryPrice;
        int256 fundingSnapshot;
        uint256 margin;
    }

    address public immutable limitOrderProtocol;
    address public liquidator; // optional rebate forwarder

    /// @notice marketId => Market
    mapping(bytes32 => Market) public markets;
    /// @notice account => marketId => Position
    mapping(address => mapping(bytes32 => Position)) public positions;
    /// @notice account => collateral balance (cross-margin)
    mapping(address => uint256) public collateral;

    event MarketRegistered(bytes32 indexed marketId);
    event Settled(bytes32 indexed marketId, address indexed taker, int256 dSize, uint256 fillPrice);
    event FundingUpdated(bytes32 indexed marketId, int256 newCumulative);

    modifier onlyProtocol() {
        if (msg.sender != limitOrderProtocol) revert CallerNotProtocol();
        _;
    }

    constructor(address lop_, address admin_) Ownable(admin_) {
        limitOrderProtocol = lop_;
    }

    function registerMarket(Market calldata m) external onlyOwner {
        markets[m.id] = m;
        emit MarketRegistered(m.id);
    }

    function setHalted(bytes32 id, bool halted) external onlyOwner {
        markets[id].halted = halted;
    }

    /// @notice Pushed by the funding cron / oracle adapter.
    function updateFundingIndex(bytes32 id, int256 newCumulative) external {
        require(msg.sender == owner() || msg.sender == liquidator, "PerpEngine: not authorised");
        markets[id].cumulativeFunding = newCumulative;
        emit FundingUpdated(id, newCumulative);
    }

    /**
     * @notice Settle a single fill. Called by LimitOrderProtocol after it
     *         has verified the maker's signature and predicate. The maker
     *         signs price+size; this contract does the position math.
     *
     *         Sign convention: a buy fill increases the maker's signed size
     *         positively for the buyer and negatively for the seller.
     */
    function settle(
        struct_Order calldata order,
        bytes32 orderHash,
        uint256 fillSize,
        uint256 fillPrice,
        address taker
    )
        external
        nonReentrant
        onlyProtocol
        returns (bool)
    {
        Market storage m = markets[order.marketId];
        if (m.id == bytes32(0)) revert MarketNotRegistered();
        if (m.halted) revert MarketHalted();

        bool makerIsSell = (order.salt & 1) != 0;
        int256 dMaker = makerIsSell ? -int256(fillSize) : int256(fillSize);
        int256 dTaker = -dMaker;

        _applyFill(order.trader, m, dMaker, fillPrice);
        _applyFill(taker, m, dTaker, fillPrice);

        emit Settled(order.marketId, taker, dTaker, fillPrice);
        // Silence "unused" warnings while preserving the calldata signature.
        orderHash;
        return true;
    }

    /* -------------------------------------------------------------------- */

    function _applyFill(address account, Market storage m, int256 dSize, uint256 fillPrice) internal {
        Position storage p = positions[account][m.id];

        // Settle accrued funding before changing size.
        int256 funding = PerpMath.unsettledFunding(
            p.size, p.fundingSnapshot, m.cumulativeFunding, fillPrice, m.priceScale
        );
        if (funding > 0) {
            p.margin += uint256(funding);
        } else if (funding < 0) {
            uint256 owed = uint256(-funding);
            if (owed > p.margin) revert InsufficientMargin();
            p.margin -= owed;
        }
        p.fundingSnapshot = m.cumulativeFunding;

        // Update size + entry price.
        if (p.size == 0 || (p.size > 0 && dSize > 0) || (p.size < 0 && dSize < 0)) {
            int256 newSize = p.size + dSize;
            uint256 absNew = newSize < 0 ? uint256(-newSize) : uint256(newSize);
            uint256 absOld = p.size < 0 ? uint256(-p.size) : uint256(p.size);
            uint256 absD = dSize < 0 ? uint256(-dSize) : uint256(dSize);
            p.entryPrice = (p.entryPrice * absOld + fillPrice * absD) / absNew;
            p.size = newSize;
        } else {
            // Reduce / flip — realise PnL onto margin.
            int256 realized = PerpMath.unrealizedPnl(dSize, p.entryPrice, fillPrice, m.sizeScale);
            if (realized > 0) p.margin += uint256(realized);
            else {
                uint256 loss = uint256(-realized);
                if (loss > p.margin) revert InsufficientMargin();
                p.margin -= loss;
            }
            p.size += dSize;
            if (p.size != 0) p.entryPrice = fillPrice;
        }

        // Initial-margin check.
        uint256 not_ = PerpMath.notional(p.size, fillPrice, m.sizeScale);
        uint256 required = (not_ * m.imf) / 1e18;
        if (p.margin < required) revert InsufficientMargin();
    }
}

/// @dev Mirror of OrderLib.Order so we don't have to import the LOP package.
struct struct_Order {
    address trader;
    bytes32 marketId;
    uint256 price;
    uint256 size;
    uint256 triggerPrice;
    uint256 expiry;
    uint256 salt;
    bytes predicate;
}
