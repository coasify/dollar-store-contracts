// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {DLRS} from "../src/DLRS.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockBlacklistERC20} from "./mocks/MockBlacklistERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {MockReentrantERC20} from "./mocks/MockReentrantERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausers} from "./utils/Pausers.sol";

/// @notice swapSpokeToSpoke: spoke A asset -> hub asset `via` -> spoke B asset in one call, fill-or-revert.
///         Net effect of a reserve fill: spoke A gains its asset and loses hub claim, spoke B loses its
///         asset and gains hub claim, hub reserves unchanged.
contract SpokeToSpokeSwapTest is Test {
    DollarStore internal store;
    DLRS internal dlrs;

    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardian");
    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");
    address internal upgrader = makeAddr("upgrader");
    address internal alice = makeAddr("alice"); // LP
    address internal bob = makeAddr("bob"); // spoke-to-spoke swapper
    address internal carol = makeAddr("carol"); // queued trader
    address internal dave = makeAddr("dave"); // queued trader

    MockERC20 internal usdc; // hub, 6dp
    MockBlacklistERC20 internal usdt; // hub, 6dp
    MockBlacklistERC20 internal pyusd; // spoke A, 6dp
    MockBlacklistERC20 internal usdg; // spoke B, 18dp
    MockAggregatorV3 internal usdcFeed;
    MockAggregatorV3 internal feed;

    uint16 internal spokeA;
    uint16 internal spokeB;

    function setUp() public {
        DollarStore impl = new DollarStore();
        bytes memory initData =
            abi.encodeCall(DollarStore.initialize, (upgrader, governor, guardian, unpauser, Pausers.one(pauser)));
        store = DollarStore(address(new ERC1967Proxy(address(impl), initData)));
        dlrs = DLRS(store.dlrs());

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usdt = new MockBlacklistERC20("Tether", "USDT", 6);
        pyusd = new MockBlacklistERC20("Spoke A", "SPA", 6);
        usdg = new MockBlacklistERC20("Spoke B", "SPB", 18);
        usdcFeed = new MockAggregatorV3(8, 1e8);
        feed = new MockAggregatorV3(8, 1e8);

        vm.startPrank(governor);
        store.addHubAsset(address(usdc), address(usdcFeed));
        store.addHubAsset(address(usdt), address(feed));
        spokeA = store.createSpoke(address(pyusd), address(feed), 0, 0);
        spokeB = store.createSpoke(address(usdg), address(feed), 0, 0);
        vm.stopPrank();

        address[5] memory who = [alice, bob, carol, dave, address(this)];
        for (uint256 i; i < who.length; i++) {
            usdc.mint(who[i], 1_000_000e6);
            usdt.mint(who[i], 1_000_000e6);
            pyusd.mint(who[i], 1_000_000e6);
            usdg.mint(who[i], 1_000_000e18);
        }
    }

    // ============ helpers ============

    function _deposit(uint16 poolId, address asset, uint256 nativeAmt) internal {
        vm.startPrank(alice);
        MockERC20(asset).approve(address(store), nativeAmt);
        store.deposit(poolId, asset, nativeAmt, alice, block.timestamp);
        vm.stopPrank();
    }

    /// @dev Spoke A holds 1,000 of hub claim (backed by USDC), spoke B holds 1,000 USDG.
    function _seedDefault() internal {
        _deposit(spokeA, address(usdc), 1_000e6);
        _deposit(spokeB, address(usdg), 1_000e18);
    }

    function _s2s(address who, address offer, address want, address via, uint256 amt) internal returns (uint256) {
        vm.startPrank(who);
        MockERC20(offer).approve(address(store), amt);
        (, uint256 out) = store.swapSpokeToSpoke(offer, want, _one(via), amt, who, block.timestamp);
        vm.stopPrank();
        return out;
    }

    function _expectS2sRevert(bytes memory err, address offer, address want, address via, uint256 amt) internal {
        vm.startPrank(bob);
        MockERC20(offer).approve(address(store), amt);
        vm.expectRevert(err);
        store.swapSpokeToSpoke(offer, want, _one(via), amt, bob, block.timestamp);
        vm.stopPrank();
    }

    /// @dev InsufficientLiquidity for a spoke-to-spoke swap, given 6-decimal fill and request amounts:
    ///      the error reports both in the wanted token's native decimals.
    function _liq(address want, uint256 fillableUnits, uint256 requestedUnits) internal view returns (bytes memory) {
        uint256 scale = 10 ** (MockERC20(want).decimals() - 6);
        return abi.encodeWithSelector(
            IDollarStore.InsufficientLiquidity.selector, want, fillableUnits * scale, requestedUnits * scale
        );
    }

    function _one(address a) internal pure returns (address[] memory v) {
        v = new address[](1);
        v[0] = a;
    }

    function _two(address a, address b) internal pure returns (address[] memory v) {
        v = new address[](2);
        v[0] = a;
        v[1] = b;
    }

    function _s2sMany(address offer, address want, address[] memory via, uint256 amt) internal returns (uint256 out) {
        vm.startPrank(bob);
        MockERC20(offer).approve(address(store), amt);
        (, out) = store.swapSpokeToSpoke(offer, want, via, amt, bob, block.timestamp);
        vm.stopPrank();
    }

    function _expectS2sManyRevert(bytes memory err, address[] memory via, uint256 amt) internal {
        vm.startPrank(bob);
        pyusd.approve(address(store), amt);
        vm.expectRevert(err);
        store.swapSpokeToSpoke(address(pyusd), address(usdg), via, amt, bob, block.timestamp);
        vm.stopPrank();
    }

    function _swap(address who, address offer, address want, uint256 amt) internal returns (uint256 filled) {
        vm.startPrank(who);
        MockERC20(offer).approve(address(store), amt);
        (, filled,,) = store.swapOrQueue(offer, want, amt, 0, block.timestamp);
        vm.stopPrank();
    }

    function _assertConservation() internal view {
        assertEq(
            dlrs.totalSupply() + store.getDlrsReserve(spokeA) + store.getDlrsReserve(spokeB),
            store.getReserve(0, address(usdc)) + store.getReserve(0, address(usdt)),
            "DLRS supply + spoke claims == hub reserves"
        );
    }

    // ============ fills ============

    function test_s2s_fillsFromReserves_movesHubClaimOnly() public {
        _seedDefault();

        uint256 out = _s2s(bob, address(pyusd), address(usdg), address(usdc), 400e6);

        assertEq(out, 400e18, "native USDG out");
        assertEq(pyusd.balanceOf(bob), 1_000_000e6 - 400e6, "bob paid spoke A asset");
        assertEq(usdg.balanceOf(bob), 1_000_000e18 + 400e18, "bob got spoke B asset");
        assertEq(store.getReserve(spokeA, address(pyusd)), 400e6, "spoke A asset up");
        assertEq(store.getDlrsReserve(spokeA), 600e6, "spoke A claim down");
        assertEq(store.getReserve(spokeB, address(usdg)), 600e6, "spoke B asset down");
        assertEq(store.getDlrsReserve(spokeB), 400e6, "spoke B claim up");
        assertEq(store.getReserve(0, address(usdc)), 1_000e6, "hub reserve unchanged");
        assertEq(usdc.balanceOf(address(store)), 1_000e6, "no hub asset left over");
        _assertConservation();
    }

    function test_s2s_18dpOffer_pullsWholeUnitsOnly() public {
        _deposit(spokeB, address(usdc), 1_000e6); // spoke B claim
        _deposit(spokeA, address(pyusd), 1_000e6); // spoke A asset

        uint256 out = _s2s(bob, address(usdg), address(pyusd), address(usdc), 100e18 + 5);

        assertEq(out, 100e6, "native PYUSD out");
        assertEq(usdg.balanceOf(bob), 1_000_000e18 - 100e18, "sub-unit dust never pulled");
        _assertConservation();
    }

    function test_s2s_emitsAggregateSwapEvent() public {
        _seedDefault();
        vm.startPrank(bob);
        pyusd.approve(address(store), 400e6);
        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.Swap(bob, address(pyusd), address(usdg), bob, 400e6, 400e18, 0);
        store.swapSpokeToSpoke(address(pyusd), address(usdg), _one(address(usdc)), 400e6, bob, block.timestamp);
        vm.stopPrank();
    }

    function test_s2s_firstLegMatchesQueuedBuyer_noHubReserveNeeded() public {
        _deposit(spokeB, address(usdg), 1_000e18); // spoke A empty, hub reserves empty
        _swap(carol, address(usdc), address(pyusd), 500e6); // queues: spoke A has no asset
        assertEq(store.getQueueDepth(address(usdc), address(pyusd)), 500e6, "carol queued");

        _s2s(bob, address(pyusd), address(usdg), address(usdc), 500e6);

        assertEq(pyusd.balanceOf(carol), 1_000_000e6 + 500e6, "carol paid peer to peer");
        assertEq(store.getQueueDepth(address(usdc), address(pyusd)), 0, "carol's position filled");
        assertEq(usdg.balanceOf(bob), 1_000_000e18 + 500e18, "bob got spoke B asset");
        assertEq(store.getReserve(0, address(usdc)), 500e6, "carol's USDC became spoke B's claim");
        assertEq(store.getDlrsReserve(spokeB), 500e6, "spoke B claim up");
        assertEq(usdc.balanceOf(address(store)), 500e6, "balance == reserve");
        _assertConservation();
    }

    function test_s2s_secondLegMatchesQueuedSeller() public {
        _deposit(spokeA, address(usdc), 1_000e6); // spoke B empty
        _swap(dave, address(usdg), address(usdc), 500e18); // queues: spoke B has no claim
        assertEq(store.getQueueDepth(address(usdg), address(usdc)), 500e6, "dave queued");

        _s2s(bob, address(pyusd), address(usdg), address(usdc), 500e6);

        assertEq(usdc.balanceOf(dave), 1_000_000e6 + 500e6, "dave paid in the hub asset");
        assertEq(store.getQueueDepth(address(usdg), address(usdc)), 0, "dave's position filled");
        assertEq(usdg.balanceOf(bob), 1_000_000e18 + 500e18, "bob got dave's escrow");
        assertEq(store.getReserve(spokeB, address(usdg)), 0, "spoke B reserve untouched");
        assertEq(store.getReserve(0, address(usdc)), 500e6, "hub paid dave");
        assertEq(store.getDlrsReserve(spokeA), 500e6, "spoke A claim down");
        _assertConservation();
    }

    // ============ fill-or-revert ============

    function test_s2s_revertsWhenOfferSpokeAtFloor() public {
        _seedDefault();
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 800e6); // 200 above the floor

        _expectS2sRevert(
            _liq(address(usdg), uint256(200e6), uint256(500e6)), address(pyusd), address(usdg), address(usdc), 500e6
        );
        assertEq(store.getDlrsReserve(spokeA), 1_000e6, "nothing moved");
    }

    function test_s2s_revertsWhenHubReserveOfViaShort() public {
        _seedDefault(); // claim backed by USDC only

        _expectS2sRevert(
            _liq(address(usdg), uint256(0), uint256(500e6)), address(pyusd), address(usdg), address(usdt), 500e6
        );
    }

    function test_s2s_revertsWhenWantSpokeShort() public {
        _deposit(spokeA, address(usdc), 1_000e6);
        _deposit(spokeB, address(usdg), 300e18);

        _expectS2sRevert(
            _liq(address(usdg), uint256(300e6), uint256(500e6)), address(pyusd), address(usdg), address(usdc), 500e6
        );
        assertEq(store.getDlrsReserve(spokeA), 1_000e6, "first leg rolled back");
        assertEq(store.getReserve(spokeB, address(usdg)), 300e6, "nothing moved");
    }

    // ============ several hub assets ============

    /// @dev Spoke A holds 1,500 of hub claim backed by 1,000 USDC and 500 USDT; spoke B holds 2,000 USDG.
    function _seedSplit() internal {
        _deposit(spokeA, address(usdc), 1_000e6);
        _deposit(spokeA, address(usdt), 500e6);
        _deposit(spokeB, address(usdg), 2_000e18);
    }

    function test_s2s_splitsAcrossHubAssets() public {
        _seedSplit();

        vm.startPrank(bob);
        pyusd.approve(address(store), 1_200e6);
        vm.expectEmit(true, true, false, true, address(store));
        emit IDollarStore.SpokeSwapRouted(bob, address(usdc), 1_000e6);
        vm.expectEmit(true, true, false, true, address(store));
        emit IDollarStore.SpokeSwapRouted(bob, address(usdt), 200e6);
        (, uint256 out) = store.swapSpokeToSpoke(
            address(pyusd), address(usdg), _two(address(usdc), address(usdt)), 1_200e6, bob, block.timestamp
        );
        vm.stopPrank();

        assertEq(out, 1_200e18, "full amount delivered");
        assertEq(store.getReserve(0, address(usdc)), 1_000e6, "USDC reserve unchanged");
        assertEq(store.getReserve(0, address(usdt)), 500e6, "USDT reserve unchanged");
        assertEq(store.getDlrsReserve(spokeA), 300e6, "spoke A claim down 1,200");
        assertEq(store.getDlrsReserve(spokeB), 1_200e6, "spoke B claim up 1,200");
        _assertConservation();
    }

    function test_s2s_singleHubAssetTooSmall_reverts() public {
        _seedSplit();
        _expectS2sManyRevert(_liq(address(usdg), uint256(1_000e6), uint256(1_200e6)), _one(address(usdc)), 1_200e6);
    }

    function test_s2s_listRunsOut_reverts() public {
        _seedSplit();
        _expectS2sManyRevert(
            _liq(address(usdg), uint256(1_500e6), uint256(1_600e6)), _two(address(usdc), address(usdt)), 1_600e6
        );
        assertEq(store.getDlrsReserve(spokeA), 1_500e6, "nothing moved");
    }

    function test_s2s_skipsHubAssetThatFillsNothing() public {
        _deposit(spokeA, address(usdt), 1_000e6); // no USDC in the hub
        _deposit(spokeB, address(usdg), 1_000e18);

        uint256 out = _s2sMany(address(pyusd), address(usdg), _two(address(usdc), address(usdt)), 500e6);

        assertEq(out, 500e18, "filled through USDT");
        _assertConservation();
    }

    /// @notice A hub asset that fails the inflow check is skipped, in either position, and another one carries
    ///         the amount.
    function test_s2s_unhealthyHubAssetSkipped_otherCarriesIt() public {
        _seedSplit();
        vm.prank(pauser);
        store.pauseDeposits(address(usdt));

        vm.recordLogs();
        assertEq(
            _s2sMany(address(pyusd), address(usdg), _two(address(usdt), address(usdc)), 300e6), 300e18, "USDT first"
        );
        assertEq(
            _s2sMany(address(pyusd), address(usdg), _two(address(usdc), address(usdt)), 300e6), 300e18, "USDT last"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 routed;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IDollarStore.SpokeSwapRouted.selector) {
                routed++;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(usdc), "only USDC carried it");
            }
        }
        assertEq(routed, 2, "one routed event per call");
        _assertConservation();
    }

    /// @dev When both legs fill from reserves, leg two returns the hub asset that leg one took, so a
    ///      repeated entry finds it again.
    function test_s2s_repeatedHubAsset_reusesItsReserve() public {
        _seedSplit();

        vm.startPrank(bob);
        pyusd.approve(address(store), 1_200e6);
        vm.expectEmit(true, true, false, true, address(store));
        emit IDollarStore.SpokeSwapRouted(bob, address(usdc), 1_000e6);
        vm.expectEmit(true, true, false, true, address(store));
        emit IDollarStore.SpokeSwapRouted(bob, address(usdc), 200e6);
        (, uint256 out) = store.swapSpokeToSpoke(
            address(pyusd), address(usdg), _two(address(usdc), address(usdc)), 1_200e6, bob, block.timestamp
        );
        vm.stopPrank();

        assertEq(out, 1_200e18, "full amount through USDC twice");
        assertEq(store.getReserve(0, address(usdc)), 1_000e6, "USDC reserve unchanged");
        assertEq(store.getDlrsReserve(spokeA), 300e6, "spoke A claim down 1,200");
        _assertConservation();
    }

    function test_s2s_emptyList_reverts() public {
        _expectS2sManyRevert(
            abi.encodeWithSelector(IDollarStore.InvalidRoute.selector, address(pyusd), address(usdg)),
            new address[](0),
            1e6
        );
    }

    function test_s2s_secondLegShort_reverts() public {
        _deposit(spokeA, address(usdc), 1_000e6);
        _deposit(spokeA, address(usdt), 500e6);
        _deposit(spokeB, address(usdg), 1_100e18);

        _expectS2sManyRevert(
            _liq(address(usdg), uint256(1_100e6), uint256(1_200e6)), _two(address(usdc), address(usdt)), 1_200e6
        );
        assertEq(store.getReserve(spokeB, address(usdg)), 1_100e6, "nothing moved");
    }

    function test_s2s_secondLegShort_neverPaysFromOtherEscrow() public {
        _deposit(spokeA, address(usdc), 1_000e6);
        _deposit(spokeB, address(usdg), 300e18);
        _swap(dave, address(usdg), address(usdt), 1_000e18); // queues: no USDT in the hub

        _expectS2sManyRevert(_liq(address(usdg), uint256(300e6), uint256(500e6)), _one(address(usdc)), 500e6);
        assertEq(store.getQueueDepth(address(usdg), address(usdt)), 1_000e6, "dave's escrow intact");
    }

    function test_s2s_skippedHubAssetEmitsNoRoutedEvent() public {
        _deposit(spokeA, address(usdt), 1_000e6); // no USDC in the hub
        _deposit(spokeB, address(usdg), 1_000e18);

        vm.recordLogs();
        _s2sMany(address(pyusd), address(usdg), _two(address(usdc), address(usdt)), 500e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 routed;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IDollarStore.SpokeSwapRouted.selector) {
                routed++;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(usdt), "only USDT carried it");
            }
        }
        assertEq(routed, 1, "one routed event");
    }

    // ============ a hub asset whose second leg is short ============

    /// @dev Spoke B holds no USDG and no hub claim, so every USDG seller queues and the second leg pays
    ///      only from queued sellers. Spoke A holds no asset, so every buyer of PYUSD queues.
    function _queueSeller(address who, address via, uint256 usdgNative) internal {
        _swap(who, address(usdg), via, usdgNative);
        assertEq(store.getReserve(spokeB, address(usdg)), 0);
    }

    /// @notice One dust unit queued to buy PYUSD with USDC used to make USDC's first leg fill 1 unit that
    ///         its second leg could not pay, reverting the call before USDT was tried.
    function test_s2s_dustBuyerOnShortHubAsset_skippedForNext() public {
        _swap(carol, address(usdt), address(pyusd), 1_000e6); // USDT buyer of PYUSD
        _queueSeller(dave, address(usdt), 1_000e18); // USDG seller for USDT
        address mallory = makeAddr("mallory");
        usdc.mint(mallory, 1);
        _swap(mallory, address(usdc), address(pyusd), 1); // dust: first position on an empty line
        uint256 dustId = store.getUserQueuePositions(mallory)[0];

        uint256 out = _s2sMany(address(pyusd), address(usdg), _two(address(usdc), address(usdt)), 1_000e6);

        assertEq(out, 1_000e18, "filled through USDT");
        (,,, uint256 dustLeft,,) = store.getQueuePosition(dustId);
        assertEq(dustLeft, 1, "USDC not used: its second leg pays nothing");
        _assertConservation();
    }

    /// @notice A PYUSD seller waits on PYUSD -> USDC. USDC can carry nothing for the caller once she is
    ///         settled, so it is skipped without settling her and USDT carries the whole amount.
    function test_s2s_waitingSellerOnFirstHubAsset_skippedNotSettled() public {
        _swap(carol, address(pyusd), address(usdc), 1_000e6); // queues: no hub USDC yet
        _deposit(spokeA, address(usdt), 1_000e6); // spoke A's claim, backed by USDT
        _deposit(0, address(usdc), 1_000e6); // hub USDC; does not settle carol
        _deposit(spokeB, address(usdg), 1_000e18);
        assertEq(store.getQueueDepth(address(pyusd), address(usdc)), 1_000e6, "carol waiting");

        uint256 out = _s2sMany(address(pyusd), address(usdg), _two(address(usdc), address(usdt)), 1_000e6);

        assertEq(out, 1_000e18, "filled through USDT");
        assertEq(store.getQueueDepth(address(pyusd), address(usdc)), 1_000e6, "carol still waiting, not settled");
        _assertConservation();
    }

    /// @notice Documented limit, two hub assets: a PYUSD seller waits for 100 of spoke A's 200 claim on
    ///         PYUSD -> USDC. [USDC, USDT] pays her first, carries 100 for the caller through USDC, leaves
    ///         USDT no claim and reverts. [USDT] alone fills all 200 and leaves her waiting.
    function test_s2s_waitingSellerTakesSharedClaim_orderMatters() public {
        _deposit(spokeA, address(usdt), 200e6); // spoke A's claim, backed by USDT
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 200e6);
        _swap(carol, address(pyusd), address(usdc), 100e6); // queues at the floor
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 0);
        _deposit(0, address(usdc), 200e6);
        _deposit(spokeB, address(usdg), 200e18);

        _expectS2sManyRevert(_liq(address(usdg), 100e6, 200e6), _two(address(usdc), address(usdt)), 200e6);
        assertEq(_s2sMany(address(pyusd), address(usdg), _one(address(usdt)), 200e6), 200e18, "USDT alone fills");
        assertEq(store.getQueueDepth(address(pyusd), address(usdc)), 100e6, "carol still waiting");
        _assertConservation();
    }

    /// @notice Documented limit, three hub assets, no one queued ahead of the caller: USDC takes all of
    ///         spoke A's claim and spoke B's reserve, stranding a queued USDT buyer and a queued USDS
    ///         seller. [USDT, USDS] pairs each with one of them and fills all 200.
    function test_s2s_greedyFirstHubAssetStrandsTheOthers_orderMatters() public {
        MockERC20 usds = new MockERC20("USDS", "USDS", 18);
        vm.prank(governor);
        store.addHubAsset(address(usds), address(feed));
        usds.mint(alice, 100e18);
        _swap(carol, address(usdt), address(pyusd), 100e6); // queued buyer of PYUSD for USDT
        _deposit(spokeA, address(usdc), 100e6); // spoke A's claim
        _deposit(0, address(usds), 100e18);
        _swap(dave, address(usdg), address(usds), 100e18); // queued seller of USDG for USDS
        _deposit(spokeB, address(usdg), 100e18); // spoke B's reserve
        address[] memory three = new address[](3);
        (three[0], three[1], three[2]) = (address(usdc), address(usdt), address(usds));

        _expectS2sManyRevert(_liq(address(usdg), 100e6, 200e6), three, 200e6);
        assertEq(_s2sMany(address(pyusd), address(usdg), _two(address(usdt), address(usds)), 200e6), 200e18);
        assertEq(store.getQueueDepth(address(usdt), address(pyusd)), 0, "queued buyer filled");
        assertEq(store.getQueueDepth(address(usdg), address(usds)), 0, "queued seller filled");
        _assertConservation();
    }

    /// @notice USDC's first leg could take all 1,000 but its second leg pays only 300: 300 goes through
    ///         USDC and the remaining 700 through USDT.
    function test_s2s_shortSecondLeg_usedForWhatItPays_restThroughNext() public {
        _deposit(spokeA, address(usdc), 1_000e6);
        _deposit(spokeA, address(usdt), 1_000e6);
        _queueSeller(dave, address(usdc), 300e18);
        _queueSeller(carol, address(usdt), 1_000e18);

        vm.startPrank(bob);
        pyusd.approve(address(store), 1_000e6);
        vm.expectEmit(true, true, false, true, address(store));
        emit IDollarStore.SpokeSwapRouted(bob, address(usdc), 300e6);
        vm.expectEmit(true, true, false, true, address(store));
        emit IDollarStore.SpokeSwapRouted(bob, address(usdt), 700e6);
        (, uint256 out) = store.swapSpokeToSpoke(
            address(pyusd), address(usdg), _two(address(usdc), address(usdt)), 1_000e6, bob, block.timestamp
        );
        vm.stopPrank();

        assertEq(out, 1_000e18, "full amount delivered");
        assertEq(store.getQueueDepth(address(usdg), address(usdc)), 0, "dave filled");
        assertEq(store.getQueueDepth(address(usdg), address(usdt)), 300e6, "carol filled 700 of 1,000");
        _assertConservation();
    }

    /// @notice Outcome, not mechanics: with each hub asset's two legs funded independently, the call
    ///         fills whenever the hub assets together can carry the amount, in either order, and reverts
    ///         only when they cannot.
    function testFuzz_s2s_fillsWheneverTheHubAssetsCanCarryIt(
        uint256 firstUsdc,
        uint256 firstUsdt,
        uint256 secondUsdc,
        uint256 secondUsdt,
        uint256 amount,
        bool usdtFirst
    ) public {
        firstUsdc = bound(firstUsdc, 0, 2_000) * 1e6; // first leg: USDC backing spoke A's claim
        firstUsdt = bound(firstUsdt, 0, 2_000) * 1e6;
        secondUsdc = bound(secondUsdc, 0, 2_000) * 1e6; // second leg: USDG queued for USDC
        secondUsdt = bound(secondUsdt, 0, 2_000) * 1e6;
        amount = bound(amount, 1, 4_000) * 1e6;

        if (firstUsdc > 0) _deposit(spokeA, address(usdc), firstUsdc);
        if (firstUsdt > 0) _deposit(spokeA, address(usdt), firstUsdt);
        if (secondUsdc > 0) _queueSeller(dave, address(usdc), secondUsdc * 1e12);
        if (secondUsdt > 0) _queueSeller(carol, address(usdt), secondUsdt * 1e12);

        uint256 carry =
            (firstUsdc < secondUsdc ? firstUsdc : secondUsdc) + (firstUsdt < secondUsdt ? firstUsdt : secondUsdt);
        address[] memory via = usdtFirst ? _two(address(usdt), address(usdc)) : _two(address(usdc), address(usdt));

        vm.startPrank(bob);
        pyusd.approve(address(store), amount);
        if (amount <= carry) {
            (, uint256 out) = store.swapSpokeToSpoke(address(pyusd), address(usdg), via, amount, bob, block.timestamp);
            assertEq(out, amount * 1e12);
            _assertConservation();
        } else {
            vm.expectRevert(_liq(address(usdg), carry, amount));
            store.swapSpokeToSpoke(address(pyusd), address(usdg), via, amount, bob, block.timestamp);
        }
        vm.stopPrank();
    }

    /// @dev Liquidity for the broader fuzz, in whole tokens. `buyers*` queue to buy PYUSD with a hub asset
    ///      (first leg, that hub asset only); `claim*` back spoke A's hub claim in a hub asset and `hubLp*`
    ///      add hub reserve in it (first leg, shared through spoke A's claim above `minClaim`); `sellers*`
    ///      queue to sell USDG for a hub asset (second leg, that hub asset only); `usdgReserve` is spoke
    ///      B's USDG reserve (second leg, shared).
    struct Liquidity {
        uint256 buyersUsdc;
        uint256 buyersUsdt;
        uint256 claimUsdc;
        uint256 claimUsdt;
        uint256 hubLpUsdc;
        uint256 hubLpUsdt;
        uint256 minClaim;
        uint256 sellersUsdc;
        uint256 sellersUsdt;
        uint256 usdgReserve;
    }

    function _boundLiquidity(Liquidity memory l) internal pure {
        l.buyersUsdc = bound(l.buyersUsdc, 0, 1_500);
        l.buyersUsdt = bound(l.buyersUsdt, 0, 1_500);
        l.claimUsdc = bound(l.claimUsdc, 0, 1_500);
        l.claimUsdt = bound(l.claimUsdt, 0, 1_500);
        l.hubLpUsdc = bound(l.hubLpUsdc, 0, 1_500);
        l.hubLpUsdt = bound(l.hubLpUsdt, 0, 1_500);
        l.minClaim = bound(l.minClaim, 0, l.claimUsdc + l.claimUsdt);
        l.sellersUsdc = bound(l.sellersUsdc, 0, 1_500);
        l.sellersUsdt = bound(l.sellersUsdt, 0, 1_500);
        l.usdgReserve = bound(l.usdgReserve, 0, 1_500);
    }

    function _fund(Liquidity memory l) internal {
        if (l.buyersUsdc > 0) _swap(carol, address(usdc), address(pyusd), l.buyersUsdc * 1e6);
        if (l.buyersUsdt > 0) _swap(dave, address(usdt), address(pyusd), l.buyersUsdt * 1e6);
        if (l.claimUsdc > 0) _deposit(spokeA, address(usdc), l.claimUsdc * 1e6);
        if (l.claimUsdt > 0) _deposit(spokeA, address(usdt), l.claimUsdt * 1e6);
        if (l.hubLpUsdc > 0) _deposit(0, address(usdc), l.hubLpUsdc * 1e6);
        if (l.hubLpUsdt > 0) _deposit(0, address(usdt), l.hubLpUsdt * 1e6);
        if (l.minClaim > 0) {
            vm.prank(governor);
            store.setMinDlrsReserve(spokeA, l.minClaim * 1e6);
        }
        if (l.sellersUsdc > 0) _queueSeller(carol, address(usdc), l.sellersUsdc * 1e18);
        if (l.sellersUsdt > 0) _queueSeller(dave, address(usdt), l.sellersUsdt * 1e18);
        if (l.usdgReserve > 0) _deposit(spokeB, address(usdg), l.usdgReserve * 1e18);
    }

    /// @dev The most the two hub assets can carry together, found by trying every split in whole tokens.
    ///      For a given amount through USDC, each leg uses its own queue before the shared liquidity, which
    ///      leaves the most shared liquidity for USDT.
    function _bestCarry(Liquidity memory l) internal pure returns (uint256 best) {
        uint256 claimFree = l.claimUsdc + l.claimUsdt - l.minClaim;
        uint256 hubUsdc = l.claimUsdc + l.hubLpUsdc;
        uint256 hubUsdt = l.claimUsdt + l.hubLpUsdt;
        uint256 firstMax = l.buyersUsdc + _min(hubUsdc, claimFree);
        uint256 secondMax = l.sellersUsdc + l.usdgReserve;
        uint256 top = _min(firstMax, secondMax);
        for (uint256 x; x <= top; ++x) {
            uint256 claimUsed = x > l.buyersUsdc ? x - l.buyersUsdc : 0;
            uint256 reserveUsed = x > l.sellersUsdc ? x - l.sellersUsdc : 0;
            uint256 viaUsdt =
                _min(l.buyersUsdt + _min(hubUsdt, claimFree - claimUsed), l.sellersUsdt + l.usdgReserve - reserveUsed);
            if (x + viaUsdt > best) best = x + viaUsdt;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice Outcome against a brute-force optimum: with every source of liquidity random (queued buyers
    ///         and sellers per hub asset, hub reserves, spoke A's claim and floor, spoke B's reserve), the
    ///         call fills whenever some split across the hub assets could carry the amount, in either order,
    ///         and otherwise fills the most any split could before it reverts.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_s2s_carriesTheBestSplit(Liquidity memory l, uint256 amount, bool usdtFirst) public {
        _boundLiquidity(l);
        amount = bound(amount, 1, 6_000);
        _fund(l);

        uint256 best = _bestCarry(l);
        address[] memory via = usdtFirst ? _two(address(usdt), address(usdc)) : _two(address(usdc), address(usdt));

        vm.startPrank(bob);
        pyusd.approve(address(store), amount * 1e6);
        if (amount <= best) {
            (, uint256 out) =
                store.swapSpokeToSpoke(address(pyusd), address(usdg), via, amount * 1e6, bob, block.timestamp);
            assertEq(out, amount * 1e18);
            _assertConservation();
        } else {
            vm.expectRevert(_liq(address(usdg), best * 1e6, amount * 1e6));
            store.swapSpokeToSpoke(address(pyusd), address(usdg), via, amount * 1e6, bob, block.timestamp);
        }
        vm.stopPrank();
    }

    // ============ parking on either leg ============

    function test_s2s_firstLeg_parksQueuedBuyerWhoCannotReceive() public {
        _swap(carol, address(usdc), address(pyusd), 500e6); // queues: spoke A has no asset
        uint256 carolId = store.getUserQueuePositions(carol)[0];
        _seedDefault();
        pyusd.setBlocked(carol, true);

        assertEq(_s2s(bob, address(pyusd), address(usdg), address(usdc), 500e6), 500e18, "bob filled from reserves");
        assertTrue(store.isQueuePositionParked(carolId), "carol parked");
        assertEq(store.getQueueDepth(address(usdc), address(usdg)), 0, "no stray position");
        assertEq(store.getQueueDepth(address(usdc), address(pyusd)), 0, "carol off the line");
        assertEq(store.getQueueDepth(address(usdc), address(0)), 500e6, "carol's escrow on the parked line");
        _assertConservation();
    }

    function test_s2s_secondLeg_parksQueuedSellerWhoCannotReceive() public {
        _deposit(spokeB, address(usdg), 1_000e18);
        _swap(dave, address(usdg), address(usdt), 500e18); // queues: spoke B has no claim
        uint256 daveId = store.getUserQueuePositions(dave)[0];
        _deposit(spokeA, address(usdt), 1_000e6);
        usdt.setBlocked(dave, true);

        assertEq(_s2s(bob, address(pyusd), address(usdg), address(usdt), 500e6), 500e18, "bob filled from reserves");
        assertTrue(store.isQueuePositionParked(daveId), "dave parked");
        assertEq(store.getQueueDepth(address(usdg), address(0)), 500e6, "dave's escrow on the parked line");
        assertEq(store.getReserve(spokeB, address(usdg)), 500e6, "spoke B paid bob from reserve");
        _assertConservation();
    }

    function test_s2s_firstLeg_parksEarlierSellerWhoCannotReceive() public {
        _deposit(spokeA, address(usdt), 1_000e6);
        _deposit(spokeB, address(usdg), 1_000e18);
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 1_000e6);
        _swap(dave, address(pyusd), address(usdt), 300e6); // queues at the floor, ahead of bob
        uint256 daveId = store.getUserQueuePositions(dave)[0];
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 0);
        usdt.setBlocked(dave, true);

        assertEq(_s2s(bob, address(pyusd), address(usdg), address(usdt), 500e6), 500e18, "bob filled after dave");
        assertTrue(store.isQueuePositionParked(daveId), "dave parked, not paid");
        assertEq(store.getQueueDepth(address(pyusd), address(usdt)), 0, "dave off the line");
        assertEq(store.getQueueDepth(address(pyusd), address(0)), 300e6, "dave's escrow on the parked line");
        _assertConservation();
    }

    /// @notice Documented limit: the sizing assumes every payout succeeds, so dave's 100, frozen and not yet
    ///         parked, counts against USDT's 1,000 until he is parked. 900 fills and parks him; 1,000 gets 900
    ///         through USDT and reverts; after processQueue parks him, 1,000 fills.
    function test_s2s_frozenOwnerAhead_countsUntilParked() public {
        _deposit(spokeA, address(usdt), 1_000e6);
        _deposit(spokeB, address(usdg), 1_000e18);
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 1_000e6);
        _swap(dave, address(pyusd), address(usdt), 100e6); // queues at the floor
        uint256 daveId = store.getUserQueuePositions(dave)[0];
        usdt.setBlocked(dave, true);
        (uint256 visited,) = store.processQueue(address(pyusd), address(usdt), 8);
        assertEq(visited, 0, "nothing to pay dave from at the floor");
        assertFalse(store.isQueuePositionParked(daveId), "so dave is not parked");
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 0);

        uint256 snap = vm.snapshotState();
        assertEq(_s2s(bob, address(pyusd), address(usdg), address(usdt), 900e6), 900e18, "900 fills");
        assertTrue(store.isQueuePositionParked(daveId), "dave parked on the way");
        vm.revertToState(snap);

        assertEq(
            _s2sMany(address(pyusd), address(usdg), _two(address(usdt), address(usdt)), 1_000e6),
            1_000e18,
            "USDT listed again carries the last 100"
        );
        assertTrue(store.isQueuePositionParked(daveId), "dave parked by the first entry");
        vm.revertToState(snap);

        _expectS2sRevert(_liq(address(usdg), 900e6, 1_000e6), address(pyusd), address(usdg), address(usdt), 1_000e6);
        store.processQueue(address(pyusd), address(usdt), 8);
        assertTrue(store.isQueuePositionParked(daveId), "processQueue parks dave");
        assertEq(store.getDlrsReserve(spokeA), 1_000e6, "nothing paid to dave");
        assertEq(_s2s(bob, address(pyusd), address(usdg), address(usdt), 1_000e6), 1_000e18, "1,000 fills");
        _assertConservation();
    }

    function test_s2s_frozenOwnerTakesAllCapacity_repeatingHubAssetDoesNotHelp() public {
        _deposit(spokeA, address(usdt), 100e6);
        _deposit(spokeB, address(usdg), 1_000e18);
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 100e6);
        _swap(dave, address(pyusd), address(usdt), 100e6); // queues at the floor
        uint256 daveId = store.getUserQueuePositions(dave)[0];
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 0);
        usdt.setBlocked(dave, true);

        // Dave's 100 ahead takes the whole 100 claim, so USDT is sized at 0 both times and no payout is tried.
        _expectS2sManyRevert(_liq(address(usdg), 0, 100e6), _two(address(usdt), address(usdt)), 100e6);
        assertFalse(store.isQueuePositionParked(daveId), "dave not parked");
        store.processQueue(address(pyusd), address(usdt), 8);
        assertTrue(store.isQueuePositionParked(daveId), "processQueue parks dave");
        assertEq(_s2s(bob, address(pyusd), address(usdg), address(usdt), 100e6), 100e18, "100 fills");
        _assertConservation();
    }

    function test_s2s_frozenOwnerAheadOnSecondLeg_countsUntilParked() public {
        _deposit(spokeA, address(usdt), 1_000e6);
        _swap(carol, address(usdt), address(usdg), 100e6); // queues: spoke B has no USDG yet
        uint256 carolId = store.getUserQueuePositions(carol)[0];
        vm.prank(pauser);
        store.pauseDeposits(address(usdt)); // keep the spoke B deposit from settling carol's line
        _deposit(spokeB, address(usdg), 1_000e18);
        vm.prank(unpauser);
        store.unpauseDeposits(address(usdt));
        usdg.setBlocked(carol, true);

        // Spoke B holds 1,000 USDG, but carol's 100 ahead counts as paid, so USDT is sized at 900.
        _expectS2sRevert(_liq(address(usdg), 900e6, 1_000e6), address(pyusd), address(usdg), address(usdt), 1_000e6);
        store.processQueue(address(usdt), address(usdg), 8);
        assertTrue(store.isQueuePositionParked(carolId), "processQueue parks carol");
        assertEq(store.getReserve(spokeB, address(usdg)), 1_000e6, "nothing paid to carol");
        assertEq(_s2s(bob, address(pyusd), address(usdg), address(usdt), 1_000e6), 1_000e18, "1,000 fills");
        _assertConservation();
    }

    function test_s2s_chainedQuoteOverpromises_frozenOppositeOwner() public {
        _swap(carol, address(usdt), address(pyusd), 100e6); // queues: spoke A has no PYUSD
        _swap(dave, address(usdg), address(usdt), 100e18); // queues: spoke B has no hub claim
        uint256 carolId = store.getUserQueuePositions(carol)[0];
        pyusd.setBlocked(carol, true);

        // The quote counts on carol taking bob's PYUSD for her USDT, and dave taking that USDT for his USDG.
        uint256 viaOut = store.getSwapQuote(address(pyusd), address(usdt), 100e6);
        assertEq(store.getSwapQuote(address(usdt), address(usdg), viaOut), 100e18, "quote promises 100");
        // Paying carol fails, so she is parked and her USDT stays in escrow. Spoke A has no hub claim to use
        // instead, so the first leg fills nothing and the call reverts, undoing her parking.
        _expectS2sRevert(_liq(address(usdg), 0, 100e6), address(pyusd), address(usdg), address(usdt), 100e6);
        (uint256 visited,) = store.processQueue(address(usdt), address(pyusd), 8);
        assertEq(visited, 0, "no PYUSD in spoke A to try paying carol from");
        assertFalse(store.isQueuePositionParked(carolId), "so processQueue cannot park her");
    }

    function test_s2s_secondLeg_parksEarlierBuyerWhoCannotReceive() public {
        _deposit(spokeA, address(usdt), 1_000e6);
        _swap(carol, address(usdt), address(usdg), 300e6); // queues: spoke B has no asset
        uint256 carolId = store.getUserQueuePositions(carol)[0];
        usdg.setBlocked(carol, true);
        vm.prank(pauser);
        store.pauseDeposits(address(usdt)); // keep the spoke B deposit from settling carol's line
        _deposit(spokeB, address(usdg), 1_000e18);
        vm.prank(unpauser);
        store.unpauseDeposits(address(usdt));

        assertEq(_s2s(bob, address(pyusd), address(usdg), address(usdt), 500e6), 500e18, "bob filled after carol");
        assertTrue(store.isQueuePositionParked(carolId), "carol parked, not paid");
        assertEq(store.getQueueDepth(address(usdt), address(usdg)), 0, "carol off the line");
        assertEq(store.getQueueDepth(address(usdt), address(0)), 300e6, "carol's escrow on the parked line");
        _assertConservation();
    }

    // ============ 18-decimal hub asset as via ============

    function test_s2s_18dpHubAsset_asVia() public {
        MockERC20 hub18 = new MockERC20("Hub 18", "H18", 18);
        vm.prank(governor);
        store.addHubAsset(address(hub18), address(feed));
        hub18.mint(alice, 1_000e18);
        _deposit(spokeA, address(hub18), 1_000e18);
        _deposit(spokeB, address(usdg), 1_000e18);

        assertEq(_s2s(bob, address(pyusd), address(usdg), address(hub18), 400e6), 400e18, "bob gets 400");
        assertEq(store.getReserve(0, address(hub18)), 1_000e6, "hub reserve unchanged, in 6-decimal units");
        assertEq(hub18.balanceOf(address(store)), 1_000e18, "no native hub asset left over");
        assertEq(store.getDlrsReserve(spokeA), 600e6, "spoke A claim down 400");
        assertEq(store.getDlrsReserve(spokeB), 400e6, "spoke B claim up 400");
    }

    // ============ reentrancy ============

    function test_s2s_reentrantWantedToken_reverts() public {
        MockReentrantERC20 evil = new MockReentrantERC20("Reentrant", "RNT", 6);
        vm.prank(governor);
        uint16 spokeC = store.createSpoke(address(evil), address(feed), 0, 0);
        evil.mint(alice, 1_000e6);
        _deposit(spokeA, address(usdc), 1_000e6);
        _deposit(spokeC, address(evil), 1_000e6);

        assertEq(_s2s(bob, address(pyusd), address(evil), address(usdc), 100e6), 100e6, "fills when the token behaves");

        evil.arm(address(store)); // the payout to bob calls back into the store
        _expectS2sRevert(
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
            address(pyusd),
            address(evil),
            address(usdc),
            100e6
        );
        assertEq(store.getReserve(spokeC, address(evil)), 900e6, "nothing moved");
    }

    // ============ unrelated escrow ============

    function test_s2s_hubReserveShort_neverUsesOtherEscrowOfVia() public {
        _swap(carol, address(usdc), address(usdt), 1_000e6); // hub-to-hub, queues: no USDT in the hub
        _deposit(spokeA, address(usdc), 300e6);
        _deposit(spokeB, address(usdg), 1_000e18);

        _expectS2sManyRevert(_liq(address(usdg), uint256(300e6), uint256(500e6)), _one(address(usdc)), 500e6);
    }

    function test_s2s_leavesOtherEscrowOfOfferedAsset() public {
        _swap(dave, address(pyusd), address(usdt), 1_000e6); // queues: spoke A has no claim
        _seedDefault();

        _s2s(bob, address(pyusd), address(usdg), address(usdc), 500e6);

        assertEq(store.getQueueDepth(address(pyusd), address(usdt)), 1_000e6, "dave's position untouched");
        assertEq(store.getReserve(spokeA, address(pyusd)), 500e6, "spoke A reserve up by bob's amount");
        assertEq(pyusd.balanceOf(address(store)), 1_500e6, "balance == reserve + escrow");
    }

    // ============ same-direction settle cap ============

    function test_s2s_firstLeg_moreSellersThanOneCallSettles_reverts() public {
        _deposit(spokeA, address(usdc), 10_000e6);
        _deposit(spokeB, address(usdg), 1_000e18);
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 10_000e6);
        for (uint256 i; i < 9; i++) {
            _swap(dave, address(pyusd), address(usdc), 500e6);
        }
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 0);

        _expectS2sRevert(
            _liq(address(usdg), uint256(0), uint256(500e6)), address(pyusd), address(usdg), address(usdc), 500e6
        );

        store.processQueue(address(pyusd), address(usdc), 9);
        assertEq(_s2s(bob, address(pyusd), address(usdg), address(usdc), 500e6), 500e18, "fills once the line clears");
    }

    function test_s2s_secondLeg_moreBuyersThanOneCallSettles_reverts() public {
        _deposit(spokeA, address(usdt), 1_000e6);
        for (uint256 i; i < 9; i++) {
            _swap(carol, address(usdt), address(usdg), 500e6); // queues: spoke B has no asset
        }
        vm.prank(pauser);
        store.pauseDeposits(address(usdt)); // keep the spoke B deposit from settling carol's line
        _deposit(spokeB, address(usdg), 10_000e18);
        vm.prank(unpauser);
        store.unpauseDeposits(address(usdt));

        _expectS2sManyRevert(_liq(address(usdg), uint256(0), uint256(500e6)), _one(address(usdt)), 500e6);

        store.processQueue(address(usdt), address(usdg), 9);
        assertEq(_s2s(bob, address(pyusd), address(usdg), address(usdt), 500e6), 500e18, "fills once the line clears");
    }

    // ============ queue order ============

    function test_s2s_settlesOlderSellerFirst() public {
        _seedDefault();
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 1_000e6);
        assertEq(_swap(dave, address(pyusd), address(usdc), 300e6), 0, "dave queues at the floor");
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 500e6); // 500 above the floor

        _s2s(bob, address(pyusd), address(usdg), address(usdc), 200e6);

        assertEq(usdc.balanceOf(dave), 1_000_000e6 + 300e6, "dave settled first");
        assertEq(usdg.balanceOf(bob), 1_000_000e18 + 200e18, "bob filled after");
        assertEq(store.getDlrsReserve(spokeA), 500e6, "spoke A at its floor");
        _assertConservation();
    }

    function test_s2s_cannotJumpOlderSeller() public {
        _seedDefault();
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 1_000e6);
        _swap(dave, address(pyusd), address(usdc), 300e6);
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 700e6); // room for dave only

        _expectS2sRevert(
            _liq(address(usdg), uint256(0), uint256(200e6)), address(pyusd), address(usdg), address(usdc), 200e6
        );
        assertEq(store.getQueueDepth(address(pyusd), address(usdc)), 300e6, "dave still first in line");
    }

    // ============ quoting through one hub asset ============

    /// @dev The documented recipe: chain getSwapQuote over the two legs. Returns native wanted units.
    function _chainedQuote(address offer, address want, address via, uint256 amt) internal view returns (uint256) {
        return store.getSwapQuote(via, want, store.getSwapQuote(offer, via, amt));
    }

    function test_s2s_chainedQuote_matchesFill() public {
        _seedDefault();

        uint256 quoted = _chainedQuote(address(pyusd), address(usdg), address(usdc), 400e6);

        assertEq(quoted, 400e18, "6-decimal PYUSD in, 18-decimal USDG out: 400 in normalized units");
        assertEq(_s2s(bob, address(pyusd), address(usdg), address(usdc), 400e6), quoted, "swap delivers the quote");
    }

    function test_s2s_chainedQuote_matchesFill_withSellerWaitingAhead() public {
        _seedDefault();
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 1_000e6);
        _swap(dave, address(pyusd), address(usdc), 300e6); // waits in PYUSD -> USDC, the first leg's line
        vm.prank(governor);
        store.setMinDlrsReserve(spokeA, 500e6); // room for dave's 300, then 200 more

        uint256 quoted = _chainedQuote(address(pyusd), address(usdg), address(usdc), 200e6);

        assertEq(quoted, 200e18, "dave is paid first, then the full 200");
        assertEq(_s2s(bob, address(pyusd), address(usdg), address(usdc), 200e6), quoted, "swap delivers the quote");
    }

    function test_s2s_chainedQuote_short_swapReverts() public {
        _deposit(spokeA, address(usdc), 1_000e6);
        _deposit(spokeB, address(usdg), 300e18);

        uint256 quoted = _chainedQuote(address(pyusd), address(usdg), address(usdc), 500e6);

        assertEq(quoted, 300e18, "only 300 of the 500 can fill");
        _expectS2sRevert(
            _liq(address(usdg), uint256(300e6), uint256(500e6)), address(pyusd), address(usdg), address(usdc), 500e6
        );
    }

    // ============ lifecycle and pauses ============

    function test_s2s_offerSpokeWindingDown_reverts() public {
        _seedDefault();
        vm.prank(governor);
        store.windDownSpoke(spokeA);

        _expectS2sRevert(
            abi.encodeWithSelector(IDollarStore.SpokeWindingDown.selector, spokeA),
            address(pyusd),
            address(usdg),
            address(usdc),
            100e6
        );
    }

    function test_s2s_wantSpokeWindingDown_fills() public {
        _seedDefault();
        vm.prank(governor);
        store.windDownSpoke(spokeB);

        assertEq(_s2s(bob, address(pyusd), address(usdg), address(usdc), 100e6), 100e18, "drains spoke B");
    }

    function test_s2s_globalPause_reverts() public {
        _seedDefault();
        vm.prank(pauser);
        store.pause();

        _expectS2sRevert(
            abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector),
            address(pyusd),
            address(usdg),
            address(usdc),
            100e6
        );
    }

    function test_s2s_wantPoolPaused_reverts() public {
        _seedDefault();
        vm.prank(pauser);
        store.pausePool(spokeB);

        _expectS2sRevert(
            abi.encodeWithSelector(IDollarStore.PoolPaused.selector, spokeB),
            address(pyusd),
            address(usdg),
            address(usdc),
            100e6
        );
    }

    function test_s2s_offerPoolPaused_reverts() public {
        _seedDefault();
        vm.prank(pauser);
        store.pausePool(spokeA);

        _expectS2sRevert(
            abi.encodeWithSelector(IDollarStore.PoolPaused.selector, spokeA),
            address(pyusd),
            address(usdg),
            address(usdc),
            100e6
        );
    }

    function test_s2s_viaPriceStale_skipped() public {
        _seedDefault();
        vm.warp(block.timestamp + 2 days);
        feed.setUpdatedAt(block.timestamp); // offered asset fresh, USDC's feed left behind

        _expectS2sRevert(
            _liq(address(usdg), uint256(0), uint256(100e6)), address(pyusd), address(usdg), address(usdc), 100e6
        );
    }

    function test_s2s_offerPriceStale_reverts() public {
        _seedDefault();
        vm.warp(block.timestamp + 2 days);
        usdcFeed.setUpdatedAt(block.timestamp); // USDC fresh, the offered asset's feed left behind

        vm.startPrank(bob);
        pyusd.approve(address(store), 100e6);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.PriceStale.selector, address(pyusd), feed.updatedAt()));
        store.swapSpokeToSpoke(address(pyusd), address(usdg), _one(address(usdc)), 100e6, bob, block.timestamp);
        vm.stopPrank();
    }

    function test_s2s_callerFrozenOnOfferedAsset_reverts() public {
        _seedDefault();
        pyusd.setBlockedSender(bob, true);

        _expectS2sRevert(bytes("blocked sender"), address(pyusd), address(usdg), address(usdc), 100e6);
        assertEq(store.getDlrsReserve(spokeA), 1_000e6, "nothing moved");
    }

    function test_s2s_offerDepositsPaused_reverts() public {
        _seedDefault();
        vm.prank(pauser);
        store.pauseDeposits(address(pyusd));

        _expectS2sRevert(
            abi.encodeWithSelector(IDollarStore.DepositsPaused.selector, address(pyusd)),
            address(pyusd),
            address(usdg),
            address(usdc),
            100e6
        );
    }

    function test_s2s_viaDepositsPaused_skipped() public {
        _seedDefault();
        vm.prank(pauser);
        store.pauseDeposits(address(usdc));

        _expectS2sRevert(
            _liq(address(usdg), uint256(0), uint256(100e6)), address(pyusd), address(usdg), address(usdc), 100e6
        );
    }

    function test_s2s_hubPoolPaused_skipsEveryVia() public {
        _seedDefault();
        vm.prank(pauser);
        store.pausePool(0);

        // Every hub asset is skipped, so the pause reads as a shortfall of the whole amount, not
        // PoolPaused(0) (PROTOCOL.md, Swaps).
        _expectS2sRevert(
            _liq(address(usdg), uint256(0), uint256(100e6)), address(pyusd), address(usdg), address(usdc), 100e6
        );
    }

    function test_s2s_viaOffPeg_skipped() public {
        _seedDefault();
        usdcFeed.setAnswer(0.9e8);

        _expectS2sRevert(
            _liq(address(usdg), uint256(0), uint256(100e6)), address(pyusd), address(usdg), address(usdc), 100e6
        );
    }

    /// @notice The second leg pays out less than its first leg took: a frozen seller waiting on the
    ///         second leg is parked and the wanted spoke has no reserve left to replace it. The first
    ///         entry already carried 50, so the error reports 50 of 150 in native USDG, and the
    ///         rollback leaves the seller unparked.
    function test_s2s_secondLegPaysLess_reportsProgressInNativeWant() public {
        _swap(dave, address(usdg), address(usdt), 100e18); // spoke B has no claim: queued
        uint256 daveId = store.getUserQueuePositions(dave)[0];
        _deposit(spokeA, address(usdc), 50e6); // A's claim: 50 backed by USDC
        _deposit(spokeA, address(usdt), 100e6); // and 100 backed by USDT
        _deposit(spokeB, address(usdg), 50e18); // B's reserve: 50
        usdt.setBlocked(dave, true);

        _expectS2sManyRevert(_liq(address(usdg), 50e6, 150e6), _two(address(usdc), address(usdt)), 150e6);

        assertFalse(store.isQueuePositionParked(daveId), "parking rolled back");
        (,,, uint256 daveUnits,,) = store.getQueuePosition(daveId);
        assertEq(daveUnits, 100e6, "seller untouched");
        assertEq(store.getReserve(spokeB, address(usdg)), 50e6, "B's reserve untouched");
        assertEq(store.getDlrsReserve(spokeA), 150e6, "A's claim untouched");
    }

    /// @notice A recipient the wanted spoke asset refuses reverts the whole call, including a seller
    ///         already paid on the second leg; a caller refused by it can still send to an allowed
    ///         recipient.
    function test_s2s_recipientRefusedByWantAsset_revertsAll() public {
        _swap(dave, address(usdg), address(usdc), 100e18); // spoke B has no claim: queued
        uint256 daveId = store.getUserQueuePositions(dave)[0];
        _seedDefault();
        usdg.setBlocked(carol, true);
        uint256 daveUsdc = usdc.balanceOf(dave);

        vm.startPrank(bob);
        pyusd.approve(address(store), 100e6);
        vm.expectRevert(bytes("blocked"));
        store.swapSpokeToSpoke(address(pyusd), address(usdg), _one(address(usdc)), 100e6, carol, block.timestamp);
        vm.stopPrank();

        (,,, uint256 daveUnits,,) = store.getQueuePosition(daveId);
        assertEq(daveUnits, 100e6, "seller's fill rolled back");
        assertEq(usdc.balanceOf(dave), daveUsdc, "seller's payout rolled back");
        assertEq(store.getDlrsReserve(spokeA), 1_000e6, "A's claim untouched");

        usdg.setBlocked(carol, false);
        usdg.setBlocked(bob, true);
        vm.startPrank(bob);
        (uint256 amountIn, uint256 out) =
            store.swapSpokeToSpoke(address(pyusd), address(usdg), _one(address(usdc)), 100e6, carol, block.timestamp);
        vm.stopPrank();
        assertEq(amountIn, 100e6, "bob paid");
        assertEq(out, 100e18, "carol received");
        assertEq(usdg.balanceOf(carol), 1_000_000e18 + 100e18, "to the recipient, not the refused caller");
    }

    function test_s2s_callerFrozenOnWantAsset_reverts() public {
        _seedDefault();
        usdg.setBlocked(bob, true);

        _expectS2sRevert(bytes("blocked"), address(pyusd), address(usdg), address(usdc), 100e6);
        assertEq(store.getDlrsReserve(spokeA), 1_000e6, "nothing moved");
    }

    function test_s2s_removedSpoke_reverts() public {
        _seedDefault();
        MockERC20 gone = new MockERC20("Removed", "RMV", 6);
        vm.startPrank(governor);
        uint16 spokeC = store.createSpoke(address(gone), address(feed), 0, 0);
        store.removePool(spokeC);
        vm.stopPrank();

        _expectS2sRevert(
            abi.encodeWithSelector(IDollarStore.AssetNotListed.selector, address(gone)),
            address(gone),
            address(usdg),
            address(usdc),
            1e6
        );
        _expectS2sRevert(
            abi.encodeWithSelector(IDollarStore.AssetNotListed.selector, address(gone)),
            address(pyusd),
            address(gone),
            address(usdc),
            1e6
        );
    }

    // ============ input checks ============

    function test_s2s_sameAsset_reverts() public {
        _expectS2sRevert(
            abi.encodeWithSelector(IDollarStore.SameAsset.selector), address(pyusd), address(pyusd), address(usdc), 1e6
        );
    }

    function test_s2s_viaNotHubAsset_reverts() public {
        _expectS2sRevert(
            abi.encodeWithSelector(IDollarStore.InvalidRoute.selector, address(pyusd), address(usdg)),
            address(pyusd),
            address(usdg),
            address(usdg),
            1e6
        );
    }

    function test_s2s_viaIsOfferedAsset_reverts() public {
        _expectS2sManyRevert(abi.encodeWithSelector(IDollarStore.SameAsset.selector), _one(address(pyusd)), 1e6);
    }

    function test_s2s_offerHubAsset_reverts() public {
        _expectS2sRevert(
            abi.encodeWithSelector(IDollarStore.InvalidRoute.selector, address(usdt), address(usdg)),
            address(usdt),
            address(usdg),
            address(usdc),
            1e6
        );
    }

    function test_s2s_wantHubAsset_reverts() public {
        _expectS2sRevert(
            abi.encodeWithSelector(IDollarStore.InvalidRoute.selector, address(pyusd), address(usdt)),
            address(pyusd),
            address(usdt),
            address(usdc),
            1e6
        );
    }

    function test_s2s_deadlineExpired_reverts() public {
        _seedDefault();
        vm.startPrank(bob);
        pyusd.approve(address(store), 100e6);
        vm.expectRevert(
            abi.encodeWithSelector(IDollarStore.DeadlineExpired.selector, block.timestamp - 1, block.timestamp)
        );
        store.swapSpokeToSpoke(address(pyusd), address(usdg), _one(address(usdc)), 100e6, bob, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_s2s_zeroUnits_reverts() public {
        _seedDefault();
        _expectS2sRevert(
            abi.encodeWithSelector(IDollarStore.ZeroAmount.selector), address(usdg), address(pyusd), address(usdc), 1e11
        );
    }
}
