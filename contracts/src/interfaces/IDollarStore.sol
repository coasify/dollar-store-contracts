// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IDollarStore - Milestone M1 interface for DollarStore
/// @notice Minimal surface for the upgradeable (UUPS) base + governance skeleton.
/// @dev Swap/queue/reserve logic lands in later milestones; M1 is roles + upgrade plumbing.
/// @custom:security-contact admin@dollarstore.world
interface IDollarStore {
    // ============ Events ============

    /// @notice Emitted when the current governor initiates a two-step governor transfer.
    event GovernorTransferInitiated(address indexed currentGovernor, address indexed pendingGovernor);
    /// @notice Emitted when the pending governor accepts the governor role.
    event GovernorTransferCompleted(address indexed previousGovernor, address indexed newGovernor);
    /// @notice Emitted when the governor initiates a two-step guardian transfer.
    event GuardianTransferInitiated(address indexed currentGuardian, address indexed pendingGuardian);
    /// @notice Emitted when the pending guardian accepts the guardian role.
    event GuardianTransferCompleted(address indexed previousGuardian, address indexed newGuardian);
    /// @notice Emitted when the current upgrader initiates a two-step upgrader transfer.
    event UpgraderTransferInitiated(address indexed currentUpgrader, address indexed pendingUpgrader);
    /// @notice Emitted when the pending upgrader accepts the upgrader role.
    event UpgraderTransferCompleted(address indexed previousUpgrader, address indexed newUpgrader);

    // ============ Errors ============

    /// @notice Caller is not the governor.
    error OnlyGovernor();
    /// @notice Caller is not the guardian.
    error OnlyGuardian();
    /// @notice Caller is not the pending governor.
    error OnlyPendingGovernor();
    /// @notice Caller is not the pending guardian.
    error OnlyPendingGuardian();
    /// @notice Caller is not the upgrader.
    error OnlyUpgrader();
    /// @notice Caller is not the pending upgrader.
    error OnlyPendingUpgrader();
    /// @notice A zero address was supplied where a non-zero address is required.
    error ZeroAddress();

    // ============ Role / State Getters ============

    /// @notice The current governor address.
    function governor() external view returns (address);
    /// @notice The current guardian address.
    function guardian() external view returns (address);
    /// @notice The pending governor (zero if no transfer in progress).
    function pendingGovernor() external view returns (address);
    /// @notice The pending guardian (zero if no transfer in progress).
    function pendingGuardian() external view returns (address);
    /// @notice The current upgrader address (UUPS upgrade authority).
    function upgrader() external view returns (address);
    /// @notice The pending upgrader (zero if no transfer in progress).
    function pendingUpgrader() external view returns (address);
    /// @notice The DLRS receipt token address.
    function dlrs() external view returns (address);
    /// @notice The semantic version of this implementation.
    function version() external pure returns (string memory);

    // ============ Two-step Role Transfers ============

    /// @notice Initiate a two-step governor transfer. Governor-gated.
    function transferGovernor(address newGovernor) external;
    /// @notice Accept the governor role. Callable only by the pending governor.
    function acceptGovernor() external;
    /// @notice Initiate a two-step guardian transfer. Governor-gated (not guardian-gated).
    function transferGuardian(address newGuardian) external;
    /// @notice Accept the guardian role. Callable only by the pending guardian.
    function acceptGuardian() external;
    /// @notice Initiate a two-step upgrader transfer. Upgrader-gated (self-managed, not governor).
    function transferUpgrader(address newUpgrader) external;
    /// @notice Accept the upgrader role. Callable only by the pending upgrader.
    function acceptUpgrader() external;

    // ============ Emergency ============

    /// @notice Pause the protocol. Guardian-gated.
    function pause() external;
    /// @notice Unpause the protocol. Guardian-gated.
    function unpause() external;

    // ============ Asset Registry (M2) ============

