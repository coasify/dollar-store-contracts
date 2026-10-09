// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {QueueStorage} from "../storage/QueueStorage.sol";

/// @title QueueLib - Directed FIFO queue mechanics (linked-list only)
/// @notice Pure bookkeeping for the directed queues: enqueue at tail, reduce (partial fill),
///         remove (full fill / cancel), and the escalating minimum order size. Keeps the queue
///         counters, the doubly-linked list, `totalEscrowedByAsset`, and `userPositions` in sync.
/// @dev Does NOT move tokens, validate routes, or touch reserves — the contract orchestrates those.
///      `totalEscrowedByAsset[asset]` always equals the sum of `offerAmount` over live positions
///      whose `offerAsset == asset`, because it is updated atomically here.
/// @custom:security-contact admin@dollarstore.world
library QueueLib {
    /// @notice Minimum queued order size given `positionCount` existing positions in the queue.
    /// @dev Grows 10x every MIN_ORDER_SCALE_POSITIONS positions: 500, 5_000, 50_000, ...
    function minimumOrderSize(uint256 positionCount) internal pure returns (uint256) {
        uint256 tier = positionCount / QueueStorage.MIN_ORDER_SCALE_POSITIONS;
        uint256 mult = 1;
        for (uint256 i = 0; i < tier; i++) {
            mult *= 10;
        }
        return QueueStorage.MIN_ORDER_BASE * mult;
    }

    /// @notice Append a new position at the tail of the (offerAsset -> wantAsset) queue.
    /// @return positionId The id of the newly created position.
    function enqueue(
        QueueStorage.Layout storage qs,
        address offerAsset,
        address wantAsset,
        uint16 poolId,
        address owner,
        uint256 amount
    ) internal returns (uint256 positionId) {
        bytes32 key = QueueStorage.queueKey(offerAsset, wantAsset, poolId);
        QueueStorage.Queue storage q = qs.queues[key];

        positionId = ++qs.nextPositionId; // first id == 1 (0 means "no position")
        QueueStorage.QueuePosition storage p = qs.positions[positionId];
        p.owner = owner;
        p.poolId = poolId;
        p.userIndex = uint64(qs.userPositions[owner].length);
        p.offerAsset = offerAsset;
        p.wantAsset = wantAsset;
        p.offerAmount = amount;
        p.tip = 0; // reserved; enabling tips is a post-launch upgrade (U1)
        p.timestamp = block.timestamp;
        p.prev = q.tail;
        p.next = 0;

        if (q.tail == 0) {
            q.head = positionId;
        } else {
            qs.positions[q.tail].next = positionId;
        }
        q.tail = positionId;
        q.positionCount += 1;
        q.totalDepth += amount;

        qs.totalEscrowedByAsset[offerAsset] += amount;
        qs.userPositions[owner].push(positionId);
    }

    /// @dev Key of the line a position currently sits in: its directed queue, or the parked line.
    function lineKey(QueueStorage.QueuePosition storage p) internal view returns (bytes32) {
        return
            p.parked ? QueueStorage.parkedKey(p.offerAsset) : QueueStorage.queueKey(p.offerAsset, p.wantAsset, p.poolId);
    }

    /// @notice Park a queued position: unlink it from its directed queue and append it to the parked
    ///         line for its offer asset. Escrow, ownership and `userPositions` are untouched; only the
    ///         line bookkeeping moves. Called when a transfer to the owner fails, so the queue can
    ///         advance past the position. Idempotent: parking an already-parked position is a no-op.
    function park(QueueStorage.Layout storage qs, uint256 positionId) internal {
        QueueStorage.QueuePosition storage p = qs.positions[positionId];
        if (p.parked) return;
        uint256 amount = p.offerAmount;

        QueueStorage.Queue storage q = qs.queues[QueueStorage.queueKey(p.offerAsset, p.wantAsset, p.poolId)];
        _unlink(qs, p, q);
        q.positionCount -= 1;
        q.totalDepth -= amount;

        QueueStorage.Queue storage pk = qs.queues[QueueStorage.parkedKey(p.offerAsset)];
        p.parked = true;
        p.prev = pk.tail;
        p.next = 0;
        if (pk.tail == 0) {
            pk.head = positionId;
        } else {
            qs.positions[pk.tail].next = positionId;
        }
        pk.tail = positionId;
        pk.positionCount += 1;
        pk.totalDepth += amount;
    }

    /// @notice Reduce a live position's amount by `delta` (partial fill). Requires delta < amount.
    function reduce(QueueStorage.Layout storage qs, uint256 positionId, uint256 delta) internal {
        QueueStorage.QueuePosition storage p = qs.positions[positionId];
        bytes32 key = lineKey(p);
        p.offerAmount -= delta;
        qs.queues[key].totalDepth -= delta;
        qs.totalEscrowedByAsset[p.offerAsset] -= delta;
    }

    /// @notice Remove a position entirely (full fill or cancel), unlinking it from its queue.
    /// @return owner The position owner.
    /// @return offerAsset The escrowed asset.
    /// @return amount The remaining amount that was removed (still escrowed at call time).
    function remove(QueueStorage.Layout storage qs, uint256 positionId)
        internal
        returns (address owner, address offerAsset, uint256 amount)
    {
        QueueStorage.QueuePosition storage p = qs.positions[positionId];
        owner = p.owner;
        offerAsset = p.offerAsset;
        amount = p.offerAmount;

        QueueStorage.Queue storage q = qs.queues[lineKey(p)];
        _unlink(qs, p, q);

        q.positionCount -= 1;
        q.totalDepth -= amount;
        qs.totalEscrowedByAsset[offerAsset] -= amount;

        _removeUserPosition(qs, owner, p.userIndex);
        delete qs.positions[positionId];
    }

    /// @dev Unlink `p` from the doubly-linked list of line `q` (counters are the caller's job).
    function _unlink(QueueStorage.Layout storage qs, QueueStorage.QueuePosition storage p, QueueStorage.Queue storage q)
        private
    {
        if (p.prev == 0) {
            q.head = p.next;
        } else {
            qs.positions[p.prev].next = p.next;
        }
        if (p.next == 0) {
            q.tail = p.prev;
        } else {
            qs.positions[p.next].prev = p.prev;
        }
    }

    /// @dev Swap-and-pop the id at `index` out of the owner's position array. The id moved into its
    ///      place gets that index, so no removal searches the array.
    function _removeUserPosition(QueueStorage.Layout storage qs, address owner, uint256 index) private {
        uint256[] storage arr = qs.userPositions[owner];
        uint256 last = arr.length - 1;
        if (index != last) {
            uint256 moved = arr[last];
            arr[index] = moved;
            qs.positions[moved].userIndex = uint64(index);
        }
        arr.pop();
    }
}
