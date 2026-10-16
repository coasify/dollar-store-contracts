// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {DLRS} from "../src/DLRS.sol";
import {MockBlacklistERC20} from "./mocks/MockBlacklistERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {Pausers} from "./utils/Pausers.sol";

/// @notice U2 P6: deposits into a spoke settle the queues the new liquidity can fill, and a
///         position whose payout fails is parked whether its escrow is a hub or a spoke asset.
contract SpokeQueueTriggerTest is Test {
    DollarStore internal store;
    DLRS internal dlrs;

    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardian");
    address internal pauser = makeAddr("pauser");
    address internal unpauser = makeAddr("unpauser");
    address internal upgrader = makeAddr("upgrader");
    address internal alice = makeAddr("alice"); // LP
    address internal bob = makeAddr("bob"); // queued trader

    MockBlacklistERC20 internal usdc; // 6dp hub
    MockBlacklistERC20 internal rlusd; // 18dp spoke asset
    MockAggregatorV3 internal feed;

    uint16 internal spoke;

    function setUp() public {
        DollarStore impl = new DollarStore();
        bytes memory initData =
            abi.encodeCall(DollarStore.initialize, (upgrader, governor, guardian, unpauser, Pausers.one(pauser)));
        store = DollarStore(address(new ERC1967Proxy(address(impl), initData)));
        dlrs = DLRS(store.dlrs());

        usdc = new MockBlacklistERC20("USD Coin", "USDC", 6);
        rlusd = new MockBlacklistERC20("Ripple USD", "RLUSD", 18);
        feed = new MockAggregatorV3(8, 1e8);

        vm.startPrank(governor);
        store.addHubAsset(address(usdc), address(feed));
        spoke = store.createSpoke(address(rlusd), address(feed), 0, 0);
        vm.stopPrank();

        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        rlusd.mint(alice, 1_000_000e18);
        rlusd.mint(bob, 1_000_000e18);
    }

    function _queue(address who, MockBlacklistERC20 offer, MockBlacklistERC20 want, uint256 amt)
        internal
        returns (uint256 queued)
    {
        vm.startPrank(who);
        offer.approve(address(store), amt);
        (, queued) = store.swap(address(offer), address(want), amt, 0, 0, block.timestamp);
        vm.stopPrank();
    }

    // ============ Deposit-triggered settlement ============

    function test_depositSpokeAsset_settlesHubToSpokeQueue() public {
        // Bob queues USDC->RLUSD with no spoke liquidity.
        uint256 q = _queue(bob, usdc, rlusd, 500e6);
        assertEq(q, 500e6, "bob queued");

        // Alice deposits the spoke asset; the new reserve settles bob's waiting hub->spoke order.
        vm.startPrank(alice);
        rlusd.approve(address(store), 1_000e18);
        store.deposit(spoke, address(rlusd), 1_000e18, block.timestamp);
        vm.stopPrank();

        assertEq(rlusd.balanceOf(bob), 1_000_000e18 + 500e18, "bob got RLUSD from the deposit");
        assertEq(store.getQueueDepth(address(usdc), address(rlusd)), 0, "queue settled");
        assertEq(store.getDlrsReserve(spoke), 500e6, "dlrsReserve grew (bob's USDC escrow backs it)");
        assertEq(store.getReserve(spoke, address(rlusd)), 500e6, "spoke reserve = 1000 - 500 paid out");
        assertEq(store.getReserve(0, address(usdc)), 500e6, "bob's escrow moved into hub reserves");
        // Alice keeps her full value (settlement is pool-value-neutral).
        assertEq(store.getReceiptShares(spoke, alice), 1_000e6, "alice shares unchanged in value");
        assertEq(dlrs.totalSupply() + store.getDlrsReserve(spoke), store.getReserve(0, address(usdc)), "conservation");
    }

    function test_fundingDeposit_settlesSpokeToHubQueue() public {
        // Bob queues RLUSD->USDC with no DLRS side.
        uint256 q = _queue(bob, rlusd, usdc, 500e18);
        assertEq(q, 500e6, "bob queued");

        // Alice funds the spoke with a hub asset; the new DLRS side settles bob's spoke->hub order.
        vm.startPrank(alice);
        usdc.approve(address(store), 1_000e6);
        store.deposit(spoke, address(usdc), 1_000e6, block.timestamp);
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), 1_000_000e6 + 500e6, "bob got USDC from the funding deposit");
        assertEq(store.getQueueDepth(address(rlusd), address(usdc)), 0, "queue settled");
        assertEq(store.getDlrsReserve(spoke), 500e6, "dlrsReserve = 1000 funded - 500 consumed");
        assertEq(store.getReserve(spoke, address(rlusd)), 500e6, "bob's RLUSD escrow entered the spoke");
        assertEq(store.getReserve(0, address(usdc)), 500e6, "hub reserve = 1000 - 500 paid to bob");
    }

    // ============ Failed payout during a trigger: the position is parked ============

    function test_trigger_spokeEscrow_isParked() public {
        // Bob queues RLUSD->USDC (escrow = spoke asset), then is blocked from receiving USDC.
        _queue(bob, rlusd, usdc, 500e18);
        uint256 id = store.getUserQueuePositions(bob)[0];
        usdc.setBlocked(bob, true);

        // Alice funds USDC -> settlement tries to pay bob USDC, which fails -> bob is parked.
        vm.startPrank(alice);
        usdc.approve(address(store), 1_000e6);
        store.deposit(spoke, address(usdc), 1_000e6, block.timestamp);
        vm.stopPrank();

        assertEq(usdc.balanceOf(bob), 1_000_000e6, "bob received no USDC (blocked)");
        assertEq(store.getReceiptShares(spoke, bob), 0, "bob holds no shares");
        assertEq(store.getReserve(spoke, address(rlusd)), 0, "escrowed RLUSD is not in the pool");
        assertEq(store.getQueueDepth(address(rlusd), address(usdc)), 0, "line advanced past bob");
        assertEq(store.getQueueDepth(address(rlusd), address(0)), 500e6, "bob's escrow is on the parked line");
        assertTrue(store.isQueuePositionParked(id));
        assertEq(store.getReceiptTotalShares(spoke), 1_000e6, "alice only");
        assertEq(store.getDlrsReserve(spoke), 1_000e6, "nothing was paid, claim intact");

        // The only way out is cancel, which returns the RLUSD; the USDC block is irrelevant to it.
        vm.prank(bob);
        store.cancelQueue(id);
        assertEq(rlusd.balanceOf(bob), 1_000_000e18, "escrow returned as RLUSD");
        assertEq(store.getQueueDepth(address(rlusd), address(0)), 0);
    }

    function test_trigger_hubEscrow_isParked() public {
        // Bob queues USDC->RLUSD (escrow = hub asset), then is blocked from receiving RLUSD.
        _queue(bob, usdc, rlusd, 500e6);
        uint256 id = store.getUserQueuePositions(bob)[0];
        rlusd.setBlocked(bob, true);

        // Alice deposits RLUSD -> settlement tries to pay bob RLUSD, which fails -> bob is parked.
        vm.startPrank(alice);
        rlusd.approve(address(store), 1_000e18);
        store.deposit(spoke, address(rlusd), 1_000e18, block.timestamp);
        vm.stopPrank();

        assertEq(rlusd.balanceOf(bob), 1_000_000e18, "bob received no RLUSD (blocked)");
        assertEq(dlrs.balanceOf(bob), 0, "bob holds no DLRS");
        assertEq(store.getReserve(0, address(usdc)), 0, "escrowed USDC is not in hub reserves");
        assertEq(store.getQueueDepth(address(usdc), address(rlusd)), 0, "line advanced past bob");
        assertEq(store.getQueueDepth(address(usdc), address(0)), 500e6, "parked");
        assertTrue(store.isQueuePositionParked(id));
        assertEq(store.getReserve(spoke, address(rlusd)), 1_000e6, "spoke reserve untouched (payout failed)");
    }

    // ============ F-01: deposit-triggered settlement is inflow-gated ============

    /// @notice A permissionless spoke deposit must NOT settle a queue whose offer asset is
    ///         deposit-paused: absorbing it would take a (typically depegged) asset at par. The trigger
    ///         skips it; the queue stays settleable via processQueue once the asset is healthy again.
    function test_trigger_skipsQueueWhenOfferDepositPaused() public {
        uint256 q = _queue(bob, usdc, rlusd, 500e6); // queued while USDC is healthy
        assertEq(q, 500e6, "bob queued");

        vm.prank(pauser);
        store.pauseDeposits(address(usdc)); // guardian pauses USDC (e.g. after a depeg)

        // Alice deposits the healthy spoke asset; the trigger must skip bob's USDC->RLUSD queue.
        vm.startPrank(alice);
        rlusd.approve(address(store), 1_000e18);
        store.deposit(spoke, address(rlusd), 1_000e18, block.timestamp);
        vm.stopPrank();

        assertEq(store.getQueueDepth(address(usdc), address(rlusd)), 500e6, "queue NOT settled (offer paused)");
        assertEq(rlusd.balanceOf(bob), 1_000_000e18, "bob got no RLUSD");
        assertEq(store.getReserve(0, address(usdc)), 0, "no paused USDC absorbed into hub reserves");
        assertEq(store.getDlrsReserve(spoke), 0, "dlrsReserve unchanged");
        assertEq(store.getReserve(spoke, address(rlusd)), 1_000e6, "alice's full deposit sits in the spoke reserve");

        // Once USDC is healthy again the queue is still settleable via processQueue.
        vm.prank(unpauser);
        store.unpauseDeposits(address(usdc));
        store.processQueue(address(usdc), address(rlusd), 10);
        assertEq(store.getQueueDepth(address(usdc), address(rlusd)), 0, "queue settled after unpause");
        assertEq(rlusd.balanceOf(bob), 1_000_000e18 + 500e18, "bob got RLUSD via processQueue");
    }

    /// @notice Same protection for an OFF-PEG (not paused) offer asset: the trigger reads the oracle and
    ///         skips the queue rather than absorbing the discounted asset 1:1.
    function test_trigger_skipsQueueWhenOfferOffPeg() public {
        // Give USDC its own feed so it can be depegged independently of the spoke asset.
        MockAggregatorV3 usdcFeed = new MockAggregatorV3(8, 1e8);
        vm.prank(governor);
        store.setPriceFeed(address(usdc), address(usdcFeed));

        uint256 q = _queue(bob, usdc, rlusd, 500e6); // queued while USDC is on peg
        assertEq(q, 500e6, "bob queued");

        usdcFeed.setAnswer(0.9e8); // USDC drops well below the peg tolerance band

        vm.startPrank(alice);
        rlusd.approve(address(store), 1_000e18);
        store.deposit(spoke, address(rlusd), 1_000e18, block.timestamp);
        vm.stopPrank();

        assertEq(store.getQueueDepth(address(usdc), address(rlusd)), 500e6, "off-peg offer queue NOT settled");
        assertEq(rlusd.balanceOf(bob), 1_000_000e18, "bob got no RLUSD");
        assertEq(store.getReserve(0, address(usdc)), 0, "no off-peg USDC absorbed into hub reserves");
    }

    // ---- canInflow branch coverage: each condition makes the trigger SKIP the usdc->rlusd queue ----
    // Gives usdc its own feed and queues a usdc->rlusd position while healthy; the caller then breaks the
    // feed/state before the rlusd deposit triggers settlement, so canInflow(usdc) returns false.
    function _queueUsdcToRlusd() internal returns (MockAggregatorV3 usdcFeed) {
        usdcFeed = new MockAggregatorV3(8, 1e8);
        vm.prank(governor);
        store.setPriceFeed(address(usdc), address(usdcFeed));
        _queue(bob, usdc, rlusd, 500e6);
    }

    function _depositRlusdAndAssertSkipped() internal {
        vm.startPrank(alice);
        rlusd.approve(address(store), 1_000e18);
        store.deposit(spoke, address(rlusd), 1_000e18, block.timestamp);
        vm.stopPrank();
        assertEq(store.getQueueDepth(address(usdc), address(rlusd)), 500e6, "queue NOT settled: offer failed canInflow");
        assertEq(rlusd.balanceOf(bob), 1_000_000e18, "bob got no RLUSD");
    }

    function test_trigger_skipsQueueWhenOfferPriceZero() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        usdcFeed.setAnswer(0); // invalid price
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferRoundStale() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        usdcFeed.setRound(5, 4); // answeredInRound < roundId
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferPriceStale() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        vm.warp(100_000);
        feed.setUpdatedAt(100_000); // keep the rlusd feed fresh so the deposit itself succeeds
        usdcFeed.setUpdatedAt(100_000 - (store.maxStaleness() + 1)); // usdc feed one second past the window
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferFeedReverts() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        usdcFeed.setReverts(true); // latestRoundData reverts -> canInflow catch -> false
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferPoolPaused() public {
        _queueUsdcToRlusd();
        vm.prank(pauser);
        store.pausePool(0); // hub pool paused -> canInflow(usdc) false; does not block the spoke rlusd deposit
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferFeedTimeInFuture() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        usdcFeed.setUpdatedAt(block.timestamp + 1); // a malformed feed: updated after now
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferFeedDecimalsRevert() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        usdcFeed.setDecimalsReverts(true);
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferFeedDecimalsAbove18() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        usdcFeed.setDecimals(19);
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferPriceOverflows() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        usdcFeed.setAnswer(type(int256).max); // scaled to 18 decimals this would overflow
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferFeedReturnsTooLittle() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        vm.mockCall(address(usdcFeed), abi.encodeWithSelector(usdcFeed.latestRoundData.selector), hex"01");
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferFeedDecimalsReturnTooLittle() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        vm.mockCall(address(usdcFeed), abi.encodeWithSelector(usdcFeed.decimals.selector), hex"01");
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferFeedRoundOutOfRange() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        uint256 tooBig = uint256(type(uint80).max) + 1; // not a uint80; answeredInRound == roundId otherwise passes
        vm.mockCall(
            address(usdcFeed),
            abi.encodeWithSelector(usdcFeed.latestRoundData.selector),
            abi.encode(tooBig, int256(1e8), uint256(0), block.timestamp, tooBig)
        );
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferFeedAnsweredInRoundOutOfRange() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        // Only answeredInRound is out of range. It is above roundId, so without the range check the feed
        // would read as healthy.
        vm.mockCall(
            address(usdcFeed),
            abi.encodeWithSelector(usdcFeed.latestRoundData.selector),
            abi.encode(uint256(1), int256(1e8), uint256(0), block.timestamp, uint256(type(uint80).max) + 1)
        );
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferFeedDecimalsOutOfRange() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        // 264 is not a uint8; its low byte is 8, the feed's real decimals.
        vm.mockCall(address(usdcFeed), abi.encodeWithSelector(usdcFeed.decimals.selector), abi.encode(uint256(264)));
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_skipsQueueWhenOfferFeedHasNoCode() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        vm.etch(address(usdcFeed), ""); // calls succeed and return nothing
        _depositRlusdAndAssertSkipped();
    }

    function test_trigger_settlesQueueWhenOfferFeedPadsItsAnswer() public {
        _queueUsdcToRlusd();
        PaddedFeed padded = new PaddedFeed();
        vm.prank(governor);
        store.setPriceFeed(address(usdc), address(padded)); // a healthy $1 answer followed by 8 KB of zeros

        vm.startPrank(alice);
        rlusd.approve(address(store), 1_000e18);
        store.deposit(spoke, address(rlusd), 1_000e18, block.timestamp);
        vm.stopPrank();
        assertEq(store.getQueueDepth(address(usdc), address(rlusd)), 0, "padding ignored: queue settled");
        assertEq(rlusd.balanceOf(bob), 1_000_000e18 + 500e18, "bob got his RLUSD");
    }

    function test_trigger_skipsQueueWhenOfferFeedNeverAnswers() public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        vm.etch(address(usdcFeed), address(new LoopingFeed()).code); // uses up whatever gas it is given

        // The feed call is capped, so the loop costs the depositor at most that budget, not 63/64 of their gas.
        vm.startPrank(alice);
        rlusd.approve(address(store), 1_000e18);
        uint256 before = gasleft();
        store.deposit{gas: 3_000_000}(spoke, address(rlusd), 1_000e18, block.timestamp);
        assertLt(before - gasleft(), 1_000_000, "a looping feed costs the caller at most its budget");
        vm.stopPrank();
        assertEq(store.getQueueDepth(address(usdc), address(rlusd)), 500e6, "queue NOT settled: offer failed canInflow");
        assertEq(rlusd.balanceOf(bob), 1_000_000e18, "bob got no RLUSD");
    }

    /// @dev For any feed response, the queue is settled (canInflow) exactly when a USDC deposit (checkPeg)
    ///      succeeds. Each field is healthy most of the time, so both outcomes are common.
    function testFuzz_trigger_canInflowAgreesWithCheckPeg(
        uint256 roundId,
        uint256 roundGap,
        uint256 priceBps,
        uint256 age,
        uint256 decimals_
    ) public {
        MockAggregatorV3 usdcFeed = _queueUsdcToRlusd();
        vm.warp(1_000_000);
        feed.setUpdatedAt(block.timestamp); // keep the rlusd feed fresh so the deposit itself succeeds
        uint256 dec = bound(decimals_, 0, 19); // 19 is unhealthy
        uint256 answer = 10 ** dec * bound(priceBps, 9_900, 10_100) / 10_000; // the peg band is 9,950 to 10,050
        uint256 updatedAt = block.timestamp - bound(age, 0, store.maxStaleness() * 5 / 4);
        roundId = bound(roundId, 1, uint256(type(uint80).max) + 1); // the top value is out of range
        uint256 answeredInRound = roundId + bound(roundGap, 0, 2) - 1; // one below roundId is unhealthy
        vm.mockCall(
            address(usdcFeed),
            abi.encodeWithSelector(usdcFeed.latestRoundData.selector),
            abi.encode(roundId, answer, uint256(0), updatedAt, answeredInRound)
        );
        vm.mockCall(address(usdcFeed), abi.encodeWithSelector(usdcFeed.decimals.selector), abi.encode(dec));

        uint256 snap = vm.snapshotState();
        vm.startPrank(alice);
        usdc.approve(address(store), 1e6);
        bool healthy;
        try store.deposit(0, address(usdc), 1e6, block.timestamp) {
            healthy = true;
        } catch {}
        vm.stopPrank();
        vm.revertToState(snap);

        vm.startPrank(alice);
        rlusd.approve(address(store), 1_000e18);
        store.deposit(spoke, address(rlusd), 1_000e18, block.timestamp);
        vm.stopPrank();
        bool settled = store.getQueueDepth(address(usdc), address(rlusd)) == 0;
        assertEq(settled, healthy, "canInflow and checkPeg disagree");
    }
}

/// @dev A feed that never answers.
contract LoopingFeed {
    function decimals() external pure returns (uint8) {
        while (true) {}
        return 8;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        while (true) {}
        return (1, 1e8, 0, 0, 1);
    }
}

/// @dev A healthy $1 feed that pads its latestRoundData answer to 8 KB.
contract PaddedFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        assembly {
            let p := mload(0x40)
            mstore(p, 1)
            mstore(add(p, 0x20), 100000000)
            mstore(add(p, 0x40), 0)
            mstore(add(p, 0x60), timestamp())
            mstore(add(p, 0x80), 1)
            return(p, 8192)
        }
    }
}
