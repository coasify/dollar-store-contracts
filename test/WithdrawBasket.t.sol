// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {Pausers} from "./utils/Pausers.sol";

/// @notice withdraw returns every asset the exit can pay with its native amount (spoke asset first,
///         then hub assets in listing order, 0 where nothing is paid), takes optional native minimums
///         in the same order, emits one Withdraw per asset paid tagged with the pool exited, and
///         previewWithdraw returns exactly what the exit then pays, for any caller.
contract WithdrawBasketTest is Test {
    DollarStore internal store;

    address internal governor = makeAddr("governor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger"); // holds nothing

    MockERC20 internal usdc; // 6 decimals, hub
    MockERC20 internal usds; // 18 decimals, hub
    MockERC20 internal usdt; // 6 decimals, hub
    MockERC20 internal pyusd; // 6 decimals, spoke
    MockAggregatorV3 internal feed;
    uint16 internal spoke;

    function setUp() public {
        DollarStore impl = new DollarStore();
        bytes memory initData = abi.encodeCall(
            DollarStore.initialize,
            (
                makeAddr("upgrader"),
                governor,
                makeAddr("guardian"),
                makeAddr("unpauser"),
                Pausers.one(makeAddr("pauser"))
            )
        );
        store = DollarStore(address(new ERC1967Proxy(address(impl), initData)));

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usds = new MockERC20("USDS", "USDS", 18);
        usdt = new MockERC20("Tether", "USDT", 6);
        pyusd = new MockERC20("PayPal USD", "PYUSD", 6);
        feed = new MockAggregatorV3(8, 1e8);

        vm.startPrank(governor);
        store.addHubAsset(address(usdc), address(feed));
        store.addHubAsset(address(usds), address(feed));
        store.addHubAsset(address(usdt), address(feed));
        spoke = store.createSpoke(address(pyusd), address(feed), 0, 0);
        vm.stopPrank();

        MockERC20[4] memory tokens = [usdc, usds, usdt, pyusd];
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i].mint(alice, 1_000_000 * 10 ** tokens[i].decimals());
            tokens[i].mint(bob, 1_000_000 * 10 ** tokens[i].decimals());
            vm.prank(alice);
            tokens[i].approve(address(store), type(uint256).max);
            vm.prank(bob);
            tokens[i].approve(address(store), type(uint256).max);
        }
    }

    function _deposit(address who, uint16 poolId, MockERC20 token, uint256 amount) internal {
        vm.prank(who);
        store.deposit(poolId, address(token), amount, who, block.timestamp);
    }

    function _none() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    function _three(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory m) {
        m = new uint256[](3);
        (m[0], m[1], m[2]) = (a, b, c);
    }

    // ============ the basket ============

    /// @notice Hub holds 600 USDC and 400 USDS. Burning 100 DLRS pays 60 USDC and 40 USDS, plus a 0 slot
    ///         for USDT, in listing order, in each token's own decimals.
    function test_hubExit_returnsNativeBasketInListingOrder() public {
        _deposit(alice, 0, usdc, 600e6);
        _deposit(alice, 0, usds, 400e18);

        vm.prank(alice);
        (address[] memory assets, uint256[] memory amounts) = store.withdraw(0, 100e6, _none(), block.timestamp);

        assertEq(assets.length, 3, "every hub asset");
        assertEq(assets[0], address(usdc));
        assertEq(assets[1], address(usds));
        assertEq(assets[2], address(usdt));
        assertEq(amounts[0], 60e6, "60 USDC");
        assertEq(amounts[1], 40e18, "40 USDS");
        assertEq(amounts[2], 0, "nothing held, 0 slot");
        assertEq(usds.balanceOf(alice), 1_000_000e18 - 400e18 + 40e18, "USDS arrived");
    }

    /// @notice A spoke holding 500 PYUSD and a claim on 500 hub dollars (hub: 600 USDC, 400 USDS). The
    ///         only LP burns a tenth of its 1,000 shares: 100 dollars, half from each side, the hub half
    ///         split 60/40.
    function test_spokeExit_spokeAssetFirst_thenHub() public {
        _deposit(bob, 0, usdc, 100e6); // hub 600 USDC / 400 USDS once the spoke's 500 arrives
        _deposit(bob, 0, usds, 400e18);
        _deposit(alice, spoke, pyusd, 500e6);
        _deposit(alice, spoke, usdc, 500e6);
        uint256 shares = store.getReceiptShares(spoke, alice) / 10;

        vm.prank(alice);
        (address[] memory assets, uint256[] memory amounts) = store.withdraw(spoke, shares, _none(), block.timestamp);

        assertEq(assets.length, 4, "spoke asset plus every hub asset");
        assertEq(assets[0], address(pyusd), "spoke asset first");
        assertEq(assets[1], address(usdc));
        assertEq(assets[2], address(usds));
        assertEq(assets[3], address(usdt));
        assertEq(amounts[0], 50e6, "50 PYUSD");
        assertEq(amounts[1], 30e6, "30 USDC");
        assertEq(amounts[2], 20e18, "20 USDS");
        assertEq(amounts[3], 0, "0 USDT");
    }

    /// @notice Hub reserves [5, 5, 0] units of [USDC, USDS, USDT]; burning 3 DLRS units floors to
    ///         [1, 1, 0] and hands the remaining unit to the first listed asset with spare reserve:
    ///         [2, 1, 0] units, natively [2, 1e12, 0]. A minimum of 1 on the empty third slot fails there.
    function test_hubExit_remainderGoesToFirstListed_andMinimumOnZeroSlotFails() public {
        _deposit(alice, 0, usdc, 5);
        _deposit(alice, 0, usds, 5e12);

        (address[] memory assets, uint256[] memory quoted) = store.previewWithdraw(0, 3);
        assertEq(quoted[0], 2, "USDC gets the remainder");
        assertEq(quoted[1], 1e12, "USDS");
        assertEq(quoted[2], 0, "USDT");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.WithdrawMinNotMet.selector, address(usdt), 0, 1));
        store.withdraw(0, 3, _three(2, 1e12, 1), block.timestamp);

        vm.prank(alice);
        (, uint256[] memory paid) = store.withdraw(0, 3, _three(2, 1e12, 0), block.timestamp);
        assertEq(paid[0], quoted[0]);
        assertEq(paid[1], quoted[1]);
        assertEq(paid[2], quoted[2]);
        assertEq(assets[2], address(usdt));
    }

    /// @notice A spoke can take deposits before any hub asset is listed. Its exit pays the spoke asset
    ///         alone, with no hub slots, and is never blocked by the empty hub list.
    function test_spokeExit_beforeAnyHubAssetIsListed() public {
        DollarStore impl = new DollarStore();
        bytes memory initData = abi.encodeCall(
            DollarStore.initialize,
            (
                makeAddr("upgrader"),
                governor,
                makeAddr("guardian"),
                makeAddr("unpauser"),
                Pausers.one(makeAddr("pauser"))
            )
        );
        DollarStore bare = DollarStore(address(new ERC1967Proxy(address(impl), initData)));
        vm.prank(governor);
        uint16 pool = bare.createSpoke(address(pyusd), address(feed), 0, 0);
        vm.startPrank(alice);
        pyusd.approve(address(bare), 100e6);
        bare.deposit(pool, address(pyusd), 100e6, alice, block.timestamp);

        (address[] memory quotedAssets, uint256[] memory quoted) = bare.previewWithdraw(pool, 50e6);
        (address[] memory assets, uint256[] memory amounts) =
            bare.withdraw(pool, 50e6, new uint256[](0), block.timestamp);
        vm.stopPrank();

        assertEq(assets.length, 1, "the spoke asset only");
        assertEq(assets[0], address(pyusd));
        assertEq(amounts[0], 50e6, "half the spoke");
        assertEq(quotedAssets.length, 1, "preview: the spoke asset only");
        assertEq(quoted[0], 50e6, "preview equals the exit");
    }

    // ============ events ============

    /// @notice A spoke exit emits a Withdraw for the spoke asset too, and every Withdraw names the spoke.
    function test_spokeExit_withdrawEvents_includeSpokeAsset_taggedWithPool() public {
        _deposit(alice, spoke, pyusd, 500e6);
        _deposit(alice, spoke, usdc, 500e6);

        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.Withdraw(alice, spoke, address(pyusd), 50e6, 50e6);
        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.Withdraw(alice, spoke, address(usdc), 50e6, 50e6);
        vm.expectEmit(true, true, false, true, address(store));
        emit IDollarStore.SpokeWithdrawn(spoke, alice, 100e6, 50e6, 50e6);
        vm.prank(alice);
        store.withdraw(spoke, 100e6, _none(), block.timestamp);
    }

    // ============ minimums ============

    /// @notice Exact minimums pass; one wei above on any slot reverts naming that asset; a list of the
    ///         wrong length reverts; an empty list accepts the payout.
    function test_minimums_perSlot() public {
        _deposit(alice, 0, usdc, 600e6);
        _deposit(alice, 0, usds, 400e18);

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.WithdrawMinNotMet.selector, address(usdc), 60e6, 60e6 + 1));
        store.withdraw(0, 100e6, _three(60e6 + 1, 40e18, 0), block.timestamp);
        vm.expectRevert(
            abi.encodeWithSelector(IDollarStore.WithdrawMinNotMet.selector, address(usds), 40e18, 40e18 + 1)
        );
        store.withdraw(0, 100e6, _three(60e6, 40e18 + 1, 0), block.timestamp);

        uint256[] memory two = new uint256[](2);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.MinAmountsLength.selector, 2, 3));
        store.withdraw(0, 100e6, two, block.timestamp);

        store.withdraw(0, 100e6, _three(60e6, 40e18, 0), block.timestamp);
        store.withdraw(0, 100e6, _none(), block.timestamp);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 1_000_000e6 - 600e6 + 120e6, "both exits paid");
    }

    /// @notice A minimum on the spoke slot is checked against the spoke asset paid.
    function test_minimums_spokeSlot() public {
        _deposit(alice, spoke, pyusd, 500e6);
        _deposit(alice, spoke, usdc, 500e6);
        uint256[] memory mins = new uint256[](4);
        mins[0] = 50e6 + 1;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.WithdrawMinNotMet.selector, address(pyusd), 50e6, 50e6 + 1));
        store.withdraw(spoke, 100e6, mins, block.timestamp);
    }

    /// @notice Listing a hub asset between quote and exit adds a slot, so the old list reverts on
    ///         length instead of being read against the wrong tokens.
    function test_minimums_newListingRevertsOldList() public {
        _deposit(alice, 0, usdc, 600e6);
        (, uint256[] memory quoted) = store.previewWithdraw(0, 100e6);

        MockERC20 rlusd = new MockERC20("Ripple USD", "RLUSD", 18);
        vm.prank(governor);
        store.addHubAsset(address(rlusd), address(feed));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.MinAmountsLength.selector, 3, 4));
        store.withdraw(0, 100e6, quoted, block.timestamp);
    }

    // ============ preview ============

    /// @notice Anyone can preview any amount up to what is outstanding; zero and anything above all
    ///         outstanding DLRS or shares revert.
    function test_preview_callerIndependent_andBounds() public {
        _deposit(alice, 0, usdc, 600e6);
        _deposit(alice, spoke, pyusd, 500e6);

        vm.prank(stranger);
        (, uint256[] memory hub) = store.previewWithdraw(0, 600e6);
        assertEq(hub[0], 600e6, "a stranger can quote alice's whole position");

        vm.expectRevert(IDollarStore.ZeroAmount.selector);
        store.previewWithdraw(0, 0);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InsufficientReceiptShares.selector, 600e6 + 1, 600e6));
        store.previewWithdraw(0, 600e6 + 1);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InsufficientReceiptShares.selector, 500e6 + 1, 500e6));
        store.previewWithdraw(spoke, 500e6 + 1);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InvalidPool.selector, uint16(9)));
        store.previewWithdraw(9, 1);
    }

    /// @notice After a write-down leaves hub reserves short, the preview reverts InsufficientReserves with
    ///         the same payload as the exit: for a hub exit naming the first hub asset, for a spoke exit
    ///         naming the spoke asset. Hub: 1,000 DLRS against 400 USDC. Spoke: a 1,000 claim against the
    ///         same 400.
    function test_preview_revertsInsufficientReserves_likeTheExit() public {
        _deposit(alice, 0, usdc, 1_000e6);
        _deposit(bob, spoke, usdc, 1_000e6); // the spoke's whole value is its claim on hub dollars
        usdc.burn(address(store), 1_600e6); // external loss: 2,000 -> 400
        vm.prank(governor);
        store.syncReserves(0, address(usdc));

        bytes memory hubErr =
            abi.encodeWithSelector(IDollarStore.InsufficientReserves.selector, address(usdc), 1_000e6, 400e6);
        vm.expectRevert(hubErr);
        store.previewWithdraw(0, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(hubErr);
        store.withdraw(0, 1_000e6, _none(), block.timestamp);

        bytes memory spokeErr =
            abi.encodeWithSelector(IDollarStore.InsufficientReserves.selector, address(pyusd), 1_000e6, 400e6);
        vm.expectRevert(spokeErr);
        store.previewWithdraw(spoke, 1_000e6);
        vm.prank(bob);
        vm.expectRevert(spokeErr);
        store.withdraw(spoke, 1_000e6, _none(), block.timestamp);
    }

    /// @notice A spoke with one unit on each side and two shares: one share is worth 1 * 2 / 2 = 1 unit in
    ///         total, rather than flooring both halves to zero. The spoke leg is floor(1 * 1 / 2) = 0, so
    ///         the hub leg pays the whole unit, in USDC, the only hub asset with reserves.
    function test_preview_oneShareOfTwoUnits_paysOne() public {
        _deposit(alice, spoke, pyusd, 1);
        _deposit(alice, spoke, usdc, 1);

        (, uint256[] memory quoted) = store.previewWithdraw(spoke, 1);
        assertEq(quoted[0], 0, "nothing from the spoke side");
        assertEq(quoted[1], 1, "one unit of USDC from the hub side");
        assertEq(quoted[2] + quoted[3], 0, "nothing in USDS or USDT");

        vm.prank(alice);
        (, uint256[] memory paid) = store.withdraw(spoke, 1, new uint256[](0), block.timestamp);
        assertEq(paid[1], 1, "the exit pays the same");
    }

    /// @notice For random hub and spoke states, the preview equals both the exit's return and what
    ///         actually arrives, slot by slot.
    function testFuzz_preview_matchesExit(uint256 a, uint256 b, uint256 c, uint256 s, uint256 h, uint256 burnBps)
        public
    {
        a = bound(a, 0, 1e12);
        b = bound(b, 0, 1e12);
        c = bound(c, 1, 1e12);
        s = bound(s, 1, 1e12);
        h = bound(h, 0, 1e12);
        burnBps = bound(burnBps, 1, 10_000);
        if (a > 0) _deposit(bob, 0, usdc, a);
        if (b > 0) _deposit(bob, 0, usds, b * 1e12);
        _deposit(bob, 0, usdt, c);
        _deposit(alice, spoke, pyusd, s);
        if (h > 0) _deposit(alice, spoke, usdc, h);

        uint256 shares = store.getReceiptShares(spoke, alice) * burnBps / 10_000;
        if (shares == 0) shares = 1;
        _checkPreviewMatchesExit(alice, spoke, shares);
        uint256 dlrsBurn = (a + b + c) * burnBps / 10_000;
        _checkPreviewMatchesExit(bob, 0, dlrsBurn == 0 ? 1 : dlrsBurn);
    }

    function _checkPreviewMatchesExit(address who, uint16 poolId, uint256 amount) internal {
        try store.previewWithdraw(poolId, amount) returns (address[] memory assets, uint256[] memory quoted) {
            uint256[] memory before = new uint256[](assets.length);
            for (uint256 i; i < assets.length; ++i) {
                before[i] = MockERC20(assets[i]).balanceOf(who);
            }
            vm.prank(who);
            (address[] memory paidAssets, uint256[] memory paid) =
                store.withdraw(poolId, amount, quoted, block.timestamp);
            for (uint256 i; i < assets.length; ++i) {
                assertEq(paidAssets[i], assets[i], "same asset");
                assertEq(paid[i], quoted[i], "return equals preview");
                assertEq(MockERC20(assets[i]).balanceOf(who) - before[i], quoted[i], "arrived equals preview");
            }
        } catch (bytes memory err) {
            // A value below one unit: the exit reverts the same way.
            assertEq(bytes4(err), IDollarStore.ZeroAmount.selector, "only a sub-unit value");
            vm.prank(who);
            vm.expectRevert(IDollarStore.ZeroAmount.selector);
            store.withdraw(poolId, amount, _none(), block.timestamp);
        }
    }
}
