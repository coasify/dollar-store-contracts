// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

interface IReentryTarget {
    function withdraw(uint16 poolId, uint256 receiptAmount, uint256[] calldata minAmountsOut, uint256 deadline)
        external
        returns (address[] memory, uint256[] memory);
}

/// @notice Malicious ERC20 that reenters the DollarStore on an outbound payout transfer.
/// @dev Used to prove the nonReentrant guard blocks reentrancy on token-moving paths. The reentry
///      fires only when the token is moving FROM the store TO a user (a payout), and only once,
///      so it trips the guard cleanly rather than looping.
contract MockReentrantERC20 is ERC20 {
    uint8 private immutable _decimals;
    address public store;
    address public target;
    bytes public callData;
    bool public attack;
    bool public onPull; // fire on a transfer into the store instead of out of it

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Arm the reentrancy: the next payout (store -> user) reenters store.withdraw.
    function arm(address store_) external {
        armCall(store_, store_, abi.encodeCall(IReentryTarget.withdraw, (0, 1, new uint256[](0), block.timestamp)));
    }

    /// @notice Arm the reentrancy: the next payout (store -> user) calls `target_` with `data`,
    ///         bubbling any revert.
    function armCall(address store_, address target_, bytes memory data) public {
        onPull = false;
        store = store_;
        target = target_;
        callData = data;
        attack = true;
    }

    /// @notice Like armCall, but fires on the next pull into the store (a deposit or a swap's offer).
    function armCallOnPull(address store_, address target_, bytes memory data) external {
        armCall(store_, target_, data);
        onPull = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        bool fires = onPull ? (to == store && from != store) : (from == store && to != store);
        if (attack && store != address(0) && fires) {
            attack = false; // one shot; the reentrant call reverts on the guard
            Address.functionCall(target, callData);
        }
    }
}
