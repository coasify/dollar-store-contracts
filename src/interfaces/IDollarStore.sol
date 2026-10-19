// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title IDollarStore - Interface for DollarStore
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
    /// @notice Emitted when the governor replaces the unpauser.
    event UnpauserSet(address indexed previousUnpauser, address indexed newUnpauser);
    /// @notice Emitted when an address is allowed to pause, or no longer allowed.
    event PauserSet(address indexed account, bool allowed);

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
    /// @notice Caller is not a pauser.
    error OnlyPauser();
    /// @notice Caller is not the unpauser.
    error OnlyUnpauser();
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
    /// @notice The current unpauser address.
    function unpauser() external view returns (address);
    /// @notice Whether `account` may pause.
    function isPauser(address account) external view returns (bool);
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
    /// @notice Replace the unpauser. Governor-gated, so it waits in the governor timelock.
    function setUnpauser(address newUnpauser) external;
    /// @notice Initiate a two-step upgrader transfer. Upgrader-gated (self-managed, not governor).
    function transferUpgrader(address newUpgrader) external;
    /// @notice Accept the upgrader role. Callable only by the pending upgrader.
    function acceptUpgrader() external;

    // ============ Emergency ============

    /// @notice Pause the protocol. Callable by any pauser. Exits and queue cancels stay open.
    function pause() external;
    /// @notice Unpause the protocol. Unpauser-gated.
    function unpause() external;
    /// @notice Allow `account` to pause, or stop allowing it. Unpauser-gated, with no delay, so a
    ///         pauser that should not be pausing is removed at once. A pauser can pause the protocol,
    ///         a pool or an asset, and can do nothing else. The unpauser may list any address,
    ///         including a multi-sig or its own.
    function setPauser(address account, bool allowed) external;

    // ============ Asset Registry ============

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
    ///         A relisted asset keeps its deposit pause and probe exemption.
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

    // ============ Spoke Lifecycle ============

    /// @notice Emitted when a spoke's protected minimum DLRS-side reserve is set or changed.
    event MinDlrsReserveSet(uint16 indexed poolId, uint256 oldMin, uint256 newMin);
    /// @notice Emitted when a spoke pool is removed (killed): paused and all its assets unlisted.
    event PoolRemoved(uint16 indexed poolId);
    /// @notice Emitted when liquidity is added to a spoke (spoke asset, or a hub asset funding the
    ///         spoke's DLRS side). `caller` paid `nativeAmount` (native asset pulled); `receiver` was
    ///         credited `sharesMinted` non-transferable receipt shares. `valueUnits` is the normalized
    ///         6dp value added.
    event SpokeLiquidityAdded(
        uint16 indexed poolId,
        address indexed receiver,
        address indexed asset,
        address caller,
        uint256 nativeAmount,
        uint256 valueUnits,
        uint256 sharesMinted
    );
    /// @notice Emitted when an LP burns spoke receipt shares and receives their proportional slice of
    ///         both sides: `spokeUnits` from the spoke asset reserve and `hubUnits` from the spoke's claim
    ///         on hub dollars, paid across hub assets. Each asset paid, the spoke asset included, also has
    ///         its own Withdraw. `spokeUnits` and `hubUnits` are normalized 6dp; `sharesBurned` is a share
    ///         count.
    event SpokeWithdrawn(
        uint16 indexed poolId, address indexed provider, uint256 sharesBurned, uint256 spokeUnits, uint256 hubUnits
    );

    /// @notice The pool exists but is not a spoke (operation is spoke-only).
    error PoolNotSpoke(uint16 poolId);
    /// @notice The spoke still holds reserves or DLRS-side liquidity.
    error PoolNotEmpty(uint16 poolId);
    /// @notice The pool registry is full (poolId space exhausted).
    error MaxPoolsReached();
    /// @notice The caller does not hold enough receipt shares for the requested spoke withdrawal, or a
    ///         preview asks for more than all outstanding DLRS (hub) or shares (spoke).
    error InsufficientReceiptShares(uint256 requested, uint256 available);
    /// @notice `minAmountsOut` is neither empty nor one entry per asset the exit can pay.
    error MinAmountsLength(uint256 provided, uint256 expected);
    /// @notice The exit would pay less than `minimum` of `asset`; both amounts native `asset`.
    error WithdrawMinNotMet(address asset, uint256 amount, uint256 minimum);
    /// @notice `asset` will not deliver to `wallet`, so the exit is refused.
    error ExitBlockedByIssuer(address asset, address wallet);

    /// @notice Create a spoke pool for `spokeAsset`. Governor-gated (timelock). Reads and freezes the
    ///         token decimals, computes the scaling factor, requires a Chainlink feed, and sets the
    ///         initial protected minimum DLRS-side reserve and the launch cap (normalized 6dp units; 0 means
    ///         no cap). The cap is set in the same call, so it never depends on a pool id chosen in advance.
    ///         Reverts if the asset is already listed (an asset belongs to exactly one pool), decimals are
    ///         outside [6,18], or the feed reports more than 18 decimals. Reverts EscrowImpaired while the
    ///         contract holds less of the asset than its queue escrow. A relisted asset keeps its deposit
    ///         pause and probe exemption.
    /// @return poolId The new spoke's pool id (>= 1).
    function createSpoke(address spokeAsset, address priceFeed, uint256 minDlrsReserve, uint256 launchCap)
        external
        returns (uint16 poolId);

    /// @notice Set a spoke's minimum DLRS-side reserve. Governor-gated (timelock). Spoke-only. The floor
    ///         bounds spoke->hub SWAPS only: LP exits are senior to it and may take the claim below it.
    function setMinDlrsReserve(uint16 poolId, uint256 newMin) external;

    /// @notice Kill a spoke with zero spoke reserves and zero dlrsReserve. Worthless LP shares remain as
    ///         historical records in the retired poolId. Queued and parked positions on the spoke's lines
    ///         do not block removal; they remain cancellable by their owners and can never be filled.
    ///         Pauses the pool and unlists its assets; governance may relist them in a fresh pool once
    ///         the contract's balance covers any escrow of the asset left behind.
    ///         Governor-gated (timelock). The hub cannot be removed, and a killed pool cannot be removed
    ///         again or unpaused.
    function removePool(uint16 poolId) external;

    /// @notice A spoke's minimum DLRS-side reserve for swaps (0 for the hub). Not a floor for LP exits.
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

    // ============ Hub Deposit / Withdraw ============

    /// @notice Emitted on a hub deposit (a spoke deposit emits SpokeLiquidityAdded instead). `caller`
    ///         paid `amountIn` (native asset pulled); `receiver` was minted `receiptAmount` DLRS.
    event Deposit(
        address indexed receiver,
        uint16 indexed poolId,
        address indexed asset,
        address caller,
        uint256 amountIn,
        uint256 receiptAmount
    );
    /// @notice Emitted once per asset a withdrawal pays, the spoke asset included, tagged with the pool
    ///         exited. `units` is normalized 6dp; `nativeAmount` is the transfer in the asset's own decimals.
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
    /// @notice The pool's reserves are insufficient for the requested amount. Both amounts are normalized
    ///         6dp; on an exit they are hub dollar totals, and `asset` only names the pool being exited.
    error InsufficientReserves(address asset, uint256 requested, uint256 available);
    /// @notice The asset delivered less than expected (fee-on-transfer / non-standard); unsupported.
    error FeeOnTransferNotSupported(address asset);

    /// @notice Deposit into pool `poolId`, paid by the caller and owned by `receiver`. Into the hub
    ///         (poolId 0), a hub asset mints DLRS 1:1 in normalized units. Into a spoke, the spoke's asset
    ///         or a hub asset mints non-transferable receipt shares and emits SpokeLiquidityAdded. With
    ///         S = 10**(decimals - 6), `amount` is rounded down to a whole multiple of S and only that
    ///         much is pulled; the rest stays with the caller.
    ///         Anyone can deposit for any receiver, unasked: it takes nothing from the receiver, but a
    ///         contract must not assume its receipt balance equals its own deposits. The position is
    ///         inaccessible unless the receiver can call `withdraw`, and receipts cannot be transferred
    ///         to another owner, so a receiver that can never call it leaves the position stuck for good.
    /// @param amount Native budget of `asset`.
    /// @param receiver Owner of the DLRS or shares. Pass the caller's own address to deposit for
    ///        yourself; reverts InvalidRecipient for the zero address or DollarStore.
    /// @return amountIn Native `asset` pulled from the caller.
    /// @return receiptAmount For the hub, the DLRS minted (6 decimals). For a spoke, the receipt shares
    ///         credited, a count that stops matching dollars once the spoke takes a write-down.
    function deposit(uint16 poolId, address asset, uint256 amount, address receiver, uint256 deadline)
        external
        returns (uint256 amountIn, uint256 receiptAmount);

    /// @notice Proportional exit: exact receipt amount in, proportional basket out; not ERC-4626. Hub
    ///         (poolId 0): burn `receiptAmount` DLRS and receive your slice of every hub asset. Spoke
    ///         (poolId >= 1): burn `receiptAmount` receipt shares and receive your slice of the spoke asset
    ///         and of the spoke's claim on hub dollars. The caller never chooses an asset: to end up 100%
    ///         in one asset, withdraw and then swap.
    ///         Exits are not pausable and are senior to minDlrsReserve: a spoke exit may take the claim
    ///         below the floor, and a fresh deposit followed by an exit returns the pool's mix, so it can
    ///         still move part of a deposit into hub assets without queueing. Pool assets of which the
    ///         exit pays none are probed with a zero-value transfer unless exempted by governance;
    ///         reverts ExitBlockedByIssuer if the probe fails.
    /// @param receiptAmount DLRS (hub) or receipt shares (spoke) to burn, from the caller.
    /// @param minAmountsOut Empty to accept the proportional payout, or one native minimum per entry of
    ///        `assets`, in the same order; reverts MinAmountsLength for any other length and
    ///        WithdrawMinNotMet when an asset pays less. Build it from previewWithdraw, not getPoolAssets.
    /// @return assets Every asset the exit can pay: the spoke asset first (spoke exits only), then every
    ///         hub asset in listing order. A new hub listing adds a slot, so an old minimums list
    ///         reverts on length instead of being misread.
    /// @return amounts Native amount paid of each, 0 where nothing was paid.
    function withdraw(uint16 poolId, uint256 receiptAmount, uint256[] calldata minAmountsOut, uint256 deadline)
        external
        returns (address[] memory assets, uint256[] memory amounts);

    /// @notice What withdraw would pay for `receiptAmount` at the current state, from the same
    ///         calculation, including how rounding remainders are handed out. Anyone can preview any
    ///         amount: it does not check the caller's balance. It reverts where the exit's calculation
    ///         does (ZeroAmount for a zero or sub-unit value, InsufficientReserves when the hub cannot
    ///         cover the payout) and on more than all outstanding receipts (InsufficientReceiptShares).
    ///         It promises the calculation only: state can change before the exit, and it does not run
    ///         the issuer probe or any transfer, so the exit can still revert ExitBlockedByIssuer.
    function previewWithdraw(uint16 poolId, uint256 receiptAmount)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts);

    /// @notice All assets in a pool and their reserves (normalized 6dp). Reverts InvalidPool if absent.
    function getReserves(uint16 poolId) external view returns (address[] memory assets, uint256[] memory amounts);

    // ============ Directed Swaps & Queues ============

    /// @notice Emitted on a swap, in native units. `caller` paid; `recipient` received `amountOut`
    ///         (the caller for swapOrQueue). `amountIn` is offerAsset pulled, `amountOut` wantAsset
    ///         delivered now, `amountInQueued` the part of `amountIn` escrowed in the queue. Later queue
    ///         payouts are reported by QueueFilled, in normalized 6dp units.
    event Swap(
        address indexed caller,
        address indexed offerAsset,
        address indexed wantAsset,
        address recipient,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountInQueued
    );
    /// @notice Emitted by swapSpokeToSpoke once per entry in `via` that carried part of the swap, with the
    ///         normalized amount routed through that hub asset. The whole call also emits one Swap.
    event SpokeSwapRouted(address indexed user, address indexed via, uint256 amount);
    /// @notice Emitted when a new queue position is created. `amount` is the escrow in normalized 6dp
    ///         units (swapOrQueue returns the same escrow in native offerAsset). `poolId` is the pool whose
    ///         lines it joins.
    event QueueJoined(
        uint256 indexed positionId,
        address indexed owner,
        address offerAsset,
        address wantAsset,
        uint256 amount,
        uint16 poolId
    );
    /// @notice Emitted when a queued position is filled (partially or fully). `filled` and `remaining`
    ///         are normalized 6dp units.
    event QueueFilled(uint256 indexed positionId, address indexed owner, uint256 filled, uint256 remaining);
    /// @notice Emitted when a queue position is cancelled and its escrow returned. `amountReturned` is
    ///         normalized 6dp units; the transfer is in native offerAsset.
    event QueueCancelled(uint256 indexed positionId, address indexed owner, uint256 amountReturned);
    /// @notice Emitted when a position is parked: a transfer to its owner failed, so it is lifted out of
    ///         its directed queue and held on the parked line for its offer asset. Escrow is untouched;
    ///         the owner exits by cancelQueue once the transfer can succeed. `units` is the escrow in
    ///         normalized 6dp.
    event QueueParked(uint256 indexed positionId, address indexed owner, address offerAsset, uint256 units);

    /// @notice offerAsset == wantAsset is not a valid swap.
    error SameAsset();
    /// @notice The (offerAsset, wantAsset) route is not supported, e.g. spoke to spoke through swapOrQueue().
    error InvalidRoute(address offerAsset, address wantAsset);
    /// @notice The directed queue is at capacity (MAX_QUEUE_POSITIONS).
    error QueueFull(address offerAsset, address wantAsset);
    /// @notice The queued remainder is below the minimum order size (both normalized 6dp).
    error OrderTooSmall(uint256 providedUnits, uint256 minimumUnits);
    /// @notice The amount delivered now is below the caller's `minAmountOut` (both native `wantAsset`).
    error MinAmountNotMet(address wantAsset, uint256 amountOut, uint256 minAmountOut);
    /// @notice An all-or-nothing swap could not fill in full. Both amounts are native `wantAsset`.
    ///         `fillableAmountOut` is the amount accounted as filled by this attempted execution before
    ///         the revert; all effects were reverted. It is not a maximum-liquidity quote or a guarantee
    ///         for a smaller retry; simulate the intended call. `requestedAmountOut` is the full output,
    ///         floor(amount / So) * Sw.
    error InsufficientLiquidity(address wantAsset, uint256 fillableAmountOut, uint256 requestedAmountOut);
    /// @notice A swap recipient or deposit receiver is the zero address or DollarStore itself.
    error InvalidRecipient(address recipient);
    /// @notice No queue position exists with this id.
    error QueuePositionNotFound(uint256 positionId);
    /// @notice The caller does not own this queue position.
    error NotPositionOwner(uint256 positionId, address caller);
    /// @notice Cancelling a parked position: the escrow transfer to its owner failed.
    error EscrowTransferFailed(uint256 positionId);

    /// @notice Swap `offerAsset` for `wantAsset` 1:1, filling what it can now and queueing the rest
    ///         under the caller. Fills from the exact-opposite queue, then protocol reserves (only
    ///         behind any same-direction queue). The caller owns the queued position: it receives the
    ///         later payouts and is the only one who can cancel it. Routers and solvers should use
    ///         swapExactInput, which never queues. All amounts are native; with S = 10**(decimals - 6),
    ///         `amount` is rounded down to a whole multiple of So and only that much is pulled, so any
    ///         remainder below So stays with the caller.
    /// @param amount Native offerAsset budget.
    /// @param minAmountOut Minimum native wantAsset delivered now; a full instant fill is
    ///        floor(amount / So) * Sw. Reverts MinAmountNotMet below it.
    /// @return amountIn Native offerAsset pulled, floor(amount / So) * So, including the part queued.
    /// @return amountOut Native wantAsset delivered now.
    /// @return amountInQueued Native offerAsset escrowed in the queue, part of `amountIn`.
    /// @return positionId The new queue position, 0 if nothing was queued.
    function swapOrQueue(address offerAsset, address wantAsset, uint256 amount, uint256 minAmountOut, uint256 deadline)
        external
        returns (uint256 amountIn, uint256 amountOut, uint256 amountInQueued, uint256 positionId);

    /// @notice All-or-nothing swap for routers and solvers: fills fully from the opposite queue and
    ///         reserves or reverts InsufficientLiquidity. Never queues. All amounts are native; with
    ///         S = 10**(decimals - 6), `amount` is rounded down to a whole multiple of So and only that
    ///         much is pulled from the caller, so any remainder below So stays with the caller.
    /// @param amount Native offerAsset budget. The full output is floor(amount / So) * Sw.
    /// @param minAmountOut Minimum native wantAsset delivered. Reverts MinAmountNotMet below it.
    /// @param recipient Receives the output. Pass the caller's own address to receive it yourself;
    ///        reverts InvalidRecipient for the zero address or DollarStore.
    /// @return amountIn Native offerAsset pulled from the caller.
    /// @return amountOut Native wantAsset delivered to `recipient`.
    function swapExactInput(
        address offerAsset,
        address wantAsset,
        uint256 amount,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountIn, uint256 amountOut);

    /// @notice All-or-nothing swap between two spoke assets through the hub assets in `via`, tried in
    ///         order. For each, a spoke->hub leg fills, like swapExactInput (opposite queue, then reserves
    ///         behind any same-direction queue), up to what both legs can carry through that hub asset, and
    ///         the hub->spoke leg pays it out; the rest moves on to the next hub asset. Hub assets are used
    ///         greedily in list order, and they share the offered spoke's hub claim and the wanted spoke's
    ///         reserve, which positions already waiting on a line the call enters are paid from first. So
    ///         the result can depend on the order of `via`, and a list can revert when another order or a
    ///         shorter list would fill (see docs/PROTOCOL.md). Each hub asset is sized assuming every payout
    ///         succeeds, so a waiting position whose owner cannot be paid counts against that entry even
    ///         though the fill parks it; a later entry, the same hub asset included, is sized again. An
    ///         entry sized at zero is skipped without trying any payout, so it parks no one.
    ///         Reverts if the list runs out before the full amount fills, or if a second leg pays out less
    ///         than its first leg took (a payout failed, that position was parked, and the wanted spoke's
    ///         reserve cannot cover the rest). Parking alone does not revert. Never queues. `offerAsset`
    ///         is inflow-checked, and a `via` that fails the inflow check is skipped. To quote a single
    ///         hub asset, chain getSwapQuote(via, wantAsset, getSwapQuote(offerAsset, via, amount)): if
    ///         that equals floor(amount / So) * Sw, there is enough liquidity; the swap still needs every
    ///         transfer to succeed, including payouts to queued owners and the final one to `recipient`.
    ///         Simulate the actual call, and always for a list. Amounts are native and rounded as in swapExactInput.
    /// @param recipient Receives the output. Pass the caller's own address to receive it yourself;
    ///        reverts InvalidRecipient for the zero address or DollarStore.
    /// @return amountIn Native offerAsset pulled from the caller.
    /// @return amountOut Native wantAsset delivered to `recipient`.
    function swapSpokeToSpoke(
        address offerAsset,
        address wantAsset,
        address[] calldata via,
        uint256 amount,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountIn, uint256 amountOut);

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
    /// @notice Details of a queue position (zeros if it does not exist). `amount` is the remaining
    ///         escrow in normalized 6dp units, not native offerAsset. `poolId` is the pool it was
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
    ///         which includes `wantAsset == address(0)`, the parked line. Normalized 6dp units: the
    ///         native minimum queued remainder is this times 10**(offerAsset decimals - 6).
    function getMinimumOrderSize(address offerAsset, address wantAsset) external view returns (uint256);
    /// @notice Amount of wantAsset, in its native units, that swapOrQueue or swapExactInput would fill now
    ///         for `amount` of offerAsset: the opposite queue, then reserves left after the swap first
    ///         settles up to 8 earlier same-direction positions at the caller's gas cost. 0 when the swap
    ///         would revert on route, pause, or offer-price checks. A quote is liquidity only: it takes no
    ///         caller or recipient and checks no transfer permission. It assumes every transfer succeeds:
    ///         a queued owner who cannot be paid can make the real fill higher or lower, and the swap
    ///         reverts if the address receiving wantAsset (the caller for swapOrQueue, `recipient`
    ///         otherwise) cannot receive it. Simulate the actual call, with its caller and recipient,
    ///         for an exact answer.
    function getSwapQuote(address offerAsset, address wantAsset, uint256 amount) external view returns (uint256);

    // ============ Risk Controls ============

    event PriceFeedUpdated(address indexed asset, address indexed feed);
    event ProbeExemptSet(address indexed asset, bool exempt);
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
    /// @notice Exempt an asset from the zero-value transfer probe on exits, or re-enable it. Governor-gated
    ///         (via timelock). Exempting disables the issuer check for exits that pay none of the asset:
    ///         its issuer is then not consulted on those exits at all. Real transfers of the asset still
    ///         run the token's own controls. Use only when the token rejects zero-value transfers (which
    ///         would otherwise block such exits for everyone) or does not apply its controls to them.
    function setProbeExempt(address asset, bool exempt) external;
    /// @notice Whether an asset is exempt from the exit probe.
    function isProbeExempt(address asset) external view returns (bool);
    /// @notice Set the peg tolerance (basis points). Governor-gated (via timelock).
    function setPegTolerance(uint256 tolerance) external;
    /// @notice Set the max oracle staleness (seconds). Governor-gated (via timelock). Must be above 0
    ///         and at most 3 days, which is a ceiling with room for a 48h heartbeat feed. The value in
    ///         use should be the slowest listed feed's heartbeat plus margin, 25h for the 24h feeds on
    ///         Chainlink's mainnet stablecoins.
    function setMaxStaleness(uint256 staleness) external;
    /// @notice Pause deposits/inflows of an asset. Callable by any pauser. Exits stay open.
    function pauseDeposits(address asset) external;
    /// @notice Unpause deposits/inflows of an asset. Unpauser-gated.
    function unpauseDeposits(address asset) external;
    /// @notice Pause a pool (blocks inflows involving it). Callable by any pauser. Exits stay open.
    function pausePool(uint16 poolId) external;
    /// @notice Unpause a pool. Unpauser-gated. Reverts if the pool is permanently killed.
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

    // ============ Launch Caps ============

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
