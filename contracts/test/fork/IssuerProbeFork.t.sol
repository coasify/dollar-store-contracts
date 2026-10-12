// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Verifies the zero-value transfer probe against the real mainnet token contracts the protocol
///         intends to list, rather than against mocks. Skipped unless MAINNET_RPC_URL is set.
///         Run: MAINNET_RPC_URL=<url> forge test --match-path test/fork/IssuerProbeFork.t.sol
contract IssuerProbeForkTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address constant RLUSD = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;

    /// @dev An address on the OFAC SDN list at the time of writing (Lazarus-attributed). If it is ever
    ///      delisted, the "frozen" expectations below will fail and the constant should be updated.
    address constant SANCTIONED = 0x098B716B8Aaf21512996dC57EB0615e2383E2f96;

    address internal store = makeAddr("dollarstore");
    address internal fresh = makeAddr("fresh-wallet");

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
    }

    modifier onFork() {
        if (bytes(vm.envOr("MAINNET_RPC_URL", string(""))).length == 0) {
            vm.skip(true);
        }
        _;
    }

    function _probe(address token, address to) internal returns (bool delivered) {
        vm.prank(store);
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, 0)));
        delivered = ok && (data.length == 0 || abi.decode(data, (bool)));
    }

    function test_fork_zeroTransfer_succeedsToUnfrozenWallet() public onFork {
        assertTrue(_probe(USDC, fresh), "USDC delivers to an unfrozen wallet");
        assertTrue(_probe(USDT, fresh), "USDT delivers to an unfrozen wallet");
        assertTrue(_probe(PYUSD, fresh), "PYUSD delivers to an unfrozen wallet");
        assertTrue(_probe(USDS, fresh), "USDS delivers to an unfrozen wallet");
        assertTrue(_probe(RLUSD, fresh), "RLUSD delivers to an unfrozen wallet");
    }

    /// @notice Tokens whose transfer controls run before the amount check reject the probe for a frozen
    ///         recipient. USDT only restricts frozen senders, so a payout to a frozen wallet would also
    ///         succeed there, and the probe is consistent with that. USDS has no freeze.
    function test_fork_zeroTransfer_revertsToFrozenWallet_whereRecipientsAreRestricted() public onFork {
        assertFalse(_probe(USDC, SANCTIONED), "USDC: recipient frozen");
        assertFalse(_probe(PYUSD, SANCTIONED), "PYUSD: recipient frozen");
        assertFalse(_probe(RLUSD, SANCTIONED), "RLUSD: recipient paused");
        assertTrue(_probe(USDT, SANCTIONED), "USDT: recipients are not restricted");
        assertTrue(_probe(USDS, SANCTIONED), "USDS: no freeze exists");
    }
}
