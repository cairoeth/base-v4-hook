// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {NoDelegateCall} from "v4-core/src/NoDelegateCall.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {ProtocolFees} from "v4-core/src/ProtocolFees.sol";
import {ERC6909Claims} from "v4-core/src/ERC6909Claims.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Lock} from "v4-core/src/libraries/Lock.sol";
import {CurrencyDelta} from "v4-core/src/libraries/CurrencyDelta.sol";
import {NonZeroDeltaCount} from "v4-core/src/libraries/NonZeroDeltaCount.sol";
import {CurrencyReserves} from "v4-core/src/libraries/CurrencyReserves.sol";
import {Extsload} from "v4-core/src/Extsload.sol";
import {Exttload} from "v4-core/src/Exttload.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";

/// @author cairoeth <https://github.com/cairoeth>
abstract contract BaseV4Hook is BaseHook, ProtocolFees, NoDelegateCall, ERC6909Claims, Extsload, Exttload {
    using PoolIdLibrary for PoolKey;
    using SafeCast for *;
    using Pool for *;
    using Hooks for IHooks;
    using Position for mapping(bytes32 => Position.Info);
    using CurrencyDelta for Currency;
    using LPFeeLibrary for uint24;
    using CurrencyReserves for Currency;
    using CustomRevert for bytes4;

    error DirectLiquidityOnly();

    int24 private constant MAX_TICK_SPACING = TickMath.MAX_TICK_SPACING;

    int24 private constant MIN_TICK_SPACING = TickMath.MIN_TICK_SPACING;

    mapping(PoolId id => Pool.State) internal _pools;

    /// @notice Sets the constant for protocol fees and base hook.
    /// @param controllerGasLimit The gas limit for the controller.
    /// @param _poolManager The pool manager contract.
    constructor(uint256 controllerGasLimit, IPoolManager _poolManager)
        ProtocolFees(controllerGasLimit)
        BaseHook(_poolManager)
    {}

    /// @notice This will revert if the contract is locked
    modifier onlyWhenUnlocked() {
        if (!Lock.isUnlocked()) IPoolManager.ManagerLocked.selector.revertWith();
        _;
    }

    /// @notice All interactions on the contract that account deltas require unlocking. A caller that calls `unlock` must implement
    /// `IUnlockCallback(msg.sender).unlockCallback(data)`, where they interact with the remaining functions on this contract.
    /// @dev The only functions callable without an unlocking are `initialize` and `updateDynamicLPFee`
    /// @param data Any data to pass to the callback, via `IUnlockCallback(msg.sender).unlockCallback(data)`
    /// @return result The data returned by the call to `IUnlockCallback(msg.sender).unlockCallback(data)`
    function unlock(bytes calldata data) external returns (bytes memory result) {
        if (Lock.isUnlocked()) IPoolManager.AlreadyUnlocked.selector.revertWith();

        Lock.unlock();

        // the caller does everything in this callback, including paying what they owe via calls to settle
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        if (NonZeroDeltaCount.read() != 0) IPoolManager.CurrencyNotSettled.selector.revertWith();
        Lock.lock();
    }

    /// @notice Initialize the state of this hook
    /// @param key The pool key for the pool to initialize (remains constant)
    /// @param sqrtPriceX96 The initial square root price
    /// @return tick The initial tick of the pool
    function initialize(PoolKey memory key, uint160 sqrtPriceX96, bytes calldata)
        external
        noDelegateCall
        returns (int24 tick)
    {
        // see TickBitmap.sol for overflow conditions that can arise from tick spacing being too large
        if (key.tickSpacing > MAX_TICK_SPACING) IPoolManager.TickSpacingTooLarge.selector.revertWith(key.tickSpacing);
        if (key.tickSpacing < MIN_TICK_SPACING) IPoolManager.TickSpacingTooSmall.selector.revertWith(key.tickSpacing);
        if (key.currency0 >= key.currency1) {
            IPoolManager.CurrenciesOutOfOrderOrEqual.selector.revertWith(
                Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)
            );
        }
        if (!key.hooks.isValidHookAddress(key.fee)) Hooks.HookAddressNotValid.selector.revertWith(address(key.hooks));

        uint24 lpFee = key.fee.getInitialLPFee();

        PoolId id = key.toId();
        (, uint24 protocolFee) = _fetchProtocolFee(key);

        tick = _pools[id].initialize(sqrtPriceX96, protocolFee, lpFee);

        // emit all details of a pool key. poolkeys are not saved in storage and must always be provided by the caller
        // the key's fee may be a static fee or a sentinel to denote a dynamic fee.
        emit IPoolManager.Initialize(
            id, key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks, sqrtPriceX96, tick
        );
    }

    /// @notice Modify the liquidity of this hook
    /// @param key The constant hook identifier
    /// @param params The parameters for modifying the liquidity
    /// @return callerDelta The balance delta of the caller of modifyLiquidity. This is the total of both principal and fee deltas.
    /// @return feesAccrued The balance delta of the fees generated in the liquidity range. Returned for informational purposes.
    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, bytes calldata)
        external
        onlyWhenUnlocked
        noDelegateCall
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        Pool.State storage pool = _getPool(id);
        pool.checkPoolInitialized();

        BalanceDelta principalDelta;
        (principalDelta, feesAccrued) = pool.modifyLiquidity(
            Pool.ModifyLiquidityParams({
                owner: msg.sender,
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta.toInt128(),
                tickSpacing: key.tickSpacing,
                salt: params.salt
            })
        );

        // fee delta and principal delta are both accrued to the caller
        callerDelta = principalDelta + feesAccrued;

        // event is emitted before the afterModifyLiquidity call to ensure events are always emitted in order
        emit IPoolManager.ModifyLiquidity(id, msg.sender, params.tickLower, params.tickUpper, params.liquidityDelta);

        _accountPoolBalanceDelta(key, callerDelta, msg.sender);
    }

    /// @notice Writes the current ERC20 balance of the specified currency to transient storage
    /// This is used to checkpoint balances for the manager and derive deltas for the caller.
    /// @param currency The currency whose balance to sync
    function sync(Currency currency) external {
        CurrencyReserves.requireNotSynced();
        if (currency.isNative()) return;
        uint256 balance = currency.balanceOfSelf();
        CurrencyReserves.syncCurrencyAndReserves(currency, balance);
    }

    /// @notice Called by the user to net out some value owed to the user
    /// @param currency The currency to withdraw
    /// @param to The address to withdraw to
    /// @param amount The amount of currency to withdraw
    function take(Currency currency, address to, uint256 amount) external onlyWhenUnlocked {
        unchecked {
            // negation must be safe as amount is not negative
            _accountDelta(currency, -(amount.toInt128()), msg.sender);
            currency.transfer(to, amount);
        }
    }

    /// @notice Called by the user to pay what is owed
    /// @return paid The amount of currency settled
    function settle() external payable onlyWhenUnlocked returns (uint256 paid) {
        return _settle(msg.sender);
    }

    /// @notice Updates the hook's LP fees.
    /// @param key The constant hook identifier.
    /// @param newDynamicLPFee The new dynamic LP fee
    function updateDynamicLPFee(PoolKey memory key, uint24 newDynamicLPFee) external {
        if (!key.fee.isDynamicFee() || msg.sender != address(key.hooks)) {
            IPoolManager.UnauthorizedDynamicLPFeeUpdate.selector.revertWith();
        }
        newDynamicLPFee.validate();
        PoolId id = key.toId();
        _pools[id].setLPFee(newDynamicLPFee);
    }

    /// @notice Pay and settle the synced currency.
    /// @param recipient The address to settle to
    function _settle(address recipient) internal returns (uint256 paid) {
        Currency currency = CurrencyReserves.getSyncedCurrency();
        // If not previously synced, expects native currency to be settled because CurrencyLibrary.NATIVE == address(0)
        if (currency.isNative()) {
            paid = msg.value;
        } else {
            if (msg.value > 0) IPoolManager.NonZeroNativeValue.selector.revertWith();
            // Reserves are guaranteed to be set, because currency and reserves are always set together
            uint256 reservesBefore = CurrencyReserves.getSyncedReserves();
            uint256 reservesNow = currency.balanceOfSelf();
            paid = reservesNow - reservesBefore;
            CurrencyReserves.resetCurrency();
        }
        _accountDelta(currency, paid.toInt128(), recipient);
    }

    /// @notice Adds a balance delta in a currency for a target address
    /// @param currency The currency to add the delta to
    /// @param delta The delta to add
    /// @param target The address to add the delta to
    function _accountDelta(Currency currency, int128 delta, address target) internal {
        if (delta == 0) return;

        (int256 previous, int256 next) = currency.applyDelta(target, delta);

        if (next == 0) {
            NonZeroDeltaCount.decrement();
        } else if (previous == 0) {
            NonZeroDeltaCount.increment();
        }
    }

    /// @notice Accounts the deltas of 2 currencies to a target address
    /// @param key The constant hook identifier.
    /// @param delta The delta to account
    /// @param target The address to account the delta to
    function _accountPoolBalanceDelta(PoolKey memory key, BalanceDelta delta, address target) internal {
        _accountDelta(key.currency0, delta.amount0(), target);
        _accountDelta(key.currency1, delta.amount1(), target);
    }

    /// @notice Fetches the state of the hook.
    /// @param id The constant ID of this hook.
    function _getPool(PoolId id) internal view override returns (Pool.State storage) {
        return _pools[id];
    }

    /// @notice Liquidity must be deposited directly.
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert DirectLiquidityOnly();
    }

    /// @dev Execute swap with custom logic
    /// @param sender The initial msg.sender for the swap call
    /// @param key The key for the pool
    /// @param params The parameters for the swap
    /// @return bytes4 The function selector for the hook
    /// @return BeforeSwapDelta The hook's delta in specified and unspecified currencies. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    /// @return uint24 Optionally override the lp fee, only used if three conditions are met: 1. the Pool has a dynamic fee, 2. the value's 2nd highest bit is set (23rd bit, 0x400000), and 3. the value is less than or equal to the maximum fee (1 million)
    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        virtual
        override
        onlyByPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return _beforeSwap(
            sender,
            key,
            Pool.SwapParams({
                tickSpacing: key.tickSpacing,
                zeroForOne: params.zeroForOne,
                amountSpecified: params.amountSpecified,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                lpFeeOverride: 0
            })
        );
    }

    /// @dev Execute swap with custom logic
    /// @param sender The initial msg.sender for the swap call
    /// @param key The key for the pool
    /// @param params The parameters for the swap
    /// @return bytes4 The function selector for the hook
    /// @return BeforeSwapDelta The hook's delta in specified and unspecified currencies. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    /// @return uint24 Optionally override the lp fee, only used if three conditions are met: 1. the Pool has a dynamic fee, 2. the value's 2nd highest bit is set (23rd bit, 0x400000), and 3. the value is less than or equal to the maximum fee (1 million)
    function _beforeSwap(address sender, PoolKey calldata key, Pool.SwapParams memory params)
        internal
        virtual
        returns (bytes4, BeforeSwapDelta, uint24);

    /// @notice Set the permissions for the hook
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true, // -- liquidity must be deposited here directly -- //
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // -- custom curve handler -- //
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // -- enable custom curve by skipping poolmanager swap -- //
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
