// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDollarStore} from "./interfaces/IDollarStore.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {CoreStorage} from "./storage/CoreStorage.sol";
import {RegistryStorage} from "./storage/RegistryStorage.sol";
import {QueueStorage} from "./storage/QueueStorage.sol";
import {NormalizationLib} from "./libraries/NormalizationLib.sol";
import {QueueLib} from "./libraries/QueueLib.sol";
import {SpokeShareLib} from "./libraries/SpokeShareLib.sol";
import {SpokeAdminLib} from "./libraries/SpokeAdminLib.sol";
import {SpokeLifecycleLib} from "./libraries/SpokeLifecycleLib.sol";
import {SwapRouteLib} from "./libraries/SwapRouteLib.sol";
import {PegLib} from "./libraries/PegLib.sol";
import {DLRS} from "./DLRS.sol";

/// @title DollarStore - Upgradeable (UUPS) stablecoin swap store with a hub pool and spoke pools
/// @notice Upgrades are authorized by the upgrader. Pausing is done by the pausers and lifting a pause
///         by the unpauser. The governor lists assets and sets parameters; the guardian lowers launch
///         caps and haircuts impaired escrow.
/// @dev Storage is held in CoreStorage's ERC-7201 namespaced slot, NOT in contract state
///      variables, so the layout is stable across upgrades.
/// @custom:security-contact admin@dollarstore.world
contract DollarStore is Initializable, UUPSUpgradeable, PausableUpgradeable, ReentrancyGuard, IDollarStore {
    using SafeERC20 for IERC20;

    // ============ Constants ============

    /// @dev Max supported price-feed decimals; the peg math scales by 10**(18 - feedDecimals).
    uint8 private constant MAX_FEED_DECIMALS = 18;
    /// @dev Peg tolerance set at initialize: 50 bps == 0.5%.
    uint256 private constant DEFAULT_PEG_TOLERANCE_BPS = 50;
    /// @dev Maximum settable peg tolerance: 500 bps == 5%.
    uint256 private constant MAX_PEG_TOLERANCE_BPS = 500;
    /// @dev Max oracle staleness set at initialize: 90000 s == 25 hours.
    ///      Chainlink's mainnet stablecoin feeds are heartbeat-driven at 24h and only update sooner on a
    ///      deviation, so a healthy feed is routinely hours old: measured 2026-09-23, USDC/USD was 1.1h
    ///      old and USDT/USD 18.1h old. Anything at or below the heartbeat marks a healthy feed as stale
    ///      and reverts every swap, so the initial value is the heartbeat plus an hour of margin.
    ///      Governance can tighten it per deployment; a faster feed deserves a shorter window.
    uint256 private constant DEFAULT_MAX_STALENESS = 90000;
    /// @dev Maximum settable staleness: 3 days. This is a ceiling on what governance may configure, not
    ///      a value anything runs with, so it is set with margin: some feeds run on a 48h heartbeat, and
    ///      a ceiling below what a listed feed needs bricks swaps and takes an upgrade to lift, while a
    ///      generous one only matters if a governor action is wrong, which is timelocked and cancellable
    ///      by the veto Safe.
    uint256 private constant MAX_STALENESS = 3 days;

    // Routing types (RouteKind / Route) and the directed-swap engine live in SwapRouteLib (linked,
    // delegatecall) so this implementation fits under the EIP-170 24576-byte runtime limit.

    // ============ Modifiers ============

    /// @dev Restricts to the current governor (read from namespaced core storage).
    modifier onlyGovernor() {
        if (msg.sender != CoreStorage.layout().governor) revert OnlyGovernor();
        _;
    }

    /// @dev Restricts to the current guardian (read from namespaced core storage).
    modifier onlyGuardian() {
        if (msg.sender != CoreStorage.layout().guardian) revert OnlyGuardian();
        _;
    }

    /// @dev Restricts to an address that may pause. A pauser has no other power. The check is a
    ///      function call so its code is not copied into every pause function (contract size).
    modifier onlyPauser() {
        _checkPauser();
        _;
    }

    /// @dev Restricts to the current unpauser, which lifts pauses and sets who may pause.
    modifier onlyUnpauser() {
        _checkUnpauser();
        _;
    }

    function _checkPauser() private view {
        if (!CoreStorage.layout().pausers[msg.sender]) revert OnlyPauser();
    }

    function _checkUnpauser() private view {
        if (msg.sender != CoreStorage.layout().unpauser) revert OnlyUnpauser();
    }

    /// @dev Restricts to the current upgrader (read from namespaced core storage). The upgrader
    ///      holds UUPS upgrade authority and is kept separate from the governor.
    modifier onlyUpgrader() {
        if (msg.sender != CoreStorage.layout().upgrader) revert OnlyUpgrader();
        _;
    }

    // ============ Constructor ============

    /// @notice Locks the implementation contract so it can never be initialized directly.
    /// @dev All state lives behind the proxy; the implementation must stay uninitialized.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ============ Initializer ============

    /// @notice Initialize the proxy: set roles, init bases, and deploy the DLRS token.
    /// @dev Deploys a fresh DLRS bound to this proxy (address(this)) and stores its address.
    /// @param upgrader_ The upgrader address (UUPS upgrade authority; expected: timelock).
    /// @param governor_ The governor address (risk params + registry + caps; expected: timelock).
    /// @param guardian_ The guardian address (tightens caps, haircuts escrow; expected: multisig).
    /// @param unpauser_ The unpauser address (lifts pauses, sets pausers; expected: multisig).
    /// @param pausers_ The addresses that may pause from the first block.
    function initialize(
        address upgrader_,
        address governor_,
        address guardian_,
        address unpauser_,
        address[] calldata pausers_
    ) external initializer {
        if (upgrader_ == address(0)) revert ZeroAddress();
        if (governor_ == address(0)) revert ZeroAddress();
        if (guardian_ == address(0)) revert ZeroAddress();
        if (unpauser_ == address(0)) revert ZeroAddress();

        __Pausable_init();
        // ReentrancyGuard (OZ v5.6+) is stateless/namespaced and has no initializer:
        // the guard slot defaults to 0, which `_nonReentrantBefore` treats as NOT_ENTERED.

        CoreStorage.Layout storage $ = CoreStorage.layout();
        $.upgrader = upgrader_;
        $.governor = governor_;
        $.guardian = guardian_;
        $.unpauser = unpauser_;
        for (uint256 i; i < pausers_.length; ++i) {
            _setPauser($, pausers_[i], true);
        }
        $.dlrs = address(new DLRS(address(this)));
        $.pegTolerance = DEFAULT_PEG_TOLERANCE_BPS;
        $.maxStaleness = DEFAULT_MAX_STALENESS;

        // Create the hub pool (poolId 0). Spoke pools (poolId >= 1) are created later.
        RegistryStorage.Pool storage hub = RegistryStorage.layout().pools.push();
        hub.kind = RegistryStorage.PoolKind.Hub;
        emit PoolCreated(0, uint8(RegistryStorage.PoolKind.Hub));
    }

    // ============ Getters ============

    /// @inheritdoc IDollarStore
    function governor() external view override returns (address) {
        return CoreStorage.layout().governor;
    }

    /// @inheritdoc IDollarStore
    function guardian() external view override returns (address) {
        return CoreStorage.layout().guardian;
    }

    /// @inheritdoc IDollarStore
    function pendingGovernor() external view override returns (address) {
        return CoreStorage.layout().pendingGovernor;
    }

    /// @inheritdoc IDollarStore
    function pendingGuardian() external view override returns (address) {
        return CoreStorage.layout().pendingGuardian;
    }

    /// @inheritdoc IDollarStore
    function upgrader() external view override returns (address) {
        return CoreStorage.layout().upgrader;
    }

    /// @inheritdoc IDollarStore
    function pendingUpgrader() external view override returns (address) {
        return CoreStorage.layout().pendingUpgrader;
    }

    /// @inheritdoc IDollarStore
    function unpauser() external view override returns (address) {
        return CoreStorage.layout().unpauser;
    }

    /// @inheritdoc IDollarStore
    function isPauser(address account) external view override returns (bool) {
        return CoreStorage.layout().pausers[account];
    }

    /// @inheritdoc IDollarStore
    function dlrs() external view override returns (address) {
        return CoreStorage.layout().dlrs;
    }

    /// @inheritdoc IDollarStore
    function version() external pure override returns (string memory) {
        return "1.0.0";
    }

    // ============ Two-step Role Transfers ============

    /// @inheritdoc IDollarStore
    /// @dev Governor-gated. The new governor must call acceptGovernor to take the role.
    function transferGovernor(address newGovernor) external override onlyGovernor {
        if (newGovernor == address(0)) revert ZeroAddress();
        CoreStorage.Layout storage $ = CoreStorage.layout();
        $.pendingGovernor = newGovernor;
        emit GovernorTransferInitiated($.governor, newGovernor);
    }

    /// @inheritdoc IDollarStore
    /// @dev Callable only by the pending governor.
    function acceptGovernor() external override {
        CoreStorage.Layout storage $ = CoreStorage.layout();
        if (msg.sender != $.pendingGovernor) revert OnlyPendingGovernor();
        address previousGovernor = $.governor;
        $.governor = $.pendingGovernor;
        $.pendingGovernor = address(0);
        emit GovernorTransferCompleted(previousGovernor, $.governor);
    }

    /// @inheritdoc IDollarStore
    /// @dev Governor-gated (NOT guardian-gated): if the guardian could rotate itself, a
    ///      compromised guardian could lock out the legitimate one. The governor's slower
    ///      path protects the emergency role. Same rationale as the prior design.
    function transferGuardian(address newGuardian) external override onlyGovernor {
        if (newGuardian == address(0)) revert ZeroAddress();
        CoreStorage.Layout storage $ = CoreStorage.layout();
        $.pendingGuardian = newGuardian;
        emit GuardianTransferInitiated($.guardian, newGuardian);
    }

    /// @inheritdoc IDollarStore
    /// @dev Callable only by the pending guardian.
    function acceptGuardian() external override {
        CoreStorage.Layout storage $ = CoreStorage.layout();
        if (msg.sender != $.pendingGuardian) revert OnlyPendingGuardian();
        address previousGuardian = $.guardian;
        $.guardian = $.pendingGuardian;
        $.pendingGuardian = address(0);
        emit GuardianTransferCompleted(previousGuardian, $.guardian);
    }

    /// @inheritdoc IDollarStore
    /// @dev Upgrader-gated (self-managed), NOT governor-gated: if the governor could rotate the
    ///      upgrader, a compromised governor could seize upgrade authority. The upgrader is the
    ///      most powerful role, so only it can hand itself off (two-step).
    function transferUpgrader(address newUpgrader) external override onlyUpgrader {
        if (newUpgrader == address(0)) revert ZeroAddress();
        CoreStorage.Layout storage $ = CoreStorage.layout();
        $.pendingUpgrader = newUpgrader;
        emit UpgraderTransferInitiated($.upgrader, newUpgrader);
    }

    /// @inheritdoc IDollarStore
    /// @dev Callable only by the pending upgrader.
    function acceptUpgrader() external override {
        CoreStorage.Layout storage $ = CoreStorage.layout();
        if (msg.sender != $.pendingUpgrader) revert OnlyPendingUpgrader();
        address previousUpgrader = $.upgrader;
        $.upgrader = $.pendingUpgrader;
        $.pendingUpgrader = address(0);
        emit UpgraderTransferCompleted(previousUpgrader, $.upgrader);
    }

    /// @inheritdoc IDollarStore
    function setUnpauser(address newUnpauser) external override onlyGovernor {
        if (newUnpauser == address(0)) revert ZeroAddress();
        CoreStorage.Layout storage $ = CoreStorage.layout();
        emit UnpauserSet($.unpauser, newUnpauser);
        $.unpauser = newUnpauser;
    }

    // ============ Emergency ============

    /// @inheritdoc IDollarStore
    /// @dev Any pauser, instantly. Pausing only tightens, so one address may do it alone.
    function pause() external override onlyPauser {
        _pause();
    }

    /// @inheritdoc IDollarStore
    /// @dev Unpauser-gated: lifting a pause loosens, so it does not sit with the pausers.
    function unpause() external override onlyUnpauser {
        _unpause();
    }

    /// @inheritdoc IDollarStore
    function setPauser(address account, bool allowed) external override onlyUnpauser {
        _setPauser(CoreStorage.layout(), account, allowed);
    }

    function _setPauser(CoreStorage.Layout storage $, address account, bool allowed) private {
        if (account == address(0)) revert ZeroAddress();
        $.pausers[account] = allowed;
        emit PauserSet(account, allowed);
    }

    // ============ Asset Registry ============

    /// @inheritdoc IDollarStore
    /// @dev Governor-gated. Reads and freezes the token's decimals, computes the scaling factor
    ///      (reverts if decimals are outside [6, 18]), requires a price feed, and lists the asset
    ///      into the hub (poolId 0).
    function addHubAsset(address asset, address priceFeed) external override nonReentrant onlyGovernor {
        if (asset == address(0) || priceFeed == address(0)) revert ZeroAddress();
        // Feed decimals must be <= 18: PegLib.checkPeg scales by 10**(18 - feedDecimals), which would
        // underflow (and DoS every inflow of this asset) for a feed with more than 18 decimals.
        uint8 feedDec = AggregatorV3Interface(priceFeed).decimals();
        if (feedDec > MAX_FEED_DECIMALS) revert NormalizationLib.UnsupportedDecimals(feedDec);

        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (r.assetConfig[asset].listed) revert AssetAlreadyListed(asset);

        uint8 dec = IERC20Metadata(asset).decimals();
        uint64 sf = NormalizationLib.scalingFactor(dec); // reverts UnsupportedDecimals if out of range
        // Escrow left by a removed pool must be covered before the asset holds reserves again.
        if (IERC20(asset).balanceOf(address(this)) < QueueStorage.layout().totalEscrowedByAsset[asset] * sf) {
            revert EscrowImpaired(asset);
        }

        r.assetConfig[asset] = RegistryStorage.AssetConfig({
            poolId: 0,
            decimals: dec,
            scalingFactor: sf,
            priceFeed: priceFeed,
            listed: true,
            depositPaused: r.assetConfig[asset].depositPaused,
            probeExempt: r.assetConfig[asset].probeExempt
        });
        r.pools[0].assets.push(asset);

        emit AssetListed(asset, 0, dec, priceFeed);
    }

    // ============ Spoke Lifecycle ============

    /// @inheritdoc IDollarStore
    /// @dev Governor-gated. Mirrors addHubAsset's listing guards but creates a NEW spoke pool
    ///      (poolId >= 1) and registers the asset into it. Ownership is enforced by the `listed`
    ///      flag: an already-listed asset (hub or another spoke) cannot be re-listed, so an asset
    ///      belongs to exactly one pool.
    function createSpoke(address spokeAsset, address priceFeed, uint256 minDlrsReserve_, uint256 launchCap)
        external
        override
        nonReentrant
        onlyGovernor
        returns (uint16 poolId)
    {
        // Cold path: delegated to SpokeAdminLib (runs in this proxy's storage) to keep DollarStore
        // under the EIP-170 runtime size limit.
        return SpokeAdminLib.createSpoke(spokeAsset, priceFeed, minDlrsReserve_, launchCap);
    }

    /// @inheritdoc IDollarStore
    /// @dev Governor-gated, spoke-only. The guardian must not change it (it moves market behavior).
    ///      Bounds swaps only; see IDollarStore.withdraw for why exits are senior to it.
    function setMinDlrsReserve(uint16 poolId, uint256 newMin) external override onlyGovernor {
        RegistryStorage.Pool storage p = _spokePool(poolId);
        uint256 old = p.minDlrsReserve;
        p.minDlrsReserve = newMin;
        emit MinDlrsReserveSet(poolId, old, newMin);
    }

    /// @inheritdoc IDollarStore
    /// @dev Governor-gated. A spoke can only be removed once fully drained: no spoke reserves, no
    ///      dlrsReserve. Outstanding LP shares and queued positions do NOT block removal: worthless
    ///      shares stay recorded under the retired poolId, and queue keys are pool-scoped, so a
    ///      tombstone's lines are unreachable from a replacement pool and stay cancellable by their
    ///      owners. Kills the pool by pausing it and unlisting its assets; the poolId is retired but the
    ///      pool stays as a tombstone in the array so later poolIds never shift. Body lives in
    ///      SpokeLifecycleLib to keep this implementation under the EIP-170 limit.
    function removePool(uint16 poolId) external override nonReentrant onlyGovernor {
        SpokeLifecycleLib.removePool(poolId);
    }

    /// @inheritdoc IDollarStore
    /// @dev Governor-gated, spoke-only. Enters the winding-down state: `_validateRoute` then blocks
    ///      risk-increasing spoke->hub trades and `deposit` blocks new spoke liquidity, while LP exits,
    ///      cancellations, and risk-reducing hub->spoke trades stay live. Body in SpokeLifecycleLib.
    function windDownSpoke(uint16 poolId) external override nonReentrant onlyGovernor {
        SpokeLifecycleLib.windDownSpoke(poolId);
    }

    /// @inheritdoc IDollarStore
    function getPoolStatus(uint16 poolId) external view override returns (uint8) {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId);
        return uint8(r.pools[poolId].status);
    }

    /// @dev Returns the spoke pool at `poolId`, reverting InvalidPool if it does not exist and
    ///      PoolNotSpoke if it is the hub (poolId 0, which exists but is not a spoke).
    function _spokePool(uint16 poolId) internal view returns (RegistryStorage.Pool storage p) {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId);
        p = r.pools[poolId];
        if (p.kind != RegistryStorage.PoolKind.Spoke) revert PoolNotSpoke(poolId);
    }

    /// @inheritdoc IDollarStore
    function getMinDlrsReserve(uint16 poolId) external view override returns (uint256) {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId);
        return r.pools[poolId].minDlrsReserve;
    }

    /// @inheritdoc IDollarStore
    function getDlrsReserve(uint16 poolId) external view override returns (uint256) {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId);
        return r.pools[poolId].dlrsReserve;
    }

    /// @inheritdoc IDollarStore
    function getReceiptShares(uint16 poolId, address owner_) external view override returns (uint256) {
        return RegistryStorage.layout().receiptShares[poolId][owner_];
    }

    /// @inheritdoc IDollarStore
    function getReceiptTotalShares(uint16 poolId) external view override returns (uint256) {
        return RegistryStorage.layout().receiptTotalShares[poolId];
    }

    /// @inheritdoc IDollarStore
    function poolKind(uint16 poolId) external view override returns (uint8) {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId);
        return uint8(r.pools[poolId].kind);
    }

    /// @inheritdoc IDollarStore
    function isAssetListed(address asset) external view override returns (bool) {
        return RegistryStorage.layout().assetConfig[asset].listed;
    }

    /// @inheritdoc IDollarStore
    function assetDecimals(address asset) external view override returns (uint8) {
        return RegistryStorage.layout().assetConfig[asset].decimals;
    }

    /// @inheritdoc IDollarStore
    function assetScalingFactor(address asset) external view override returns (uint64) {
        return RegistryStorage.layout().assetConfig[asset].scalingFactor;
    }

    /// @inheritdoc IDollarStore
    function assetPoolId(address asset) external view override returns (uint16) {
        return RegistryStorage.layout().assetConfig[asset].poolId;
    }

    /// @inheritdoc IDollarStore
    function assetPriceFeed(address asset) external view override returns (address) {
        return RegistryStorage.layout().assetConfig[asset].priceFeed;
    }

    /// @inheritdoc IDollarStore
    function getReserve(uint16 poolId, address asset) external view override returns (uint256) {
        return RegistryStorage.layout().reserves[poolId][asset];
    }

    /// @inheritdoc IDollarStore
    function poolCount() external view override returns (uint256) {
        return RegistryStorage.layout().pools.length;
    }

    /// @inheritdoc IDollarStore
    function getPoolAssets(uint16 poolId) external view override returns (address[] memory) {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId);
        return r.pools[poolId].assets;
    }

    /// @inheritdoc IDollarStore
    function getReserves(uint16 poolId)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts)
    {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId);
        assets = r.pools[poolId].assets;
        amounts = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            amounts[i] = r.reserves[poolId][assets[i]];
        }
    }

    // ============ Hub Deposit / Withdraw ============

    /// @inheritdoc IDollarStore
    /// @dev Routes to the hub (poolId 0, mints DLRS 1:1) or a spoke (poolId >= 1). A spoke deposit is
    ///      either the spoke's own asset (enters the spoke reserve) or a hub asset that funds the
    ///      spoke's dlrsReserve; both mint pro-rata receipt shares. New exposure is gated by global
    ///      pause + reentrancy guard. Pulls only `amountIn` (= units * scalingFactor) from the caller;
    ///      sub-unit dust stays with the caller. A before/after balance check rejects fee-on-transfer
    ///      tokens. The DLRS or receipt shares are credited to `receiver`.
    function deposit(uint16 poolId, address asset, uint256 amount, address receiver, uint256 deadline)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 amountIn, uint256 receiptAmount)
    {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
        if (receiver == address(0) || receiver == address(this)) revert InvalidRecipient(receiver);

        RegistryStorage.Layout storage r = RegistryStorage.layout();
        RegistryStorage.AssetConfig memory cfg = r.assetConfig[asset];
        if (!cfg.listed) revert AssetNotListed(asset);

        if (poolId == 0) {
            // Hub deposit: asset must be a hub asset; mints DLRS 1:1.
            if (cfg.poolId != 0) revert WrongPool(asset, poolId);
            return _depositHub(r, asset, cfg.scalingFactor, amount, receiver);
        }

        // Spoke deposit. The pool must be a live, active spoke (no new liquidity once winding down).
        RegistryStorage.Pool storage p = _spokePool(poolId);
        if (p.paused) revert PoolPaused(poolId);
        if (p.status != RegistryStorage.PoolStatus.Active) revert SpokeWindingDown(poolId);
        if (cfg.poolId == poolId) {
            // The spoke's own asset enters that spoke's active reserve.
            return _depositSpokeAsset(r, p, poolId, asset, cfg.scalingFactor, amount, receiver);
        }
        if (cfg.poolId == 0) {
            // A hub asset funds the spoke's DLRS side (enters hub reserves, credits dlrsReserve).
            return _depositSpokeFunding(r, p, poolId, asset, cfg.scalingFactor, amount, receiver);
        }
        revert WrongPool(asset, poolId); // asset belongs to a different spoke
    }

    /// @dev Hub deposit: pull the hub asset from the caller into hub reserves and mint DLRS 1:1 to
    ///      `receiver`.
    function _depositHub(
        RegistryStorage.Layout storage r,
        address asset,
        uint64 scaling,
        uint256 amount,
        address receiver
    ) internal returns (uint256 nativePulled, uint256 units) {
        PegLib.checkInflow(asset); // per-asset/hub-pool deposit pause + oracle peg check
        (units, nativePulled) = NormalizationLib.toUnits(amount, scaling);
        if (units == 0) revert ZeroAmount();

        _checkLaunchCap(0, units);
        _pullExact(asset, nativePulled); // rejects fee-on-transfer

        r.reserves[0][asset] += units;
        DLRS(CoreStorage.layout().dlrs).mint(receiver, units);

        emit Deposit(receiver, 0, asset, msg.sender, nativePulled, units);
    }

    /// @dev Spoke-asset LP: the spoke asset enters that spoke's active reserve and mints receipt shares
    ///      to `receiver` pro-rata against the pool value (spokeReserve + dlrsReserve). No DLRS is minted.
    function _depositSpokeAsset(
        RegistryStorage.Layout storage r,
        RegistryStorage.Pool storage p,
        uint16 poolId,
        address asset,
        uint64 scaling,
        uint256 amount,
        address receiver
    ) internal returns (uint256 nativePulled, uint256 shares) {
        PegLib.checkInflow(asset); // spoke asset: deposit pause + spoke-pool pause + peg
        uint256 units;
        (units, nativePulled) = NormalizationLib.toUnits(amount, scaling);
        if (units == 0) revert ZeroAmount();

        uint256 poolValueBefore = r.reserves[poolId][asset] + p.dlrsReserve;
        shares = SpokeShareLib.sharesForDeposit(units, poolValueBefore, r.receiptTotalShares[poolId]);

        _checkLaunchCap(poolId, units);
        _pullExact(asset, nativePulled);

        r.reserves[poolId][asset] += units;
        r.receiptShares[poolId][receiver] += shares;
        r.receiptTotalShares[poolId] += shares;

        emit SpokeLiquidityAdded(poolId, receiver, asset, msg.sender, nativePulled, units, shares);

        // The new spoke reserve can now settle waiting hub->spoke demand (hubAsset -> this spoke asset).
        _triggerSpokeQueues(asset, true);
    }

    /// @dev Hub-asset LP into a spoke: the hub asset enters HUB reserves and credits the spoke's
    ///      internal `dlrsReserve` (streamlined, no wallet DLRS round-trip), minting receipt shares to
    ///      `receiver` pro-rata. Hub-reserve backing and dlrsReserve grow together, preserving DLRS conservation.
    function _depositSpokeFunding(
        RegistryStorage.Layout storage r,
        RegistryStorage.Pool storage p,
        uint16 poolId,
        address hubAsset,
        uint64 scaling,
        uint256 amount,
        address receiver
    ) internal returns (uint256 nativePulled, uint256 shares) {
        PegLib.checkInflow(hubAsset); // hub asset: deposit pause + hub-pool pause + peg
        uint256 units;
        (units, nativePulled) = NormalizationLib.toUnits(amount, scaling);
        if (units == 0) revert ZeroAmount();

        address spokeAsset = p.assets[0]; // a spoke has exactly one spoke asset
        uint256 poolValueBefore = r.reserves[poolId][spokeAsset] + p.dlrsReserve;
        shares = SpokeShareLib.sharesForDeposit(units, poolValueBefore, r.receiptTotalShares[poolId]);

        _checkLaunchCap(poolId, units);
        _pullExact(hubAsset, nativePulled);

        r.reserves[0][hubAsset] += units; // hub asset backs the new DLRS-side liquidity
        p.dlrsReserve += units; // credit the spoke's DLRS side (no wallet DLRS minted)
        r.receiptShares[poolId][receiver] += shares;
        r.receiptTotalShares[poolId] += shares;

        emit SpokeLiquidityAdded(poolId, receiver, hubAsset, msg.sender, nativePulled, units, shares);

        // The new DLRS side can now settle waiting spoke->hub demand (this spoke asset -> hubAsset).
        _triggerSpokeQueues(spokeAsset, false);
    }

    /// @dev After spoke liquidity is added, settle (bounded, FIFO) the directed queues the new
    ///      liquidity can now fill. A spoke-asset deposit enables hub->spoke demand for every hub asset
    ///      (`spokeIsWant == true`, queues hubAsset -> spokeAsset); a hub-asset funding deposit enables
    ///      spoke->hub demand for every hub asset (`spokeIsWant == false`, queues spokeAsset -> hubAsset).
    ///      Bounded by the small, fixed hub-asset count x MAX_INLINE_SETTLE. The spoke is known live
    ///      (deposit already checked it is not paused).
    function _triggerSpokeQueues(address spokeAsset, bool spokeIsWant) internal {
        // Directed-queue settlement lives in SwapRouteLib (delegatecall, same storage).
        SwapRouteLib.triggerSpokeQueues(spokeAsset, spokeIsWant);
    }

    /// @inheritdoc IDollarStore
    /// @dev Exit path: NOT blocked by pause (only by the reentrancy guard). An exit can still fail if a
    ///      pool asset will not transfer to the caller, or after a governance write-down.
    ///      Proportional: the caller receives their share of every asset the pool holds. Not gated by
    ///      minDlrsReserve. Body in SpokeLifecycleLib (delegatecall, same storage, preserves
    ///      msg.sender); the nonReentrant guard here holds for the whole delegated call.
    function withdraw(uint16 poolId, uint256 receiptAmount, uint256[] calldata minAmountsOut, uint256 deadline)
        external
        override
        nonReentrant
        returns (address[] memory assets, uint256[] memory amounts)
    {
        return SpokeLifecycleLib.withdraw(poolId, receiptAmount, minAmountsOut, deadline);
    }

    /// @inheritdoc IDollarStore
    function previewWithdraw(uint16 poolId, uint256 receiptAmount)
        external
        view
        override
        returns (address[] memory assets, uint256[] memory amounts)
    {
        return SpokeLifecycleLib.previewWithdraw(poolId, receiptAmount);
    }

    // ============ Directed Swaps & Queues ============

    /// @inheritdoc IDollarStore
    /// @dev Fill order: exact-opposite queue -> protocol reserves (only if the same-direction
    ///      queue is empty) -> queue the remainder. Hub-hub swaps are reserve-neutral (no DLRS
    ///      mint/burn) — they move reserve value 1:1 between assets.
    function swapOrQueue(address offerAsset, address wantAsset, uint256 amount, uint256 minAmountOut, uint256 deadline)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 amountIn, uint256 amountOut, uint256 amountInQueued, uint256 positionId)
    {
        // Directed-swap engine lives in SwapRouteLib (delegatecall, same storage, preserves
        // msg.sender). The nonReentrant + whenNotPaused guards here hold for the whole delegated call.
        return SwapRouteLib.swapOrQueue(offerAsset, wantAsset, amount, minAmountOut, deadline);
    }

    /// @inheritdoc IDollarStore
    /// @dev All-or-nothing: fills fully from opposite queue + reserves or reverts. Never queues.
    function swapExactInput(
        address offerAsset,
        address wantAsset,
        uint256 amount,
        uint256 minAmountOut,
        address recipient,
        uint256 deadline
    ) external override nonReentrant whenNotPaused returns (uint256 amountIn, uint256 amountOut) {
        return SwapRouteLib.swapExactInput(offerAsset, wantAsset, amount, minAmountOut, recipient, deadline);
    }

    /// @inheritdoc IDollarStore
    function swapSpokeToSpoke(
        address offerAsset,
        address wantAsset,
        address[] calldata via,
        uint256 amount,
        address recipient,
        uint256 deadline
    ) external override nonReentrant whenNotPaused returns (uint256 amountIn, uint256 amountOut) {
        return SwapRouteLib.swapSpokeToSpoke(offerAsset, wantAsset, via, amount, recipient, deadline);
    }

    /// @inheritdoc IDollarStore
    /// @dev Exit path: not blocked by pause. Returns the escrowed offer. If the transfer fails, a
    ///      queued position is parked and a parked one reverts. Body in SwapRouteLib.
    function cancelQueue(uint256 positionId) external override nonReentrant {
        QueueStorage.QueuePosition storage p = QueueStorage.layout().positions[positionId];
        if (p.owner == address(0)) revert QueuePositionNotFound(positionId);
        if (p.owner != msg.sender) revert NotPositionOwner(positionId, msg.sender);
        SwapRouteLib.cancelPosition(positionId);
    }

    /// @inheritdoc IDollarStore
    /// @dev Fills the (offerAsset -> wantAsset) queue from reserves[wantAsset] in FIFO order,
    ///      bounded by `maxPositions`. Each fill moves the owner's escrowed offer into reserves.
    function processQueue(address offerAsset, address wantAsset, uint256 maxPositions)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 positionsProcessed, uint256 amountFilled)
    {
        // Directed-queue settlement (route validation + inflow gate + FIFO reserve fill) lives in
        // SwapRouteLib (delegatecall, same storage).
        return SwapRouteLib.processQueue(offerAsset, wantAsset, maxPositions);
    }

    // ============ Swap / Queue Views ============

    /// @inheritdoc IDollarStore
    function getQueueDepth(address offerAsset, address wantAsset) external view override returns (uint256) {
        (, uint256 depth) = _routeLine(offerAsset, wantAsset);
        return depth;
    }

    /// @inheritdoc IDollarStore
    function getQueuePosition(uint256 positionId)
        external
        view
        override
        returns (address, address, address, uint256, uint256, uint16)
    {
        QueueStorage.QueuePosition storage p = QueueStorage.layout().positions[positionId];
        return (p.owner, p.offerAsset, p.wantAsset, p.offerAmount, p.timestamp, p.poolId);
    }

    /// @inheritdoc IDollarStore
    function getUserQueuePositions(address user) external view override returns (uint256[] memory) {
        return QueueStorage.layout().userPositions[user];
    }

    /// @inheritdoc IDollarStore
    function isQueuePositionParked(uint256 positionId) external view override returns (bool) {
        return QueueStorage.layout().positions[positionId].parked;
    }

    /// @inheritdoc IDollarStore
    function getMinimumOrderSize(address offerAsset, address wantAsset) external view override returns (uint256) {
        // The parked line takes no orders, so its length sets no minimum.
        uint256 count;
        if (wantAsset != address(0)) (count,) = _routeLine(offerAsset, wantAsset);
        return QueueLib.minimumOrderSize(count);
    }

    /// @inheritdoc IDollarStore
    function getSwapQuote(address offerAsset, address wantAsset, uint256 amount)
        external
        view
        override
        returns (uint256)
    {
        if (paused()) return 0;
        return SwapRouteLib.quote(offerAsset, wantAsset, amount);
    }

    /// @dev The line a directed pair currently uses, for the pair-based views. `wantAsset == 0` is the
    ///      parked line of `offerAsset`, listed or not. Otherwise both assets must be listed, else the
    ///      pair routes nowhere and an empty line is returned, so a removed pool's lines are never
    ///      reported. The pool is the spoke's for a hub<->spoke pair and 0 for hub-to-hub, as in
    ///      SwapRouteLib.classifyRoute.
    function _routeLine(address offerAsset, address wantAsset)
        internal
        view
        returns (uint256 positionCount, uint256 totalDepth)
    {
        bytes32 key;
        if (wantAsset == address(0)) {
            key = QueueStorage.parkedKey(offerAsset);
        } else {
            RegistryStorage.AssetConfig storage o = RegistryStorage.layout().assetConfig[offerAsset];
            RegistryStorage.AssetConfig storage w = RegistryStorage.layout().assetConfig[wantAsset];
            if (!o.listed || !w.listed) return (0, 0);
            key = QueueStorage.queueKey(offerAsset, wantAsset, o.poolId != 0 ? o.poolId : w.poolId);
        }
        QueueStorage.Queue storage q = QueueStorage.layout().queues[key];
        return (q.positionCount, q.totalDepth);
    }

    // ============ Internal: token pull (shared by deposit) ============

    /// @dev Pull exactly `nativeAmount` of `asset`, rejecting fee-on-transfer via a balance check.
    function _pullExact(address asset, uint256 nativeAmount) internal {
        uint256 balBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransferFrom(msg.sender, address(this), nativeAmount);
        uint256 received = IERC20(asset).balanceOf(address(this)) - balBefore;
        if (received < nativeAmount) revert FeeOnTransferNotSupported(asset);
    }

    // The directed-swap fill / FIFO settle / enqueue / park / cancel machinery lives in
    // SwapRouteLib (linked, delegatecall over the same ERC-7201 storage). swapOrQueue / swapExactInput /
    // swapSpokeToSpoke / processQueue / cancelQueue / _triggerSpokeQueues delegate into it. Kept out of this
    // implementation to fit under the EIP-170 24576-byte runtime limit (accepted delegatecall cost on
    // the swap path).

    // ============ Risk Controls ============

    /// @inheritdoc IDollarStore
    function setPriceFeed(address asset, address feed) external override onlyGovernor {
        if (feed == address(0)) revert ZeroAddress();
        uint8 feedDec = AggregatorV3Interface(feed).decimals();
        if (feedDec > MAX_FEED_DECIMALS) revert NormalizationLib.UnsupportedDecimals(feedDec);
        RegistryStorage.AssetConfig storage cfg = RegistryStorage.layout().assetConfig[asset];
        if (!cfg.listed) revert AssetNotListed(asset);
        cfg.priceFeed = feed;
        emit PriceFeedUpdated(asset, feed);
    }

    /// @inheritdoc IDollarStore
    function setProbeExempt(address asset, bool exempt) external override onlyGovernor {
        RegistryStorage.AssetConfig storage cfg = RegistryStorage.layout().assetConfig[asset];
        if (!cfg.listed) revert AssetNotListed(asset);
        cfg.probeExempt = exempt;
        emit ProbeExemptSet(asset, exempt);
    }

    /// @inheritdoc IDollarStore
    function isProbeExempt(address asset) external view override returns (bool) {
        return RegistryStorage.layout().assetConfig[asset].probeExempt;
    }

    /// @inheritdoc IDollarStore
    function setPegTolerance(uint256 tolerance) external override onlyGovernor {
        if (tolerance == 0 || tolerance > MAX_PEG_TOLERANCE_BPS) revert InvalidTolerance();
        CoreStorage.layout().pegTolerance = tolerance;
        emit PegToleranceSet(tolerance);
    }

    /// @inheritdoc IDollarStore
    function setMaxStaleness(uint256 staleness) external override onlyGovernor {
        if (staleness == 0 || staleness > MAX_STALENESS) revert InvalidStaleness();
        CoreStorage.layout().maxStaleness = staleness;
        emit MaxStalenessSet(staleness);
    }

    /// @inheritdoc IDollarStore
    function pauseDeposits(address asset) external override onlyPauser {
        RegistryStorage.AssetConfig storage cfg = RegistryStorage.layout().assetConfig[asset];
        if (!cfg.listed) revert AssetNotListed(asset);
        cfg.depositPaused = true;
        emit DepositsPausedSet(asset, true);
    }

    /// @inheritdoc IDollarStore
    function unpauseDeposits(address asset) external override onlyUnpauser {
        RegistryStorage.AssetConfig storage cfg = RegistryStorage.layout().assetConfig[asset];
        if (!cfg.listed) revert AssetNotListed(asset);
        cfg.depositPaused = false;
        emit DepositsPausedSet(asset, false);
    }

    /// @inheritdoc IDollarStore
    function pausePool(uint16 poolId) external override onlyPauser {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId);
        r.pools[poolId].paused = true;
        emit PoolPausedSet(poolId, true);
    }

    /// @inheritdoc IDollarStore
    function unpausePool(uint16 poolId) external override onlyUnpauser {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId);
        if (r.pools[poolId].status == RegistryStorage.PoolStatus.Killed) revert PoolKilled(poolId);
        r.pools[poolId].paused = false;
        emit PoolPausedSet(poolId, false);
    }

    /// @inheritdoc IDollarStore
    /// @dev Escrow-aware: reserves sync down to (actualBalance - escrow). Only decreases.
    function syncReserves(uint16 poolId, address asset) external override nonReentrant onlyGovernor {
        // Cold path: delegated to SpokeAdminLib to keep DollarStore under the EIP-170 runtime size limit.
        SpokeAdminLib.syncReserves(poolId, asset);
    }

    /// @inheritdoc IDollarStore
    /// @dev Sweeps only the excess above accounted: queue escrow always, plus reserves while listed.
    function rescueTokens(address asset, address to) external override nonReentrant onlyGovernor {
        // Cold path: delegated to SpokeAdminLib to keep DollarStore under the EIP-170 runtime size limit.
        SpokeAdminLib.rescueTokens(asset, to);
    }

    /// @inheritdoc IDollarStore
    /// @dev Guardian emergency, paused-only. Reduces the queue escrow of a balance-impaired asset
    ///      pro-rata so the escrow accounting fits the surviving token balance. Only touches queue
    ///      positions; the reserve (LP) side is handled separately by syncReserves + share exposure.
    ///      Body in SpokeLifecycleLib to keep this implementation under the EIP-170 runtime size limit.
    function haircutEscrow(address asset, uint256 maxPositions)
        external
        override
        onlyGuardian
        // onlyGuardian only compares the caller with storage.
        // forge-lint: disable-next-line(non-reentrant-not-first)
        nonReentrant
        returns (uint256 removedUnits)
    {
        return SpokeLifecycleLib.haircutEscrow(asset, maxPositions);
    }

    // ============ Risk Views ============

    /// @inheritdoc IDollarStore
    function isDepositPaused(address asset) external view override returns (bool) {
        return RegistryStorage.layout().assetConfig[asset].depositPaused;
    }

    /// @inheritdoc IDollarStore
    function isPoolPaused(uint16 poolId) external view override returns (bool) {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId);
        return r.pools[poolId].paused;
    }

    /// @inheritdoc IDollarStore
    function pegTolerance() external view override returns (uint256) {
        return CoreStorage.layout().pegTolerance;
    }

    /// @inheritdoc IDollarStore
    function maxStaleness() external view override returns (uint256) {
        return CoreStorage.layout().maxStaleness;
    }

    // ============ Launch Caps ============

    /// @inheritdoc IDollarStore
    function setLaunchCap(uint16 poolId, uint256 cap) external override onlyGovernor {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId);
        r.pools[poolId].launchCap = cap;
        emit LaunchCapSet(poolId, cap);
    }

    /// @inheritdoc IDollarStore
    function lowerLaunchCap(uint16 poolId, uint256 cap) external override onlyGuardian {
        if (cap == 0) revert CapNotStricter(); // 0 would remove/loosen — governor-only
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId);
        uint256 current = r.pools[poolId].launchCap;
        // Stricter = a positive cap below the current one (or any positive value if uncapped).
        if (current != 0 && cap >= current) revert CapNotStricter();
        r.pools[poolId].launchCap = cap;
        emit LaunchCapSet(poolId, cap);
    }

    /// @inheritdoc IDollarStore
    function getLaunchCap(uint16 poolId) external view override returns (uint256) {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId);
        return r.pools[poolId].launchCap;
    }

    /// @dev Enforce a pool's launch cap against its active exposure. cap == 0 means no cap. Queue
    ///      escrow is excluded from exposure (it is not active pool liquidity). For the hub (poolId 0),
    ///      exposure == total DLRS supply (backed 1:1 by hub reserves). For a spoke, exposure == that
    ///      spoke's asset reserve + its dlrsReserve.
    function _checkLaunchCap(uint16 poolId, uint256 addedUnits) internal view {
        RegistryStorage.Layout storage r = RegistryStorage.layout();
        if (poolId >= r.pools.length) revert InvalidPool(poolId); // defense-in-depth (callers validate)
        RegistryStorage.Pool storage p = r.pools[poolId];
        uint256 cap = p.launchCap;
        if (cap == 0) return;
        uint256 newExposure;
        if (poolId == 0) {
            newExposure = DLRS(CoreStorage.layout().dlrs).totalSupply() + addedUnits;
        } else {
            newExposure = r.reserves[poolId][p.assets[0]] + p.dlrsReserve + addedUnits;
        }
        if (newExposure > cap) revert LaunchCapExceeded(poolId, newExposure, cap);
    }

    // ============ UUPS Upgrade Authorization ============

    /// @notice Authorize a UUPS upgrade. Upgrader-gated (separate from the governor).
    /// @dev In production the upgrader is a TimelockController (longest delay), so upgrades carry
    ///      a public delay and cannot be triggered by a governor or guardian compromise alone.
    /// @param newImplementation The address of the new implementation (validated by UUPS machinery).
    function _authorizeUpgrade(address newImplementation) internal override onlyUpgrader {}
}