    /// @notice Emitted when a pool is created. `kind`: 0 = Hub, 1 = Spoke.
    event PoolCreated(uint16 indexed poolId, uint8 kind);
    /// @notice Emitted when an asset is listed into a pool.
    event AssetListed(address indexed asset, uint16 indexed poolId, uint8 decimals, address priceFeed);

    /// @notice The asset is already listed.
    error AssetAlreadyListed(address asset);
    /// @notice The referenced pool does not exist.
    error InvalidPool(uint16 poolId);
    /// @notice A killed pool cannot be removed again or unpaused.
    error PoolKilled(uint16 poolId);

    /// @notice List a hub asset (poolId 0). Governor-gated. Freezes decimals, computes the
    ///         scaling factor, and requires a Chainlink price feed. Reverts if the asset decimals
    ///         are outside [6, 18], the feed reports more than 18 decimals, or it is already listed.
    ///         Reverts EscrowImpaired while the contract holds less of the asset than its queue escrow.
    function addHubAsset(address asset, address priceFeed) external;

    /// @notice Whether an asset is listed/supported.
    function isAssetListed(address asset) external view returns (bool);
    /// @notice Frozen decimals of an asset, kept after its pool is removed (0 if never listed).
    function assetDecimals(address asset) external view returns (uint8);
    /// @notice Scaling factor 10**(decimals-6) of a listed asset.
    function assetScalingFactor(address asset) external view returns (uint64);
    /// @notice Canonical pool id of a listed asset.
    function assetPoolId(address asset) external view returns (uint16);
    /// @notice Chainlink price feed of a listed asset.
    function assetPriceFeed(address asset) external view returns (address);

    /// @notice Active reserve of `asset` in `poolId`, in normalized 6dp units.
    function getReserve(uint16 poolId, address asset) external view returns (uint256);
    /// @notice Number of pools (index 0 is the hub).
    function poolCount() external view returns (uint256);
    /// @notice Assets that belong to a pool. Reverts InvalidPool if it does not exist.
    function getPoolAssets(uint16 poolId) external view returns (address[] memory);

    // ============ Spoke Lifecycle (U2) ============

    /// @notice Emitted when a spoke's protected minimum DLRS-side reserve is set or changed.
    event MinDlrsReserveSet(uint16 indexed poolId, uint256 oldMin, uint256 newMin);
    /// @notice Emitted when a spoke pool is removed (killed): paused and all its assets unlisted.
    event PoolRemoved(uint16 indexed poolId);
    /// @notice Emitted when an LP adds liquidity to a spoke (spoke asset, or a hub asset funding the
    ///         spoke's DLRS side) and receives non-transferable receipt shares. `valueUnits` is the
    ///         normalized 6dp value added; `sharesMinted` is the receipt shares credited.
    event SpokeLiquidityAdded(
        uint16 indexed poolId,
        address indexed provider,
        address indexed asset,
        uint256 nativeAmount,
        uint256 valueUnits,
        uint256 sharesMinted
    );
    /// @notice Emitted when a spoke LP burns receipt shares and withdraws value in a chosen asset.
    ///         `sharesBurned` is the receipt shares burned; `valueUnits` the normalized 6dp value paid.
    event SpokeLiquidityRemoved(
        uint16 indexed poolId,
        address indexed provider,
        address indexed asset,
        uint256 sharesBurned,
        uint256 valueUnits,
        uint256 nativeAmount
    );
    /// @notice Emitted when an LP proportionally redeems spoke shares across both sides of the pool
    ///         (its spoke asset and its DLRS-side hub assets). `spokeUnits`/`dlrsUnits` are the
    ///         normalized 6dp value paid from the spoke reserve and the DLRS side respectively.
    event SpokeRedeemed(
        uint16 indexed poolId, address indexed provider, uint256 sharesBurned, uint256 spokeUnits, uint256 dlrsUnits
    );

