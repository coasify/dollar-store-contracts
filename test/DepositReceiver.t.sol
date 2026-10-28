// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {DLRS} from "../src/DLRS.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {Pausers} from "./utils/Pausers.sol";

/// @notice deposit is paid by the caller and owned by `receiver`: the DLRS or receipt shares go to the
///         receiver, only the receiver can exit them, the caller's tokens are pulled with dust left
///         behind, and the return and events report both sides.
contract DepositReceiverTest is Test {
    DollarStore internal store;
    DLRS internal dlrs;

    address internal governor = makeAddr("governor");
    address internal zap = makeAddr("zap"); // pays
    address internal user = makeAddr("user"); // owns

    MockERC20 internal usdc; // 6 decimals, hub
    MockERC20 internal usds; // 18 decimals, hub
    MockERC20 internal rlusd; // 18 decimals, spoke
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
        dlrs = DLRS(store.dlrs());

        usdc = new MockERC20("USD Coin", "USDC", 6);
        usds = new MockERC20("USDS", "USDS", 18);
        rlusd = new MockERC20("Ripple USD", "RLUSD", 18);
        MockAggregatorV3 feed = new MockAggregatorV3(8, 1e8);

        vm.startPrank(governor);
        store.addHubAsset(address(usdc), address(feed));
        store.addHubAsset(address(usds), address(feed));
        spoke = store.createSpoke(address(rlusd), address(feed), 0, 0);
        vm.stopPrank();

        usdc.mint(zap, 1_000_000e6);
        usds.mint(zap, 1_000_000e18);
        rlusd.mint(zap, 1_000_000e18);
        vm.startPrank(zap);
        usdc.approve(address(store), type(uint256).max);
        usds.approve(address(store), type(uint256).max);
        rlusd.approve(address(store), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Hub: the zap pays 1,000.0000005 USDS; the user gets 1,000 DLRS; the dust stays with the
    ///         zap; the event names the user as receiver and the zap as caller.
    function test_hubDeposit_receiverOwnsDlrs_callerPays() public {
        uint256 amount = 1_000e18 + 5e11; // half a 6-decimal unit of dust

        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.Deposit(user, 0, address(usds), zap, 1_000e18, 1_000e6);
        vm.prank(zap);
        (uint256 amountIn, uint256 receiptAmount) = store.deposit(0, address(usds), amount, user, block.timestamp);

        assertEq(amountIn, 1_000e18, "whole units pulled");
        assertEq(receiptAmount, 1_000e6, "DLRS minted");
        assertEq(dlrs.balanceOf(user), 1_000e6, "receiver owns the DLRS");
        assertEq(dlrs.balanceOf(zap), 0, "caller owns nothing");
        assertEq(usds.balanceOf(zap), 1_000_000e18 - 1_000e18, "caller paid amountIn, kept the dust");
        assertEq(usds.balanceOf(user), 0, "receiver paid nothing");
    }

    /// @notice Spoke asset: the shares go to the user; only the user can exit them.
    function test_spokeAssetDeposit_receiverOwnsShares() public {
        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.SpokeLiquidityAdded(spoke, user, address(rlusd), zap, 500e18, 500e6, 500e6);
        vm.prank(zap);
        (uint256 amountIn, uint256 shares) = store.deposit(spoke, address(rlusd), 500e18, user, block.timestamp);

        assertEq(amountIn, 500e18, "native RLUSD pulled");
        assertEq(shares, 500e6, "first deposit mints shares 1:1 with value");
        assertEq(store.getReceiptShares(spoke, user), 500e6, "receiver owns the shares");
        assertEq(store.getReceiptShares(spoke, zap), 0, "caller owns none");

        vm.prank(zap);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InsufficientReceiptShares.selector, 500e6, 0));
        store.withdraw(spoke, 500e6, new uint256[](0), block.timestamp);

        vm.prank(user);
        store.withdraw(spoke, 500e6, new uint256[](0), block.timestamp);
        assertEq(rlusd.balanceOf(user), 500e18, "receiver exits to its own wallet");
    }

    /// @notice A hub asset funding a spoke credits the shares to the receiver.
    function test_spokeFundingDeposit_receiverOwnsShares() public {
        vm.expectEmit(true, true, true, true, address(store));
        emit IDollarStore.SpokeLiquidityAdded(spoke, user, address(usdc), zap, 300e6, 300e6, 300e6);
        vm.prank(zap);
        (uint256 amountIn, uint256 shares) = store.deposit(spoke, address(usdc), 300e6, user, block.timestamp);

        assertEq(amountIn, 300e6, "native USDC pulled");
        assertEq(shares, 300e6, "shares minted");
        assertEq(store.getReceiptShares(spoke, user), 300e6, "receiver owns the shares");
        assertEq(store.getReceiptShares(spoke, zap), 0, "caller owns none");
        assertEq(store.getDlrsReserve(spoke), 300e6, "spoke claim credited");
    }

    /// @notice A gift adds to a receiver's existing position and takes nothing from it.
    function test_deposit_giftAddsToExistingPosition() public {
        usdc.mint(user, 100e6);
        vm.startPrank(user);
        usdc.approve(address(store), 100e6);
        store.deposit(0, address(usdc), 100e6, user, block.timestamp);
        vm.stopPrank();

        vm.prank(zap);
        store.deposit(0, address(usdc), 50e6, user, block.timestamp);

        assertEq(dlrs.balanceOf(user), 150e6, "gift adds on top");
        assertEq(usdc.balanceOf(user), 0, "receiver's tokens untouched by the gift");
    }

    /// @notice The zero address and DollarStore are rejected before anything moves.
    function test_deposit_invalidReceiver() public {
        vm.startPrank(zap);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InvalidRecipient.selector, address(0)));
        store.deposit(0, address(usdc), 100e6, address(0), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InvalidRecipient.selector, address(store)));
        store.deposit(0, address(usdc), 100e6, address(store), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.InvalidRecipient.selector, address(store)));
        store.deposit(spoke, address(rlusd), 100e18, address(store), block.timestamp);
        vm.stopPrank();

        assertEq(usdc.balanceOf(zap), 1_000_000e6, "nothing pulled");
        assertEq(store.getReceiptShares(spoke, address(store)), 0, "no shares to DollarStore");
    }

    /// @notice For any hub asset decimals and amount: amountIn = floor(amount / S) * S is exactly what
    ///         leaves the caller, receiptAmount = floor(amount / S) is exactly what the receiver gets.
    function testFuzz_hubDeposit_amountInAndReceipt(uint8 d, uint256 amount) public {
        d = uint8(bound(d, 6, 18));
        MockERC20 t = new MockERC20("T", "T", d);
        MockAggregatorV3 feed = new MockAggregatorV3(8, 1e8);
        vm.prank(governor);
        store.addHubAsset(address(t), address(feed));
        uint256 s = 10 ** (d - 6);
        amount = bound(amount, s, 1e15 * s);
        t.mint(zap, amount);

        vm.startPrank(zap);
        t.approve(address(store), amount);
        (uint256 amountIn, uint256 receiptAmount) = store.deposit(0, address(t), amount, user, block.timestamp);
        vm.stopPrank();

        assertEq(amountIn, (amount / s) * s, "amountIn");
        assertEq(receiptAmount, amount / s, "receiptAmount");
        assertEq(t.balanceOf(zap), amount - amountIn, "caller keeps only the dust");
        assertEq(dlrs.balanceOf(user), receiptAmount, "receiver credited");
    }
}
