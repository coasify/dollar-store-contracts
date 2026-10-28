// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Configurable mock Chainlink feed for tests. Defaults to a fresh $1 price.
contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 private _decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;
    bool public reverts; // when true, latestRoundData reverts (simulates a broken feed)
    bool public decimalsReverts; // when true, decimals reverts

    constructor(uint8 decimals_, int256 _answer) {
        _decimals = decimals_;
        answer = _answer;
        updatedAt = block.timestamp;
        roundId = 1;
        answeredInRound = 1;
    }

    function decimals() external view override returns (uint8) {
        if (decimalsReverts) revert("feed down");
        return _decimals;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        if (reverts) revert("feed down");
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }

    // ---- test setters ----
    function setReverts(bool r) external {
        reverts = r;
    }

    function setDecimals(uint8 d) external {
        _decimals = d;
    }

    function setDecimalsReverts(bool r) external {
        decimalsReverts = r;
    }

    function setAnswer(int256 a) external {
        answer = a;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setRound(uint80 r, uint80 ar) external {
        roundId = r;
        answeredInRound = ar;
    }
}
