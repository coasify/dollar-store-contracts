// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";
import {MockBlacklistERC20} from "./mocks/MockBlacklistERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Freezable token that short-circuits zero-value transfers BEFORE its freeze check: the probe
///      cannot see the freeze. Documents the known limitation of the mechanism.
contract MockZeroShortCircuitERC20 is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("ShortCircuit", "SC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address a, bool v) external {
        blocked[a] = v;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (value == 0) return true; // no checks at all for zero
        return super.transfer(to, value);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blocked");
        super._update(from, to, value);
    }
}

/// @dev Token that rejects every zero-value transfer. Without an exemption the probe would block every
///      exit that pays none of this asset, for every holder.
contract MockRejectZeroERC20 is ERC20 {
    constructor() ERC20("RejectZero", "RZ") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        require(value > 0, "zero transfer");
        return super.transfer(to, value);
    }
}

/// @notice On an exit, a leg that pays is checked by its own transfer. A leg that pays nothing, because
///         the pool holds none of that asset right now, is probed with a zero-value transfer from the
///         contract. For tokens whose transfer controls run on zero-value transfers, a one-sided pool
///         exit therefore still consults the issuer; for tokens that short-circuit zero-value transfers
///         it does not, and governance can exempt tokens that reject them.
contract ExitIssuerProbeTest is Test {
    DollarStore internal store;

    address internal governor = makeAddr("governor");
    address internal guardian = makeAddr("guardian");
    address internal upgrader = makeAddr("upgrader");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal trader = makeAddr("trader");

    MockBlacklistERC20 internal usdc; // Circle: freezes recipients
    MockERC20 internal usds; // Sky: no freeze at all
    MockBlacklistERC20 internal pyusd; // Paxos: freezes recipients
    MockAggregatorV3 internal feed;

    uint16 internal spoke;

    function setUp() public {
        DollarStore impl = new DollarStore();
        bytes memory initData = abi.encodeCall(DollarStore.initialize, (upgrader, governor, guardian));
        store = DollarStore(address(new ERC1967Proxy(address(impl), initData)));

        usdc = new MockBlacklistERC20("USD Coin", "USDC", 6);
        usds = new MockERC20("USDS", "USDS", 18);
        pyusd = new MockBlacklistERC20("PayPal USD", "PYUSD", 6);
        feed = new MockAggregatorV3(8, 1e8);

        vm.startPrank(governor);
        store.addHubAsset(address(usdc), address(feed));
        store.addHubAsset(address(usds), address(feed));
        spoke = store.createSpoke(address(pyusd), address(feed), 0);
        vm.stopPrank();

        address[3] memory who = [alice, bob, trader];
        for (uint256 i; i < 3; i++) {
            usdc.mint(who[i], 1_000_000e6);
            usds.mint(who[i], 1_000_000e18);
            pyusd.mint(who[i], 1_000_000e6);
            vm.startPrank(who[i]);
            usdc.approve(address(store), type(uint256).max);
            usds.approve(address(store), type(uint256).max);
            pyusd.approve(address(store), type(uint256).max);
            vm.stopPrank();
        }
    }

    /// @dev Alice LPs 100 PYUSD; Bob funds 500 USDC; a trader buys ALL the PYUSD. Pool: 0 PYUSD, 600 claim.
    function _buyOutTheSpoke() internal {
        vm.prank(alice);
        store.deposit(spoke, address(pyusd), 100e6, block.timestamp);
        vm.prank(bob);
        store.deposit(spoke, address(usdc), 500e6, block.timestamp);
        vm.prank(trader);
        store.swapExactInput(address(usdc), address(pyusd), 100e6, 0, block.timestamp);
        assertEq(store.getReserve(spoke, address(pyusd)), 0, "spoke fully bought out");
        assertEq(store.getDlrsReserve(spoke), 600e6);
    }

    // ============ The case proportional-only alone does not cover ============

    /// @notice Paxos freezes Alice. The spoke holds no PYUSD, so her proportional slice is 100% hub
    ///         dollars and no PYUSD transfer would ever consult Paxos. The probe does.
    function test_spokeExit_frozenOnSpokeAsset_poolHoldsNone_reverts() public {
        _buyOutTheSpoke();
        pyusd.setBlocked(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.ExitBlockedByIssuer.selector, address(pyusd), alice));
        store.withdraw(spoke, 100e6, block.timestamp);

        // Bob, not frozen, exits the same pool normally.
        vm.prank(bob);
        (, uint256 hubUnits) = store.withdraw(spoke, 500e6, block.timestamp);
        assertEq(hubUnits, 500e6);

        // Once Paxos unfreezes her, Alice exits too.
        pyusd.setBlocked(alice, false);
        vm.prank(alice);
        (, hubUnits) = store.withdraw(spoke, 100e6, block.timestamp);
        assertEq(hubUnits, 100e6);
    }

    /// @notice Circle freezes Alice, who funded with USDC. The spoke now holds only PYUSD (claim spent),
    ///         so her slice is 100% PYUSD and no USDC would move. The USDC probe gives Circle its say.
    function test_spokeExit_frozenOnHubAsset_poolHoldsNoHubDollars_reverts() public {
        vm.prank(alice);
        store.deposit(spoke, address(usdc), 100e6, block.timestamp); // claim 100
        vm.prank(trader);
        store.swapExactInput(address(pyusd), address(usdc), 100e6, 0, block.timestamp); // spends the claim
        assertEq(store.getDlrsReserve(spoke), 0);
        assertEq(store.getReserve(spoke, address(pyusd)), 100e6);

        usdc.setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.ExitBlockedByIssuer.selector, address(usdc), alice));
        store.withdraw(spoke, 100e6, block.timestamp);
    }

    /// @notice Mixed pool: both legs pay, so both real transfers run and the frozen one reverts on its own.
    ///         No probe is needed and the outcome is the same: no exit.
    function test_spokeExit_mixedPool_frozenLegRevertsOnItsOwn() public {
        vm.prank(alice);
        store.deposit(spoke, address(pyusd), 100e6, block.timestamp);
        vm.prank(bob);
        store.deposit(spoke, address(usdc), 100e6, block.timestamp);
        pyusd.setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert(); // MockBlacklistERC20: "blocked" on the real PYUSD transfer
        store.withdraw(spoke, 100e6, block.timestamp);
    }

    // ============ Hub exits ============

    /// @notice Circle freezes a DLRS holder. The hub holds only USDS, which nobody can freeze, so the
    ///         proportional payout would be 100% USDS with no USDC transfer. The USDC probe blocks it.
    function test_hubExit_frozenOnUsdc_hubHoldsOnlyUsds_reverts() public {
        vm.prank(alice);
        store.deposit(0, address(usds), 1_000e18, block.timestamp); // only USDS in the hub
        usdc.setBlocked(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.ExitBlockedByIssuer.selector, address(usdc), alice));
        store.withdraw(0, 1_000e6, block.timestamp);

        usdc.setBlocked(alice, false);
        vm.prank(alice);
        (, uint256 hubUnits) = store.withdraw(0, 1_000e6, block.timestamp);
        assertEq(hubUnits, 1_000e6);
    }

    /// @notice Hub holds both assets: the frozen leg is a real transfer and reverts on its own.
    function test_hubExit_mixedHub_frozenLegRevertsOnItsOwn() public {
        vm.prank(alice);
        store.deposit(0, address(usdc), 500e6, block.timestamp);
        vm.prank(bob);
        store.deposit(0, address(usds), 500e18, block.timestamp);
        usdc.setBlocked(alice, true);
        vm.prank(alice);
        vm.expectRevert();
        store.withdraw(0, 100e6, block.timestamp);
    }

    // ============ The probe is harmless for everyone else ============

    function test_probe_doesNotAffectUnfrozenExits_orBalances() public {
        _buyOutTheSpoke();
        uint256 storePyusdBefore = pyusd.balanceOf(address(store));
        uint256 alicePyusdBefore = pyusd.balanceOf(alice);
        vm.prank(alice);
        (uint256 spokeUnits, uint256 hubUnits) = store.withdraw(spoke, 100e6, block.timestamp);
        assertEq(spokeUnits, 0);
        assertEq(hubUnits, 100e6);
        // The zero-value probe moved nothing.
        assertEq(pyusd.balanceOf(address(store)), storePyusdBefore);
        assertEq(pyusd.balanceOf(alice), alicePyusdBefore);
    }

    // ============ Mixed decimals: 6dp spoke asset, 6dp + 18dp hub assets ============

    /// @notice A PYUSD (6dp) LP exits a pool whose claim is backed by USDC (6dp) and USDS (18dp). Each leg
    ///         is paid in its own native decimals from the same 6dp unit accounting.
    function test_spokeExit_mixedDecimals_paysEachLegInNativeUnits() public {
        vm.prank(alice);
        store.deposit(spoke, address(pyusd), 300e6, block.timestamp); // 300 PYUSD, 300 shares
        vm.prank(bob);
        store.deposit(spoke, address(usdc), 100e6, block.timestamp); // claim 100, hub USDC 100
        vm.prank(bob);
        store.deposit(spoke, address(usds), 200e18, block.timestamp); // claim 300, hub USDS 200
        // Pool value 600, shares 600. Alice holds 300 shares = 50% of each side.

        uint256 pyBefore = pyusd.balanceOf(alice);
        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 usdsBefore = usds.balanceOf(alice);
        vm.prank(alice);
        (uint256 spokeUnits, uint256 hubUnits) = store.withdraw(spoke, 300e6, block.timestamp);

        assertEq(spokeUnits, 150e6, "half the PYUSD side, 6dp units");
        assertEq(hubUnits, 150e6, "half the claim, 6dp units");
        assertEq(pyusd.balanceOf(alice) - pyBefore, 150e6, "PYUSD native = units (6dp)");
        // Hub leg of 150 splits by reserve weight USDC 100 : USDS 200 -> 50 USDC + 100 USDS.
        assertEq(usdc.balanceOf(alice) - usdcBefore, 50e6, "USDC native = units (6dp)");
        assertEq(usds.balanceOf(alice) - usdsBefore, 100e18, "USDS native = units * 1e12 (18dp)");
        assertEq(store.getReserve(0, address(usdc)), 50e6);
        assertEq(store.getReserve(0, address(usds)), 100e6, "hub reserves stay in 6dp units");
        assertEq(store.getDlrsReserve(spoke), 150e6);
    }

    // ============ Adversarial token behaviors and the governance exemption ============

    /// @notice Known limitation: a token that returns success for zero-value transfers before running its
    ///         freeze check is invisible to the probe. Pinned so the boundary of the guarantee is explicit.
    function test_probe_cannotSeeFreeze_whenTokenShortCircuitsZeroTransfers() public {
        MockZeroShortCircuitERC20 sc = new MockZeroShortCircuitERC20();
        vm.prank(governor);
        store.addHubAsset(address(sc), address(feed)); // listed, but the hub never holds any
        vm.prank(alice);
        store.deposit(0, address(usds), 100e18, block.timestamp); // hub: USDS only
        sc.setBlocked(alice, true); // sc's issuer froze her, but sc's zero-transfer skips that check

        vm.prank(alice);
        (, uint256 hubUnits) = store.withdraw(0, 100e6, block.timestamp); // succeeds: the probe saw nothing
        assertEq(hubUnits, 100e6, "exit went through in USDS despite the sc freeze");
    }

    /// @notice A token that rejects zero-value transfers blocks every exit that pays none of it, for
    ///         everyone, until governance exempts it from the probe.
    function test_probe_rejectZeroToken_blocksExits_untilExempted() public {
        MockRejectZeroERC20 rz = new MockRejectZeroERC20();
        vm.prank(governor);
        store.addHubAsset(address(rz), address(feed));
        vm.prank(alice);
        store.deposit(0, address(usds), 100e18, block.timestamp); // hub holds only USDS; rz leg is zero

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.ExitBlockedByIssuer.selector, address(rz), alice));
        store.withdraw(0, 100e6, block.timestamp);

        vm.prank(governor);
        store.setProbeExempt(address(rz), true);
        assertTrue(store.isProbeExempt(address(rz)));
        vm.prank(alice);
        (, uint256 hubUnits) = store.withdraw(0, 100e6, block.timestamp);
        assertEq(hubUnits, 100e6);
    }

    function test_setProbeExempt_onlyGovernor_andListedOnly() public {
        vm.prank(alice);
        vm.expectRevert(IDollarStore.OnlyGovernor.selector);
        store.setProbeExempt(address(usdc), true);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IDollarStore.AssetNotListed.selector, address(0xBEEF)));
        store.setProbeExempt(address(0xBEEF), true);
    }

    /// @notice Exit gas grows with the number of hub assets (one probe per zero leg). Pinned as a bound.
    function test_exitGas_withManyHubAssets_staysBounded() public {
        for (uint256 i; i < 6; i++) {
            MockBlacklistERC20 t = new MockBlacklistERC20("X", "X", 6);
            vm.prank(governor);
            store.addHubAsset(address(t), address(feed));
        }
        vm.prank(alice);
        store.deposit(0, address(usds), 100e18, block.timestamp); // 8 hub assets, only USDS funded
        vm.prank(alice);
        uint256 g = gasleft();
        store.withdraw(0, 100e6, block.timestamp);
        uint256 used = g - gasleft();
        assertLt(used, 400_000, "7 probes + 1 payout under 400k gas");
    }
}
