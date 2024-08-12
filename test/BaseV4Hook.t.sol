// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {HookMock} from "test/mocks/HookMock.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";

contract BaseV4HookTest is Test, Deployers {
    HookMock hook;
    PoolKey _key;
    PoolModifyLiquidityTest _modifyLiquidityRouter;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddr = address(
            uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG)
        );
        deployCodeTo("HookMock.sol:HookMock", abi.encode(0, manager), hookAddr);
        hook = HookMock(hookAddr);

        _key = PoolKey(currency0, currency1, 100, 2, IHooks(address(hook)));
        hook.initialize(_key, SQRT_PRICE_1_1, ZERO_BYTES);

        _modifyLiquidityRouter = new PoolModifyLiquidityTest(IPoolManager(address(hook)));

        ERC20(Currency.unwrap(currency0)).approve(address(_modifyLiquidityRouter), type(uint256).max);
        ERC20(Currency.unwrap(currency1)).approve(address(_modifyLiquidityRouter), type(uint256).max);

        initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 100, SQRT_PRICE_1_1, ZERO_BYTES);
    }

    function test_modifyLiquidity() public {
        _modifyLiquidityRouter.modifyLiquidity(_key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function test_swap_exactInput() public {
        // add liquidity to hook and poolmanager
        _modifyLiquidityRouter.modifyLiquidity(_key, LIQUIDITY_PARAMS, ZERO_BYTES);
        initPool(currency0, currency1, IHooks(address(hook)), 100, SQRT_PRICE_1_1, ZERO_BYTES);

        uint256 balanceBefore0 = currency0.balanceOf(address(this));
        uint256 balanceBefore1 = currency1.balanceOf(address(this));

        uint256 amountToSwap = 123456;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(amountToSwap),
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });
        swapRouter.swap(_key, params, testSettings, ZERO_BYTES);

        // the hook mock implements a 1-1 linear curve (constant sum)
        assertEq(currency0.balanceOf(address(this)), balanceBefore0 - amountToSwap, "amount 0");
        assertEq(currency1.balanceOf(address(this)), balanceBefore1 + amountToSwap, "amount 1");
    }

    function test_swap_beforeSwapNoOpsSwap_exactOutput() public {
        // add liquidity to hook and poolmanager
        _modifyLiquidityRouter.modifyLiquidity(_key, LIQUIDITY_PARAMS, ZERO_BYTES);
        initPool(currency0, currency1, IHooks(address(hook)), 100, SQRT_PRICE_1_1, ZERO_BYTES);

        uint256 balanceBefore0 = currency0.balanceOf(address(this));
        uint256 balanceBefore1 = currency1.balanceOf(address(this));

        uint256 amountToSwap = 123456;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amountToSwap),
            sqrtPriceLimitX96: SQRT_PRICE_1_2
        });
        swapRouter.swap(_key, params, testSettings, ZERO_BYTES);

        // the hook mock implements a 1-1 linear curve (constant sum)
        assertEq(currency0.balanceOf(address(this)), balanceBefore0 - amountToSwap, "amount 0");
        assertEq(currency1.balanceOf(address(this)), balanceBefore1 + amountToSwap, "amount 1");
    }
}