    /// @notice The pool exists but is not a spoke (operation is spoke-only).
    error PoolNotSpoke(uint16 poolId);
    /// @notice The spoke still holds reserves or DLRS-side liquidity.
    error PoolNotEmpty(uint16 poolId);
    /// @notice The pool registry is full (poolId space exhausted).
    error MaxPoolsReached();
    /// @notice The caller does not hold enough receipt shares for the requested spoke withdrawal.
    error InsufficientReceiptShares(uint256 requested, uint256 available);

    /// @notice Create a spoke pool for `spokeAsset`. Governor-gated (timelock). Reads and freezes the
    ///         token decimals, computes the scaling factor, requires a Chainlink feed, and sets the
    ///         initial protected minimum DLRS-side reserve. Reverts if the asset is already listed (an
    ///         asset belongs to exactly one pool), decimals are outside [6,18], or the feed reports more
    ///         than 18 decimals. Reverts EscrowImpaired while the contract holds less of the asset than
    ///         its queue escrow.
    /// @return poolId The new spoke's pool id (>= 1).
    function createSpoke(address spokeAsset, address priceFeed, uint256 minDlrsReserve) external returns (uint16 poolId);

    /// @notice Set a spoke's protected minimum DLRS-side reserve. Governor-gated (timelock). Spoke-only.
    function setMinDlrsReserve(uint16 poolId, uint256 newMin) external;

    /// @notice Kill a spoke with zero spoke reserves and zero dlrsReserve. Worthless LP shares remain as
    ///         historical records in the retired poolId. Queued and parked positions on the spoke's lines
    ///         do not block removal; they remain cancellable by their owners and can never be filled.
    ///         Pauses the pool and unlists its assets; governance may relist them in a fresh pool once
    ///         the contract's balance covers any escrow of the asset left behind.
    ///         Governor-gated (timelock). The hub cannot be removed, and a killed pool cannot be removed
    ///         again or unpaused.
    function removePool(uint16 poolId) external;

    /// @notice Proportionally redeem `shares` of a spoke: pays the pro-rata slice of BOTH the spoke
    ///         asset (from its reserve) and the DLRS side (from hub reserves) in a single call, so an LP
    ///         can drain their position without leaving rounding dust stuck on one side. Exit path: live
    ///         under pause, not gated by minDlrsReserve. Burning the last shares drains both reserves to
    ///         exactly zero, which is what lets a fully-exited spoke be removed.
    /// @return spokeUnits The normalized 6dp value paid from the spoke reserve.
    /// @return dlrsUnits The normalized 6dp value paid from the DLRS side (across hub assets).
    function redeemSpoke(uint16 poolId, uint256 shares, uint256 deadline)
        external
        returns (uint256 spokeUnits, uint256 dlrsUnits);

    /// @notice A pool's protected minimum DLRS-side reserve (0 for the hub).
    function getMinDlrsReserve(uint16 poolId) external view returns (uint256);
    /// @notice A pool's internal DLRS-side reserve, normalized 6dp (0 for the hub).
    function getDlrsReserve(uint16 poolId) external view returns (uint256);
    /// @notice An LP's non-transferable receipt-share balance in a spoke pool.
    function getReceiptShares(uint16 poolId, address owner) external view returns (uint256);
    /// @notice Total outstanding non-transferable receipt shares in a spoke pool.
    function getReceiptTotalShares(uint16 poolId) external view returns (uint256);
    /// @notice Pool kind: 0 = Hub, 1 = Spoke.
    function poolKind(uint16 poolId) external view returns (uint8);
    /// @notice Spoke lifecycle status: 0 = Active, 1 = WindingDown, 2 = Killed.
    function getPoolStatus(uint16 poolId) external view returns (uint8);

    /// @notice Emitted when a spoke enters the winding-down state.
    event SpokeWindDownStarted(uint16 indexed poolId);
    /// @notice Emitted when a guardian applies an escrow-impairment haircut to a balance-impaired asset.
    event EscrowHaircut(address indexed asset, uint16 indexed poolId, uint256 oldEscrow, uint256 newEscrow);

