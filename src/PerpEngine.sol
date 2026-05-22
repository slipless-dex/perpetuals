// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PerpMath} from "./libraries/PerpMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract PerpEngine is ReentrancyGuard, Ownable {
    error MarketNotRegistered();
    error CallerNotProtocol();
    error InsufficientMargin();
    error MarketHalted();
    error NotAuthorised();

    struct Market {
        bytes32 id;
        uint256 priceScale;       // 10**priceDecimals
        uint256 sizeScale;        // 10**sizeDecimals
        uint256 maxLeverage;
        uint256 imf;              // 1e18 fp
        uint256 mmf;              // 1e18 fp
        int256 cumulativeFunding;
        bool halted;
    }

    struct Position {
        int256 size;
        uint256 entryPrice;
        int256 fundingSnapshot;
        uint256 margin;
    }

    address public immutable limitOrderProtocol;
    address public liquidator;

    mapping(bytes32 => Market) public markets;
    mapping(address => mapping(bytes32 => Position)) public positions;
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

    function updateFundingIndex(bytes32 id, int256 newCumulative) external {
        if (msg.sender != owner() && msg.sender != liquidator) revert NotAuthorised();
        markets[id].cumulativeFunding = newCumulative;
        emit FundingUpdated(id, newCumulative);
    }

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
        orderHash;
        return true;
    }

    function _applyFill(address account, Market storage m, int256 dSize, uint256 fillPrice) internal {
        Position storage p = positions[account][m.id];

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

        if (p.size == 0 || (p.size > 0 && dSize > 0) || (p.size < 0 && dSize < 0)) {
            int256 newSize = p.size + dSize;
            uint256 absNew = newSize < 0 ? uint256(-newSize) : uint256(newSize);
            uint256 absOld = p.size < 0 ? uint256(-p.size) : uint256(p.size);
            uint256 absD = dSize < 0 ? uint256(-dSize) : uint256(dSize);
            p.entryPrice = (p.entryPrice * absOld + fillPrice * absD) / absNew;
            p.size = newSize;
        } else {
            int256 realized = PerpMath.unrealizedPnl(dSize, p.entryPrice, fillPrice, m.sizeScale);
            if (realized > 0) {
                p.margin += uint256(realized);
            } else {
                uint256 loss = uint256(-realized);
                if (loss > p.margin) revert InsufficientMargin();
                p.margin -= loss;
            }
            p.size += dSize;
            if (p.size != 0) p.entryPrice = fillPrice;
        }

        uint256 not_ = PerpMath.notional(p.size, fillPrice, m.sizeScale);
        uint256 required = (not_ * m.imf) / 1e18;
        if (p.margin < required) revert InsufficientMargin();
    }
}

// Mirror of OrderLib.Order — avoids importing the LOP package.
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
