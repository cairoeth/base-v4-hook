// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BaseV4Hook} from "src/BaseV4Hook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";

/// @notice Custom curve hook mock with v4-like liquidity.
/// @author cairoeth <https://github.com/cairoeth>
contract HookMock is BaseV4Hook {
    using Hooks for IHooks;
    using CurrencySettler for Currency;

    constructor(uint256 controllerGasLimit, IPoolManager _poolManager) BaseV4Hook(controllerGasLimit, _poolManager) {}

    function _beforeSwap(address, PoolKey calldata key, Pool.SwapParams memory params)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (Currency input, Currency output) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        uint256 amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // this "custom curve" is a line, 1-1
        // take the full input amount, and give the full output amount
        poolManager.take(input, address(this), amount);
        output.settle(poolManager, address(this), amount, false);

        // return -amountSpecified as specified to no-op the concentrated liquidity swap
        BeforeSwapDelta hookDelta = toBeforeSwapDelta(int128(-params.amountSpecified), int128(params.amountSpecified));
        return (IHooks.beforeSwap.selector, hookDelta, 0);
    }
}