    /// @notice A risk-increasing operation was attempted on a winding-down spoke.
    error SpokeWindingDown(uint16 poolId);
    /// @notice The operation requires the asset's pool to be paused.
    error PoolNotPaused(uint16 poolId);
    /// @notice The asset is not balance-impaired (actual balance covers reserves + escrow).
    error AssetNotImpaired(address asset);
    /// @notice There is no queue escrow of this asset to haircut.
    error NoEscrowToHaircut(address asset);
    /// @notice The haircut did not finish within `maxPositions`; retry with a larger bound.
    error HaircutBudgetExceeded();

    /// @notice Move a spoke into the winding-down state. Governor-gated (timelock). Blocks new deposits
    ///         and risk-increasing (spoke->hub) trades while keeping LP exits, cancellations, and
    ///         risk-reducing (hub->spoke) trades live. Spoke-only.
    function windDownSpoke(uint16 poolId) external;

    /// @notice Guardian emergency: apply a pro-rata haircut to the queue escrow of a balance-impaired
    ///         asset (actual token balance < accounted reserves + escrow), so the escrow accounting
    ///         matches the surviving balance. Only while the asset's pool is paused. Iterates the queues
    ///         where `asset` is the offer, including the parked line, bounded by `maxPositions` (reverts
    ///         if exceeded). A removed spoke's asset is accepted while positions of it remain, queued
    ///         or parked.
    /// @return removedUnits The normalized 6dp escrow removed by the haircut.
    function haircutEscrow(address asset, uint256 maxPositions) external returns (uint256 removedUnits);

    // ============ Hub Deposit / Withdraw (M3) ============

    /// @notice Emitted on a deposit. `nativeAmount` is what was actually pulled; `units` is the
    ///         normalized 6dp amount credited (and DLRS minted for the hub).
    event Deposit(
        address indexed user, uint16 indexed poolId, address indexed asset, uint256 nativeAmount, uint256 units
    );
    /// @notice Emitted on a withdrawal.
    event Withdraw(
        address indexed user, uint16 indexed poolId, address indexed asset, uint256 units, uint256 nativeAmount
    );

    /// @notice The transaction deadline has passed.
    error DeadlineExpired(uint256 deadline, uint256 timestamp);
    /// @notice A zero (or sub-unit) amount was supplied.
    error ZeroAmount();
    /// @notice The asset is not listed/supported.
    error AssetNotListed(address asset);
    /// @notice The asset does not belong to the given pool.
    error WrongPool(address asset, uint16 poolId);
    /// @notice The operation is not enabled yet (e.g., spoke deposits, deferred to a later milestone).
    error NotEnabled();
    /// @notice The pool's reserves are insufficient for the requested amount.
    error InsufficientReserves(address asset, uint256 requested, uint256 available);
    /// @notice The asset delivered less than expected (fee-on-transfer / non-standard); unsupported.
    error FeeOnTransferNotSupported(address asset);

    /// @notice Deposit `amount` (native units) of a hub asset and receive DLRS 1:1 in normalized
    ///         units. Sub-unit dust stays with the caller. Hub-only in this milestone.
    /// @return receiptUnits The normalized 6dp amount credited (DLRS minted).
    function deposit(uint16 poolId, address asset, uint256 amount, uint256 deadline)
        external
        returns (uint256 receiptUnits);

    /// @notice Burn `units` DLRS and withdraw a hub asset 1:1. Exit path — not blocked by pause.
    /// @return nativeAmountOut The native token amount sent to the caller.
    function withdraw(uint16 poolId, address asset, uint256 units, uint256 deadline)
        external
        returns (uint256 nativeAmountOut);

    /// @notice All assets in a pool and their reserves (normalized 6dp). Reverts InvalidPool if absent.
    function getReserves(uint16 poolId) external view returns (address[] memory assets, uint256[] memory amounts);

