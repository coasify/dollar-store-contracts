// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {Pausers} from "./utils/Pausers.sol";

/// @notice Pins every worked example under "Units at the edge" in docs/PROTOCOL.md, with the exact
///         numbers the document shows: the four swap directions between 6- and 18-decimal tokens, the
///         dust left with the caller, an amount below one unit, a minimum written in the wrong
///         decimals, a deposit with dust, and a hub exit paid in two decimals.
contract UnitExamplesTest is Test {
    DollarStore internal store;

    address internal governor = makeAddr("governor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    MockERC20 internal usdc; // 6 decimals, listed in setUp
    MockERC20 internal usds; // 18 decimals, listed in setUp
    MockERC20 internal usdt; // 6 decimals, listed where a test needs it
    MockERC20 internal dai; // 18 decimals, listed where a test needs it
    MockAggregatorV3 internal feed;

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
        usdt = new MockERC20("Tether USD", "USDT", 6);
        dai = new MockERC20("Dai", "DAI", 18);
        feed = new MockAggregatorV3(8, 1e8);

        vm.startPrank(governor);
        store.addHubAsset(address(usdc), address(feed));
        store.addHubAsset(address(usds), address(feed));
        vm.stopPrank();

        MockERC20[4] memory tokens = [usdc, usds, usdt, dai];
        for (uint256 i; i < tokens.length; ++i) {
            tokens[i].mint(alice, 1_000_000 * 10 ** tokens[i].decimals());
            tokens[i].mint(bob, 1_000_000 * 10 ** tokens[i].decimals());
            vm.prank(alice);
            tokens[i].approve(address(store), type(uint256).max);
            vm.prank(bob);
            tokens[i].approve(address(store), type(uint256).max);
        }
    }

    function _list(MockERC20 token) internal {
        vm.prank(governor);
        store.addHubAsset(address(token), address(feed));
    }

    function _deposit(address who, MockERC20 token, uint256 amount) internal {
        vm.prank(who);
        store.deposit(0, address(token), amount, who, block.timestamp);
    }

    /// @dev One row of the swap table: Bob funds 1,000 of `want`, Alice swaps `amount` of `offer` with
    ///      the full-fill minimum. Checks the returns, what left Alice's wallet and what arrived.
    function _row(MockERC20 offer, MockERC20 want, uint256 amount, uint256 pulled, uint256 dust, uint256 out) internal {
        _deposit(bob, want, 1_000 * 10 ** want.decimals());
        uint256 offerBefore = offer.balanceOf(alice);
        uint256 wantBefore = want.balanceOf(alice);

        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut) =
            store.swapExactInput(address(offer), address(want), amount, out, alice, block.timestamp);

        assertEq(amountIn, pulled, "amountIn");
        assertEq(amountOut, out, "amountOut");
        assertEq(offerBefore - offer.balanceOf(alice), pulled, "only amountIn left the wallet");
        assertEq(amount - amountIn, dust, "left with the caller");
        assertEq(want.balanceOf(alice) - wantBefore, out, "delivered");
    }

    // ============ Swaps ============

    function test_example_usdcToUsds_6to18() public {
        _row(usdc, usds, 1000000000, 1000000000, 0, 1000000000000000000000);
    }

    function test_example_usdsToUsdc_18to6() public {
        _row(usds, usdc, 1000000000500000000000, 1000000000000000000000, 500000000000, 1000000000);
    }

    function test_example_usdsToDai_18to18() public {
        _list(dai);
        _row(usds, dai, 1000000000500000000000, 1000000000000000000000, 500000000000, 1000000000000000000000);
    }

    function test_example_usdcToUsdt_6to6() public {
        _list(usdt);
        _row(usdc, usdt, 1000000000, 1000000000, 0, 1000000000);
    }

    /// @notice 0.0000009 USDS is below one 6-decimal unit: nothing is pulled and the swap reverts.
    function test_example_belowOneUnit_reverts() public {
        _deposit(bob, usdc, 1_000e6);
        vm.prank(alice);
        vm.expectRevert(IDollarStore.ZeroAmount.selector);
        store.swapExactInput(address(usds), address(usdc), 900000000000, 0, alice, block.timestamp);
    }

    /// @notice A minimum of 1000000000 for a USDS output is 0.000000001 USDS, not 1,000 USDS: with only
    ///         1 USDS in the hub, a 1,000 USDC swapOrQueue passes it, fills 1 USDS and queues the rest.
    function test_example_minimumInWrongDecimals_acceptsAlmostAnything() public {
        _deposit(bob, usds, 1e18);
        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut, uint256 amountInQueued, uint256 positionId) =
            store.swapOrQueue(address(usdc), address(usds), 1000000000, 1000000000, block.timestamp);

        assertEq(amountIn, 1000000000, "amountIn");
        assertEq(amountOut, 1000000000000000000, "1 USDS filled");
        assertEq(amountInQueued, 999000000, "999 USDC queued");
        assertGt(positionId, 0, "a position");
    }

    // ============ Deposit ============

    /// @notice 100.0000005 USDS into the hub pulls 100 USDS, mints 100 DLRS and leaves the 0.0000005.
    function test_example_depositWithDust() public {
        uint256 before = usds.balanceOf(alice);
        vm.prank(alice);
        (uint256 amountIn, uint256 receiptAmount) =
            store.deposit(0, address(usds), 100000000500000000000, alice, block.timestamp);

        assertEq(amountIn, 100000000000000000000, "amountIn");
        assertEq(receiptAmount, 100000000, "100 DLRS");
        assertEq(before - usds.balanceOf(alice), 100000000000000000000, "only amountIn left the wallet");
    }

    // ============ Withdrawal ============

    /// @notice A hub of 600 USDC and 400 USDS: burning 100 DLRS pays 60 USDC and 40 USDS, each in its
    ///         own decimals. The preview shows the same.
    function test_example_hubExit_twoDecimals() public {
        _deposit(alice, usdc, 600e6);
        _deposit(alice, usds, 400e18);

        (address[] memory quotedAssets, uint256[] memory quoted) = store.previewWithdraw(0, 100000000);
        vm.prank(alice);
        (address[] memory assets, uint256[] memory amounts) =
            store.withdraw(0, 100000000, new uint256[](0), block.timestamp);

        assertEq(assets.length, 2, "two assets");
        assertEq(assets[0], address(usdc), "USDC first");
        assertEq(assets[1], address(usds), "USDS second");
        assertEq(amounts[0], 60000000, "60 USDC");
        assertEq(amounts[1], 40000000000000000000, "40 USDS");
        assertEq(quotedAssets, assets, "preview assets");
        assertEq(quoted, amounts, "preview amounts");
    }

    /// @notice The same exit with minimums in each asset's own decimals, 1 less of each: it passes. One
    ///         wei above the 40 USDS paid reverts.
    function test_example_hubExit_minimumsInOwnDecimals() public {
        _deposit(alice, usdc, 600e6);
        _deposit(alice, usds, 400e18);

        uint256[] memory mins = new uint256[](2);
        mins[0] = 59000000;
        mins[1] = 40000000000000000001;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDollarStore.WithdrawMinNotMet.selector, address(usds), 40000000000000000000, 40000000000000000001
            )
        );
        store.withdraw(0, 100000000, mins, block.timestamp);

        mins[1] = 39000000000000000000;
        vm.prank(alice);
        (, uint256[] memory amounts) = store.withdraw(0, 100000000, mins, block.timestamp);
        assertEq(amounts[0], 60000000, "60 USDC");
        assertEq(amounts[1], 40000000000000000000, "40 USDS");
    }
}
