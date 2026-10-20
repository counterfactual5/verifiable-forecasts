// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Uniswap V3 `observe` over a piecewise-constant tick timeline.
/// @dev tickCumulative is 0 at the first timeline point and accumulates tick * seconds after it.
///      Points before `oldest` (default: first timeline point) revert "OLD" for the whole batch.
contract MockPool {
    uint256[] public times;
    int256[] public ticks;
    int256[] public cums; // tickCumulative at times[i]
    uint256 public oldest;

    /// @notice From `time` onward the tick is `tick`. Times must be strictly increasing.
    function setTickFrom(uint256 time, int24 tick) public {
        uint256 n = times.length;
        if (n == 0) {
            oldest = time;
            cums.push(0);
        } else {
            require(time > times[n - 1], "time order");
            cums.push(cums[n - 1] + ticks[n - 1] * int256(time - times[n - 1]));
        }
        times.push(time);
        ticks.push(tick);
    }

    /// @notice Convenience: consecutive segments of `len` seconds starting at `start`.
    function setSegments(uint256 start, uint256 len, int24[] calldata segTicks) external {
        for (uint256 i = 0; i < segTicks.length; ++i) {
            setTickFrom(start + i * len, segTicks[i]);
        }
    }

    function setOldest(uint256 time) external {
        oldest = time;
    }

    function tickCumulativeAt(uint256 t) public view returns (int56) {
        require(times.length > 0 && t >= oldest && t >= times[0], "OLD");
        uint256 i = times.length - 1;
        while (times[i] > t) --i;
        return int56(cums[i] + ticks[i] * int256(t - times[i]));
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        uint256 n = secondsAgos.length;
        tickCumulatives = new int56[](n);
        secondsPerLiquidityCumulativeX128s = new uint160[](n);
        for (uint256 i = 0; i < n; ++i) {
            require(secondsAgos[i] <= block.timestamp, "OLD");
            tickCumulatives[i] = tickCumulativeAt(block.timestamp - secondsAgos[i]);
        }
    }
}