    // ============ Directed Swaps & Queues (M4) ============

    /// @notice Emitted on a swap. Amounts are normalized 6dp units.
    event Swap(
        address indexed user,
        address indexed offerAsset,
        address indexed wantAsset,
        uint256 amountIn,
        uint256 amountFilled,
        uint256 amountQueued
    );
    /// @notice Emitted when a new queue position is created. `poolId` is the pool whose lines it joins.
    event QueueJoined(
        uint256 indexed positionId,
        address indexed owner,
        address offerAsset,
        address wantAsset,
        uint256 amount,
        uint16 poolId
    );
    /// @notice Emitted when a queued position is filled (partially or fully).
    event QueueFilled(uint256 indexed positionId, address indexed owner, uint256 filled, uint256 remaining);
    /// @notice Emitted when a queue position is cancelled and its escrow returned.
    event QueueCancelled(uint256 indexed positionId, address indexed owner, uint256 amountReturned);
    /// @notice Emitted when a position is parked: a transfer to its owner failed, so it is lifted out of
    ///         its directed queue and held on the parked line for its offer asset. Escrow is untouched;
    ///         the owner exits by cancelQueue once the transfer can succeed.
    event QueueParked(uint256 indexed positionId, address indexed owner, address offerAsset, uint256 units);

    /// @notice offerAsset == wantAsset is not a valid swap.
    error SameAsset();
    /// @notice The (offerAsset, wantAsset) route is not supported (e.g., involves a spoke; deferred).
    error InvalidRoute(address offerAsset, address wantAsset);
    /// @notice A non-zero tip was supplied; priority tips are a post-launch upgrade (U1).
    error TipNotEnabled();
    /// @notice The directed queue is at capacity (MAX_QUEUE_POSITIONS).
    error QueueFull(address offerAsset, address wantAsset);
    /// @notice The queued remainder is below the minimum order size.
    error OrderTooSmall(uint256 provided, uint256 minimum);
    /// @notice The instantly-filled amount is below the caller's `minAmountOut`.
    error MinAmountNotMet(uint256 filled, uint256 required);
    /// @notice swapExactInput could not fill the full amount instantly.
    error InsufficientLiquidity(uint256 filled, uint256 requested);
    /// @notice No queue position exists with this id.
    error QueuePositionNotFound(uint256 positionId);
    /// @notice The caller does not own this queue position.
    error NotPositionOwner(uint256 positionId, address caller);
    /// @notice Cancelling a parked position: the escrow transfer to its owner failed.
    error EscrowTransferFailed(uint256 positionId);

    /// @notice Swap `offerAsset` for `wantAsset` (1:1 in normalized units). Fills from the
    ///         exact-opposite queue then protocol reserves; queues any remainder.
    /// @param minAmountOut Minimum amount that must be filled instantly before queueing; set equal
    ///        to the normalized `amount` to require a full instant fill (else it reverts).
    /// @param tip Reserved for U1 priority queues; MUST be 0 in this version.
    /// @return amountFilled Instantly filled amount (normalized 6dp).
    /// @return amountQueued Amount escrowed into the queue (normalized 6dp).
    function swap(
        address offerAsset,
        address wantAsset,
        uint256 amount,
        uint256 minAmountOut,
        uint256 tip,
        uint256 deadline
    ) external returns (uint256 amountFilled, uint256 amountQueued);

    /// @notice All-or-nothing swap for routers/solvers: fills fully from opposite queue + reserves
    ///         or reverts. Never queues.
    /// @param minAmountOut Floor on the filled amount, in normalized 6-decimal units (same
    ///        convention as swap). Reverts MinAmountNotMet(filled, minAmountOut) if not met.
    /// @return amountOut Amount of wantAsset delivered (native units of wantAsset).
    function swapExactInput(
        address offerAsset,
        address wantAsset,
        uint256 amount,
        uint256 minAmountOut,
        uint256 deadline
    ) external returns (uint256 amountOut);

