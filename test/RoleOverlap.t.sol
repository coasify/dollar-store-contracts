// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {Pausers} from "./utils/Pausers.sol";

/// @notice One wallet in two roles in the same call. Returns report the call's own transfers (gross),
///         while the wallet's balance also moves by a queue payout the same call made to it, so the
///         return and the balance change differ by exactly that payout.
contract RoleOverlapTest is Test {
    DollarStore internal store;

    address internal governor = makeAddr("governor");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal zap = makeAddr("zap");

    MockERC20 internal usdc; // 6 decimals, hub
    MockERC20 internal dai; // 18 decimals, hub
    MockERC20 internal rlusd; // 18 decimals, spoke R
    MockERC20 internal pyusd; // 6 decimals, spoke P
    uint16 internal spokeR;
    uint16 internal spokeP;

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
        dai = new MockERC20("Dai", "DAI", 18);
        rlusd = new MockERC20("Ripple USD", "RLUSD", 18);
        pyusd = new MockERC20("PayPal USD", "PYUSD", 6);
        MockAggregatorV3 feed = new MockAggregatorV3(8, 1e8);

        vm.startPrank(governor);
        store.addHubAsset(address(usdc), address(feed));
        store.addHubAsset(address(dai), address(feed));
        spokeR = store.createSpoke(address(rlusd), address(feed), 0, 0);
        spokeP = store.createSpoke(address(pyusd), address(feed), 0, 0);
        vm.stopPrank();

        address[5] memory who = [alice, bob, carol, zap, address(this)];
        MockERC20[4] memory tokens = [usdc, dai, rlusd, pyusd];
        for (uint256 w; w < who.length; ++w) {
            for (uint256 t; t < tokens.length; ++t) {
                tokens[t].mint(who[w], 1_000_000 * 10 ** tokens[t].decimals());
                vm.prank(who[w]);
                tokens[t].approve(address(store), type(uint256).max);
            }
        }
    }

    /// @notice Alice waits to sell 100 DAI for USDC, then swaps 100 USDC for DAI with swapOrQueue and
    ///         fills her own order. The return is (100e6, 100e18, 0, 0); her USDC is unchanged and her
    ///         DAI is back where it started, because she was paid both sides.
    function test_swapOrQueue_selfMatch_reportsGrossAmounts() public {
        uint256 usdcStart = usdc.balanceOf(alice);
        uint256 daiStart = dai.balanceOf(alice);
        vm.prank(alice);
        store.swapOrQueue(address(dai), address(usdc), 100e18, 0, block.timestamp);

        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut, uint256 queued, uint256 id) =
            store.swapOrQueue(address(usdc), address(dai), 100e6, 100e18, block.timestamp);

        assertEq(amountIn, 100e6, "gross input");
        assertEq(amountOut, 100e18, "gross output");
        assertEq(queued, 0, "nothing queued");
        assertEq(id, 0, "no position");
        assertEq(usdc.balanceOf(alice), usdcStart, "USDC paid in and paid back to her order");
        assertEq(dai.balanceOf(alice), daiStart, "DAI escrowed, then delivered back");
    }

    /// @notice Carol waits to sell 100 RLUSD for USDC on spoke R. Bob swaps 100 PYUSD for RLUSD through
    ///         USDC with Carol as recipient: the second leg fills Carol's order, paying her 100 USDC, and
    ///         delivers its 100 RLUSD output to her too. The return is Bob's swap only.
    function test_swapSpokeToSpoke_recipientOwnsOrderPaidInCall() public {
        vm.prank(carol);
        store.swapOrQueue(address(rlusd), address(usdc), 100e18, 0, block.timestamp); // spoke R has no claim
        vm.prank(alice);
        store.deposit(spokeP, address(usdc), 100e6, alice, block.timestamp); // spoke P's claim: 100
        uint256 carolUsdc = usdc.balanceOf(carol);
        uint256 carolRlusd = rlusd.balanceOf(carol);
        address[] memory via = new address[](1);
        via[0] = address(usdc);

        vm.prank(bob);
        (uint256 amountIn, uint256 amountOut) =
            store.swapSpokeToSpoke(address(pyusd), address(rlusd), via, 100e6, carol, block.timestamp);

        assertEq(amountIn, 100e6, "bob's PYUSD");
        assertEq(amountOut, 100e18, "bob's swap output only");
        assertEq(rlusd.balanceOf(carol) - carolRlusd, 100e18, "carol received the output");
        assertEq(usdc.balanceOf(carol) - carolUsdc, 100e6, "and separately her own order's payout");
        assertEq(store.getUserQueuePositions(carol).length, 0, "her order is filled");
    }

    /// @notice Alice waits to buy 100 RLUSD with USDC. A zap deposits 500 RLUSD into spoke R for Alice;
    ///         the deposit settles waiting hub->spoke orders, paying Alice 100 RLUSD from the new reserve.
    ///         The return is the deposit only: 500 RLUSD pulled from the zap, 500 shares to Alice.
    function test_deposit_receiverOrderSettledInCall_returnIsDepositOnly() public {
        vm.prank(alice);
        store.swapOrQueue(address(usdc), address(rlusd), 100e6, 0, block.timestamp); // no RLUSD yet
        uint256 aliceRlusd = rlusd.balanceOf(alice);
        uint256 zapRlusd = rlusd.balanceOf(zap);

        vm.prank(zap);
        (uint256 amountIn, uint256 receiptAmount) =
            store.deposit(spokeR, address(rlusd), 500e18, alice, block.timestamp);

        assertEq(amountIn, 500e18, "pulled from the zap");
        assertEq(receiptAmount, 500e6, "shares for the deposit");
        assertEq(zapRlusd - rlusd.balanceOf(zap), amountIn, "zap paid exactly amountIn");
        assertEq(store.getReceiptShares(spokeR, alice), receiptAmount, "alice owns the shares");
        assertEq(rlusd.balanceOf(alice) - aliceRlusd, 100e18, "her waiting order was paid separately");
    }

    /// @notice An exit by a wallet that also waits in a queue pays exactly the preview; exits settle no
    ///         queue, so nothing else reaches the wallet in the call.
    function test_withdraw_byWalletWithQueuedOrder_paysExactlyPreview() public {
        vm.prank(alice);
        store.deposit(0, address(usdc), 300e6, alice, block.timestamp);
        vm.prank(alice);
        store.swapOrQueue(address(usdc), address(rlusd), 100e6, 0, block.timestamp); // waits
        vm.prank(bob);
        store.swapOrQueue(address(rlusd), address(usdc), 50e18, 0, block.timestamp); // partly fills alice

        (, uint256[] memory quoted) = store.previewWithdraw(0, 100e6);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        (, uint256[] memory paid) = store.withdraw(0, 100e6, new uint256[](0), block.timestamp);

        assertEq(paid[0], quoted[0], "return equals preview");
        assertEq(usdc.balanceOf(alice) - before, paid[0], "balance moved by the exit only");
    }
}
