// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title RegistryStorage - ERC-7201 namespaced storage for the asset registry, pools and reserves
/// @notice Single source of truth for "what assets/pools exist and how much each pool holds".
/// @dev Reserves and DLRS-side bookkeeping are tracked in normalized 6-decimal units.
///      The Pool struct carries ALL its fields from day one because Pool lives in a dynamic
///      array (Pool[]), and growing a struct stored in an array after deployment is unsafe.
///      `receiptToken` is unused and kept only for the layout, and a __gap tail lets future pool-level fields be carved out later without changing
///      the struct's total size (so array elements never shift).
/// @custom:security-contact admin@dollarstore.world
library RegistryStorage {
    /// @notice Pool kind. Hub = poolId 0 (USDC/USDT + DLRS). Spoke = poolId >= 1 (one challenger asset).
    enum PoolKind {
        Hub,
        Spoke
    }

    /// @notice Spoke lifecycle. Active = normal. WindingDown = stop new risk (no deposits, no
    ///         risk-increasing spoke->hub trades) but exits/cancels/risk-reducing hub->spoke stay live.
    ///         Killed = terminal (removePool, once fully drained). Default 0 = Active.
    enum PoolStatus {
        Active,
        WindingDown,
        Killed
    }

    /// @notice Per-asset configuration. `decimals` is read once and frozen at listing.
    struct AssetConfig {
        /// @notice The canonical pool this asset belongs to (an asset belongs to exactly one pool).
        uint16 poolId;
        /// @notice Token decimals, frozen at listing (must be in [6, 18]).
        uint8 decimals;
        /// @notice 10**(decimals - 6); converts native amounts to/from normalized 6dp units.
        uint64 scalingFactor;
        /// @notice Chainlink price feed (required at listing; used by the peg check).
        address priceFeed;
        /// @notice Whether the asset is listed/supported.
        bool listed;
        /// @notice Per-asset deposit pause: set by a pauser, lifted by the unpauser.
        bool depositPaused;
        /// @notice Skip the zero-value transfer probe on exits for this asset (governor). For tokens whose
        ///         transfer controls are not exercised by a zero-value transfer, or that reject one.
        bool probeExempt;
    }

    /// @notice A pool (hub or spoke). All fields declared now (array-stored struct, see @dev above).
    struct Pool {
        /// @notice Hub or Spoke.
        PoolKind kind;
        /// @notice Per-pool pause.
        bool paused;
        /// @notice Assets that belong to this pool.
        address[] assets;
        /// @notice DLRS-side reserve internal to a spoke (normalized 6dp). Unused for the hub.
        uint256 dlrsReserve;
        /// @notice Minimum DLRS-side liquidity a spoke keeps from spoke->hub SWAPS. LP exits are
        ///         senior to it and may take dlrsReserve below this value.
        uint256 minDlrsReserve;
        /// @notice Temporary launch exposure cap. 0 = no cap.
        uint256 launchCap;
        /// @notice Unused; kept only for the storage layout. Always address(0).
        address receiptToken;
        /// @notice Spoke lifecycle status. Packs into `receiptToken`'s slot (address = 20 bytes,
        ///         enum = 1 byte), so the struct's total slot count is unchanged and `__gap` stays [32].
        PoolStatus status;
        /// @notice Reserved slots for future pool-level state (route flags, receipt metadata, ...).
        ///         Since Pool lives in a Pool[] array, its total size must stay fixed: a new full-slot
        ///         field is carved from this gap (declare it and shrink __gap by the same number of
        ///         slots), so the struct size is unchanged and elements never shift. `status` above did
        ///         not consume a gap slot because it packed into the receiptToken slot.
        uint256[32] __gap;
    }

    /// @custom:storage-location erc7201:dollarstore.storage.registry
    struct Layout {
        /// @notice Asset address => its configuration. An asset is LISTED in at most one pool at a time:
        ///         relisting requires the previous pool to be killed. Queue keys are pool-scoped (see
        ///         QueueStorage.queueKey), so a killed pool's lines are never inherited by its successor.
        mapping(address => AssetConfig) assetConfig;
        /// @notice All pools. Index 0 is always the hub.
        Pool[] pools;
        /// @notice poolId => asset => active reserve (normalized 6dp).
        mapping(uint16 => mapping(address => uint256)) reserves;
        // --- appended for spokes; mappings appended at the end of a namespaced struct are
        //     layout-safe (each occupies its own base slot, existing fields never shift). ---
        /// @notice Non-transferable spoke LP receipt shares: poolId => owner => shares.
        mapping(uint16 => mapping(address => uint256)) receiptShares;
        /// @notice Total outstanding receipt shares per spoke pool: poolId => totalShares.
        mapping(uint16 => uint256) receiptTotalShares;
    }

    /// @notice Precomputed ERC-7201 storage slot for namespace "dollarstore.storage.registry".
    /// @dev keccak256(abi.encode(uint256(keccak256("dollarstore.storage.registry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant REGISTRY_STORAGE_LOCATION =
        0xcd62d958bde512a10a72d01f1689da2c81a5ee45a5235501c7bc17aa3a0b8c00;

    /// @notice Returns a storage pointer to the registry layout at the namespaced slot.
    function layout() internal pure returns (Layout storage $) {
        assembly {
            $.slot := REGISTRY_STORAGE_LOCATION
        }
    }
}