    /// @notice Cancel a queue position and return the escrowed offer asset. If the transfer fails, a
    ///         queued position is parked (see QueueParked) and a parked position reverts
    ///         EscrowTransferFailed. Escrow only ever leaves as the offered asset.
    function cancelQueue(uint256 positionId) external;

    /// @notice Permissionless bounded fallback: fill up to `maxPositions` of the (offerAsset ->
    ///         wantAsset) queue from available reserves, in FIFO order.
    /// @return positionsProcessed Number of positions visited: filled, partially filled, or parked
    ///         because the payout failed. Parked positions count toward `maxPositions`.
    /// @return amountFilled Total amount filled (normalized 6dp).
    function processQueue(address offerAsset, address wantAsset, uint256 maxPositions)
        external
        returns (uint256 positionsProcessed, uint256 amountFilled);

    /// @notice Total escrowed depth of the (offerAsset -> wantAsset) queue (normalized 6dp), in the pool
    ///         the pair currently routes through. Zero if either asset is not listed, so lines of a
    ///         removed pool are never reported. `wantAsset == address(0)` returns the parked escrow of
    ///         `offerAsset`, listed or not.
    function getQueueDepth(address offerAsset, address wantAsset) external view returns (uint256);
    /// @notice Details of a queue position (zeros if it does not exist). `poolId` is the pool it was
    ///         queued in: the spoke pool for a hub<->spoke pair, 0 for hub-to-hub. It does not change
    ///         when the position is parked or the pool is removed.
    function getQueuePosition(uint256 positionId)
        external
        view
        returns (address owner, address offerAsset, address wantAsset, uint256 amount, uint256 timestamp, uint16 poolId);
    /// @notice All position ids owned by a user (queued and parked).
    function getUserQueuePositions(address user) external view returns (uint256[] memory);
    /// @notice Whether a position is parked (see QueueParked). getQueueDepth(asset, address(0)) is the
    ///         total parked escrow of `asset`.
    function isQueuePositionParked(uint256 positionId) external view returns (bool);
    /// @notice Current minimum order size to queue into the (offerAsset -> wantAsset) queue, in the pool
    ///         the pair currently routes through. The base minimum if either asset is not listed,
    ///         which includes `wantAsset == address(0)`, the parked line.
    function getMinimumOrderSize(address offerAsset, address wantAsset) external view returns (uint256);
    /// @notice Instantly fillable amount for a swap (normalized 6dp), respecting FIFO availability
    ///         (returns 0 for a same-direction pair that already has a non-empty queue).
    function getSwapQuote(address offerAsset, address wantAsset, uint256 amount) external view returns (uint256);

    // ============ Risk Controls (M5) ============

    event PriceFeedUpdated(address indexed asset, address indexed feed);
    event PegToleranceSet(uint256 tolerance);
    event MaxStalenessSet(uint256 staleness);
    event DepositsPausedSet(address indexed asset, bool paused);
    event PoolPausedSet(uint16 indexed poolId, bool paused);
    event ReservesSynced(address indexed asset, uint256 previousReserves, uint256 newReserves);
    event TokensRescued(address indexed asset, address indexed to, uint256 amount);

    /// @notice Deposits/inflows of this asset are paused.
    error DepositsPaused(address asset);
    /// @notice The pool is paused.
    error PoolPaused(uint16 poolId);
    /// @notice No price feed configured for the asset.
    error NoPriceFeed(address asset);
    /// @notice The oracle returned a non-positive price.
    error InvalidPrice(address asset);
    /// @notice The oracle round is stale (answeredInRound < roundId).
    error StaleRound(address asset);
    /// @notice The oracle answer is older than maxStaleness.
    error PriceStale(address asset, uint256 updatedAt);
    /// @notice The price is outside the peg tolerance band.
    error PriceOutOfBounds(address asset, uint256 price, uint256 lower, uint256 upper);
    /// @notice pegTolerance out of the allowed range.
    error InvalidTolerance();
    /// @notice maxStaleness out of the allowed range.
    error InvalidStaleness();
    /// @notice Reserves have not drifted below the accounted balance (nothing to sync).
    error ReservesNotDrifted(address asset);
    /// @notice No excess (unaccounted) balance to rescue.
    error NoExcessTokens(address asset);
    /// @notice Actual balance is below queue escrow: haircut the escrow or restore the balance first.
    error EscrowImpaired(address asset);

