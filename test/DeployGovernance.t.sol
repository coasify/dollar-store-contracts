// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {DeployGovernance} from "../script/DeployGovernance.s.sol";
import {DollarStore} from "../src/DollarStore.sol";
import {IDollarStore} from "../src/interfaces/IDollarStore.sol";

/// @notice Minimal next-version implementation to exercise the timelocked upgrade path.
contract GovUpgradeMock is DollarStore {
    function newFeature() external pure returns (uint256) {
        return 42;
    }
}

/// @notice Integration test for the production governance topology built by DeployGovernance:
///         upgrader timelock (operated by upgraderSafe) + governor timelock (operated by
///         governorSafe) + guardian (guardianSafe, direct) + veto (vetoSafe, canceller on both
///         timelocks). Uses four distinct operators to also assert cross-role separation.
contract DeployGovernanceTest is Test {
    DeployGovernance internal deployer;
    DollarStore internal store;
    TimelockController internal upgraderTL;
    TimelockController internal governorTL;

    address internal upgraderSafe = makeAddr("upgraderSafe");
    address internal governorSafe = makeAddr("governorSafe");
    address internal guardianSafe = makeAddr("guardianSafe");
    address internal vetoSafe = makeAddr("vetoSafe");
    address internal anyone = makeAddr("anyone");

    uint256 internal constant UP_DELAY = 7 days;
    uint256 internal constant GOV_DELAY = 2 days;

    function setUp() public {
        deployer = new DeployGovernance();
        // In this test the deploy calls originate from the DeployGovernance instance, so it is the
        // one holding (and renouncing) the temporary timelock admin.
        DeployGovernance.Deployed memory d =
            deployer.deploy(address(deployer), upgraderSafe, governorSafe, guardianSafe, vetoSafe, UP_DELAY, GOV_DELAY);
        store = d.store;
        upgraderTL = d.upgraderTimelock;
        governorTL = d.governorTimelock;
    }

    // ============ Wiring ============

    function test_rolesWiredToTimelocksAndGuardian() public view {
        assertEq(store.upgrader(), address(upgraderTL), "upgrader = upgrader timelock");
        assertEq(store.governor(), address(governorTL), "governor = governor timelock");
        assertEq(store.guardian(), guardianSafe, "guardian = guardian safe");
    }

    function test_timelockConfig() public view {
        assertEq(upgraderTL.getMinDelay(), UP_DELAY, "upgrader delay");
        assertEq(governorTL.getMinDelay(), GOV_DELAY, "governor delay");

        // Each timelock is proposed/cancelled by its own Safe; execution is open; no external admin.
        assertTrue(upgraderTL.hasRole(upgraderTL.PROPOSER_ROLE(), upgraderSafe), "upgraderSafe proposer");
        assertTrue(upgraderTL.hasRole(upgraderTL.CANCELLER_ROLE(), upgraderSafe), "upgraderSafe canceller");
        assertTrue(governorTL.hasRole(governorTL.PROPOSER_ROLE(), governorSafe), "governorSafe proposer");
        assertTrue(upgraderTL.hasRole(upgraderTL.EXECUTOR_ROLE(), address(0)), "open executor (up)");
        assertTrue(governorTL.hasRole(governorTL.EXECUTOR_ROLE(), address(0)), "open executor (gov)");

        // Cross-role separation: the governor Safe is NOT a proposer of the upgrader timelock.
        assertFalse(upgraderTL.hasRole(upgraderTL.PROPOSER_ROLE(), governorSafe), "governorSafe not upgrade proposer");

        // The veto Safe is CANCELLER on both timelocks; the guardian is not, and the veto Safe proposes nothing.
        assertTrue(upgraderTL.hasRole(upgraderTL.CANCELLER_ROLE(), vetoSafe), "veto canceller (up)");
        assertTrue(governorTL.hasRole(governorTL.CANCELLER_ROLE(), vetoSafe), "veto canceller (gov)");
        assertFalse(upgraderTL.hasRole(upgraderTL.CANCELLER_ROLE(), guardianSafe), "guardian not canceller (up)");
        assertFalse(governorTL.hasRole(governorTL.CANCELLER_ROLE(), guardianSafe), "guardian not canceller (gov)");
        assertFalse(upgraderTL.hasRole(upgraderTL.PROPOSER_ROLE(), vetoSafe), "veto not proposer (up)");
        assertFalse(governorTL.hasRole(governorTL.PROPOSER_ROLE(), vetoSafe), "veto not proposer (gov)");

        // The temporary admin was renounced: no external admin remains.
        assertFalse(upgraderTL.hasRole(upgraderTL.DEFAULT_ADMIN_ROLE(), address(deployer)), "admin renounced (up)");
        assertFalse(governorTL.hasRole(governorTL.DEFAULT_ADMIN_ROLE(), address(deployer)), "admin renounced (gov)");
    }

    function test_veto_canCancelQueuedUpgrade() public {
        GovUpgradeMock newImpl = new GovUpgradeMock();
        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), "");
        bytes32 salt = bytes32(uint256(7));
        bytes32 id = upgraderTL.hashOperation(address(store), 0, data, bytes32(0), salt);

        // The upgrader Safe schedules; the veto Safe (a different Safe) cancels it before the delay.
        vm.prank(upgraderSafe);
        upgraderTL.schedule(address(store), 0, data, bytes32(0), salt, UP_DELAY);
        assertTrue(upgraderTL.isOperationPending(id), "scheduled");

        vm.prank(vetoSafe);
        upgraderTL.cancel(id);
        assertFalse(upgraderTL.isOperationPending(id), "cancelled by the veto Safe");
    }

    /// @notice The guardian cannot cancel the operation that replaces it, so a compromised guardian
    ///         is removed by the governor timelock after its delay.
    function test_guardian_cannotCancelItsOwnReplacement() public {
        address newGuardian = makeAddr("newGuardian");
        bytes memory data = abi.encodeCall(DollarStore.transferGuardian, (newGuardian));
        bytes32 salt = bytes32(uint256(11));
        bytes32 id = governorTL.hashOperation(address(store), 0, data, bytes32(0), salt);

        vm.prank(guardianSafe);
        store.pause();

        vm.prank(governorSafe);
        governorTL.schedule(address(store), 0, data, bytes32(0), salt, GOV_DELAY);

        bytes32 cancellerRole = governorTL.CANCELLER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, guardianSafe, cancellerRole
            )
        );
        vm.prank(guardianSafe);
        governorTL.cancel(id);

        vm.warp(block.timestamp + GOV_DELAY);
        vm.prank(anyone);
        governorTL.execute(address(store), 0, data, bytes32(0), salt);
        vm.prank(newGuardian);
        store.acceptGuardian();
        assertEq(store.guardian(), newGuardian, "guardian replaced");

        // The old guardian's pause is lifted by the new one.
        vm.prank(newGuardian);
        store.unpause();
        assertFalse(store.paused(), "unpaused by the new guardian");
    }

    function test_veto_cannotPause() public {
        vm.prank(vetoSafe);
        vm.expectRevert();
        store.pause();
    }

    function test_deploy_revertsOnZeroVetoSafe() public {
        DeployGovernance fresh = new DeployGovernance();
        vm.expectRevert(bytes("vetoSafe = zero"));
        fresh.deploy(address(fresh), upgraderSafe, governorSafe, guardianSafe, address(0), UP_DELAY, GOV_DELAY);
    }

    function test_checkSeparation_mainnetRequiresGuardianApartFromEveryCanceller() public {
        // Any other chain: one address may hold everything, for rehearsals.
        deployer.checkSeparation(guardianSafe, guardianSafe, guardianSafe, guardianSafe);

        vm.chainId(1);
        deployer.checkSeparation(guardianSafe, vetoSafe, upgraderSafe, governorSafe);
        // The two proposers may be one Safe.
        deployer.checkSeparation(guardianSafe, vetoSafe, upgraderSafe, upgraderSafe);

        vm.expectRevert(bytes("mainnet: VETO_SAFE must differ from GUARDIAN_SAFE"));
        deployer.checkSeparation(guardianSafe, guardianSafe, upgraderSafe, governorSafe);
        vm.expectRevert(bytes("mainnet: GUARDIAN_SAFE must differ from UPGRADER_SAFE"));
        deployer.checkSeparation(guardianSafe, vetoSafe, guardianSafe, governorSafe);
        vm.expectRevert(bytes("mainnet: GUARDIAN_SAFE must differ from GOVERNOR_SAFE"));
        deployer.checkSeparation(guardianSafe, vetoSafe, upgraderSafe, guardianSafe);
    }

    /// @notice Why the mainnet check covers the proposers: a guardian that is also the governor's
    ///         proposer can cancel the operation that replaces it, even with a separate veto Safe.
    function test_guardianThatIsAProposer_canCancelItsOwnReplacement() public {
        DeployGovernance fresh = new DeployGovernance();
        DeployGovernance.Deployed memory d =
            fresh.deploy(address(fresh), guardianSafe, guardianSafe, guardianSafe, vetoSafe, UP_DELAY, GOV_DELAY);
        bytes memory data = abi.encodeCall(DollarStore.transferGuardian, (makeAddr("newGuardian")));
        bytes32 id = d.governorTimelock.hashOperation(address(d.store), 0, data, bytes32(0), bytes32(0));

        vm.startPrank(guardianSafe);
        d.governorTimelock.schedule(address(d.store), 0, data, bytes32(0), bytes32(0), GOV_DELAY);
        d.governorTimelock.cancel(id);
        vm.stopPrank();
        assertFalse(d.governorTimelock.isOperation(id), "replacement cancelled by the guardian itself");

        vm.chainId(1);
        vm.expectRevert(bytes("mainnet: GUARDIAN_SAFE must differ from UPGRADER_SAFE"));
        fresh.checkSeparation(guardianSafe, vetoSafe, guardianSafe, guardianSafe);
    }

    // ============ Guardian is instant ============

    function test_guardian_pausesInstantly() public {
        vm.prank(guardianSafe);
        store.pause();
        assertTrue(store.paused(), "guardian pauses without a timelock");
    }

    // ============ Upgrades require the upgrader timelock ============

    function test_directUpgrade_reverts_evenFromOtherRoles() public {
        GovUpgradeMock newImpl = new GovUpgradeMock();

        vm.prank(anyone);
        vm.expectRevert(IDollarStore.OnlyUpgrader.selector);
        store.upgradeToAndCall(address(newImpl), "");

        // Neither the guardian nor the governor timelock can upgrade directly.
        vm.prank(guardianSafe);
        vm.expectRevert(IDollarStore.OnlyUpgrader.selector);
        store.upgradeToAndCall(address(newImpl), "");

        vm.prank(address(governorTL));
        vm.expectRevert(IDollarStore.OnlyUpgrader.selector);
        store.upgradeToAndCall(address(newImpl), "");
    }

    function test_upgrade_viaUpgraderTimelock() public {
        GovUpgradeMock newImpl = new GovUpgradeMock();
        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), "");
        bytes32 salt = bytes32(0);

        // The upgrader Safe (proposer) schedules the upgrade.
        vm.prank(upgraderSafe);
        upgraderTL.schedule(address(store), 0, data, bytes32(0), salt, UP_DELAY);

        // Executing before the delay elapses reverts (operation not ready).
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        upgraderTL.execute(address(store), 0, data, bytes32(0), salt);

        // After the delay, anyone can execute (open executor).
        vm.warp(block.timestamp + UP_DELAY + 1);
        vm.prank(anyone);
        upgraderTL.execute(address(store), 0, data, bytes32(0), salt);

        assertEq(GovUpgradeMock(address(store)).newFeature(), 42, "upgrade applied via timelock");
    }

    function test_upgrade_crossRoleSafe_cannotSchedule() public {
        GovUpgradeMock newImpl = new GovUpgradeMock();
        bytes memory data = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), "");

        // The governor Safe is not a proposer of the upgrader timelock -> AccessControl revert.
        vm.prank(governorSafe);
        vm.expectPartialRevert(bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")));
        upgraderTL.schedule(address(store), 0, data, bytes32(0), bytes32(0), UP_DELAY);
    }

    // ============ Governor actions require the governor timelock ============

    function test_governorAction_viaGovernorTimelock() public {
        bytes memory data = abi.encodeCall(DollarStore.setPegTolerance, (100));
        bytes32 salt = bytes32(uint256(1));

        // Direct call reverts: only the governor timelock may call governor-gated functions.
        vm.prank(anyone);
        vm.expectRevert(IDollarStore.OnlyGovernor.selector);
        store.setPegTolerance(100);

        // Schedule via the governor timelock (operated by governorSafe), wait, execute.
        vm.prank(governorSafe);
        governorTL.schedule(address(store), 0, data, bytes32(0), salt, GOV_DELAY);
        vm.warp(block.timestamp + GOV_DELAY + 1);
        governorTL.execute(address(store), 0, data, bytes32(0), salt);

        assertEq(store.pegTolerance(), 100, "governor param set via timelock");
    }
}