    /// @notice Update the Chainlink price feed for a listed asset. Governor-gated (via timelock).
    ///         Reverts if the feed reports more than 18 decimals.
    function setPriceFeed(address asset, address feed) external;
    /// @notice Set the peg tolerance (basis points). Governor-gated (via timelock).
    function setPegTolerance(uint256 tolerance) external;
    /// @notice Set the max oracle staleness (seconds). Governor-gated (via timelock). Must be above 0
    ///         and at most 3 days, which is a ceiling with room for a 48h heartbeat feed. The value in
    ///         use should be the slowest listed feed's heartbeat plus margin, 25h for the 24h feeds on
    ///         Chainlink's mainnet stablecoins.
    function setMaxStaleness(uint256 staleness) external;
    /// @notice Pause deposits/inflows of an asset. Guardian-gated. Exits stay open.
    function pauseDeposits(address asset) external;
    /// @notice Unpause deposits/inflows of an asset. Guardian-gated.
    function unpauseDeposits(address asset) external;
    /// @notice Pause a pool (blocks inflows involving it). Guardian-gated. Exits stay open.
    function pausePool(uint16 poolId) external;
    /// @notice Unpause a pool. Guardian-gated. Reverts if the pool is permanently killed.
    function unpausePool(uint16 poolId) external;
    /// @notice Sync recorded reserves down to the actual balance minus queue escrow, after an
    ///         external balance loss. Only decreases. Governor-gated (via timelock): it marks down
    ///         DLRS backing, so it is a governance decision, not a fast emergency action.
    function syncReserves(uint16 poolId, address asset) external;
    /// @notice Sweep unaccounted excess tokens (accidental transfers / never-listed assets).
    ///         Governor-gated (via timelock): it moves tokens out of the contract.
    function rescueTokens(address asset, address to) external;
    /// @notice Whether deposits/inflows of an asset are paused.
    function isDepositPaused(address asset) external view returns (bool);
    /// @notice Whether a pool is paused.
    function isPoolPaused(uint16 poolId) external view returns (bool);
    /// @notice Current peg tolerance (basis points).
    function pegTolerance() external view returns (uint256);
    /// @notice Current max oracle staleness (seconds).
    function maxStaleness() external view returns (uint256);

    // ============ Launch Caps (M6) ============

    /// @notice Emitted when a pool's launch cap changes. cap == 0 means no cap.
    event LaunchCapSet(uint16 indexed poolId, uint256 cap);

    /// @notice A deposit would push the pool's active exposure above its launch cap.
    error LaunchCapExceeded(uint16 poolId, uint256 attempted, uint256 cap);
    /// @notice The guardian's new cap is not stricter than the current one.
    error CapNotStricter();

    /// @notice Set a pool's launch cap (normalized 6dp units). cap == 0 removes the cap.
    ///         Governor-gated (raise/lower/remove) — expected via the timelock.
    function setLaunchCap(uint16 poolId, uint256 cap) external;
    /// @notice Tighten a pool's launch cap instantly. Guardian-gated. Must be stricter than the
    ///         current cap (a positive value below the current cap, or any positive value if
    ///         currently uncapped). Cannot loosen or remove.
    function lowerLaunchCap(uint16 poolId, uint256 cap) external;
    /// @notice A pool's current launch cap (0 = no cap).
    function getLaunchCap(uint16 poolId) external view returns (uint256);
}
