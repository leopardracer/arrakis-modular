// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPancakeSwapV4StandardModule} from
    "../interfaces/IPancakeSwapV4StandardModule.sol";
import {
    NATIVE_COIN,
    NATIVE_COIN_DECIMALS,
    PIPS,
    BASE
} from "../constants/CArrakis.sol";
import {
    UnderlyingPayload,
    RangeData,
    PositionUnderlying,
    Range as PoolRange,
    ComputeFeesPayload,
    GetFeesPayload,
    SwapPayload,
    RebalanceResult,
    Withdraw,
    Deposit,
    SwapBalances
} from "../structs/SPancakeSwapV4.sol";
import {IArrakisLPModule} from "../interfaces/IArrakisLPModule.sol";

import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from
    "@pancakeswap/v4-core/src/types/PoolId.sol";
import {
    BalanceDeltaLibrary,
    BalanceDelta
} from "@pancakeswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@pancakeswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@pancakeswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {
    ICLHooks,
    HOOKS_BEFORE_REMOVE_LIQUIDITY_OFFSET,
    HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET,
    HOOKS_AFTER_ADD_LIQUIDITY_OFFSET
} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLHooks.sol";
import {FullMath} from
    "@pancakeswap/v4-core/src/pool-cl/libraries/FullMath.sol";
import {TickMath} from
    "@pancakeswap/v4-core/src/pool-cl/libraries/TickMath.sol";
import {FixedPoint128} from
    "@pancakeswap/v4-core/src/pool-cl/libraries/FixedPoint128.sol";
import {CLPosition} from
    "@pancakeswap/v4-core/src/pool-cl/libraries/CLPosition.sol";
import {Tick} from
    "@pancakeswap/v4-core/src/pool-cl/libraries/Tick.sol";
import {ICLPoolManager} from
    "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";
import {
    Currency,
    CurrencyLibrary
} from "@pancakeswap/v4-core/src/types/Currency.sol";
import {SqrtPriceMath} from
    "@pancakeswap/v4-core/src/pool-cl/libraries/SqrtPriceMath.sol";

import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {SafeERC20} from
    "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from
    "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from
    "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {LiquidityAmounts} from
    "@v3-lib-0.8/contracts/LiquidityAmounts.sol";

library PancakeSwapV4 {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeERC20 for IERC20Metadata;
    using Address for address payable;
    using Hooks for bytes32;
    using CurrencyLibrary for Currency;

    // #region rebalance.

    function rebalance(
        IPancakeSwapV4StandardModule self,
        PoolKey memory poolKey_,
        IPancakeSwapV4StandardModule.LiquidityRange[] memory
            liquidityRanges_,
        SwapPayload memory swapPayload_,
        IPancakeSwapV4StandardModule.Range[] storage ranges_,
        mapping(bytes32 => bool) storage activeRanges_
    ) public returns (bytes memory result) {
        ICLPoolManager poolManager = self.poolManager();
        IVault pancakeVault = self.vault();

        {
            RebalanceResult memory rebalanceResult = _modifyLiquidity(
                poolManager,
                poolKey_,
                liquidityRanges_,
                swapPayload_,
                ranges_,
                activeRanges_
            );

            // #region collect and send fees to manager.
            {
                IArrakisLPModule module =
                    IArrakisLPModule(address(self));

                (
                    rebalanceResult.managerFee0,
                    rebalanceResult.managerFee1
                ) = _collectAndSendFeesToManager(
                    pancakeVault,
                    poolKey_,
                    module.metaVault().manager(),
                    module.managerFeePIPS(),
                    rebalanceResult.fee0,
                    rebalanceResult.fee1
                );

                result = self.isInversed()
                    ? abi.encode(
                        rebalanceResult.amount1Minted,
                        rebalanceResult.amount0Minted,
                        rebalanceResult.amount1Burned,
                        rebalanceResult.amount0Burned,
                        rebalanceResult.managerFee1,
                        rebalanceResult.managerFee0
                    )
                    : abi.encode(
                        rebalanceResult.amount0Minted,
                        rebalanceResult.amount1Minted,
                        rebalanceResult.amount0Burned,
                        rebalanceResult.amount1Burned,
                        rebalanceResult.managerFee0,
                        rebalanceResult.managerFee1
                    );
            }
        }

        // #region swap.

        /// @dev here we are reasonning in term of token0 and token1 of vault (not poolKey).
        if (swapPayload_.amountIn > 0) {
            IERC20Metadata _token0 =
                IArrakisLPModule(address(self)).token0();
            IERC20Metadata _token1 =
                IArrakisLPModule(address(self)).token1();

            bool isToken0Native = address(_token0) == NATIVE_COIN;
            bool isToken1Native = address(_token1) == NATIVE_COIN;

            _checkMinReturn(
                self,
                swapPayload_.zeroForOne,
                swapPayload_.expectedMinReturn,
                swapPayload_.amountIn,
                isToken0Native
                    ? NATIVE_COIN_DECIMALS
                    : _token0.decimals(),
                isToken1Native
                    ? NATIVE_COIN_DECIMALS
                    : _token1.decimals()
            );

            SwapBalances memory balances;
            {
                uint256 ethToSend;

                if (swapPayload_.zeroForOne) {
                    if (isToken0Native) {
                        pancakeVault.take(
                            Currency.wrap(address(0)),
                            address(this),
                            swapPayload_.amountIn
                        );

                        ethToSend = swapPayload_.amountIn;

                        balances.initBalance =
                            _token1.balanceOf(address(this));
                    } else {
                        pancakeVault.take(
                            Currency.wrap(address(_token0)),
                            address(this),
                            swapPayload_.amountIn
                        );

                        balances.initBalance = isToken1Native
                            ? address(this).balance
                            : _token1.balanceOf(address(this));

                        _token0.forceApprove(
                            swapPayload_.router, swapPayload_.amountIn
                        );
                    }
                } else {
                    if (isToken1Native) {
                        pancakeVault.take(
                            Currency.wrap(address(0)),
                            address(this),
                            swapPayload_.amountIn
                        );

                        ethToSend = swapPayload_.amountIn;
                        balances.initBalance =
                            _token0.balanceOf(address(this));
                    } else {
                        pancakeVault.take(
                            Currency.wrap(address(_token1)),
                            address(this),
                            swapPayload_.amountIn
                        );
                        balances.initBalance = isToken0Native
                            ? address(this).balance
                            : _token0.balanceOf(address(this));

                        _token1.forceApprove(
                            swapPayload_.router, swapPayload_.amountIn
                        );
                    }
                }

                if (
                    swapPayload_.router
                        == address(
                            IArrakisLPModule(address(self)).metaVault()
                        )
                ) {
                    revert IPancakeSwapV4StandardModule.WrongRouter();
                }

                {
                    payable(swapPayload_.router).functionCallWithValue(
                        swapPayload_.payload, ethToSend
                    );
                }

                if (swapPayload_.zeroForOne) {
                    balances.balance = (
                        isToken1Native
                            ? address(this).balance
                            : _token1.balanceOf(address(this))
                    ) - balances.initBalance;

                    if (!isToken0Native) {
                        _token0.forceApprove(swapPayload_.router, 0);
                    }

                    if (
                        swapPayload_.expectedMinReturn
                            > balances.balance
                    ) {
                        revert
                            IPancakeSwapV4StandardModule
                            .SlippageTooHigh();
                    }

                    if (balances.balance > 0) {
                        if (isToken1Native) {
                            pancakeVault.settle{
                                value: balances.balance
                            }();
                        } else {
                            pancakeVault.sync(
                                Currency.wrap(address(_token1))
                            );
                            _token1.safeTransfer(
                                address(pancakeVault),
                                balances.balance
                            );
                            pancakeVault.settle();
                        }
                    }
                } else {
                    balances.balance = (
                        isToken0Native
                            ? address(this).balance
                            : _token0.balanceOf(address(this))
                    ) - balances.initBalance;

                    if (!isToken1Native) {
                        _token1.forceApprove(swapPayload_.router, 0);
                    }

                    if (
                        swapPayload_.expectedMinReturn
                            > balances.balance
                    ) {
                        revert
                            IPancakeSwapV4StandardModule
                            .SlippageTooHigh();
                    }

                    if (balances.balance > 0) {
                        if (isToken0Native) {
                            pancakeVault.settle{
                                value: balances.balance
                            }();
                        } else {
                            pancakeVault.sync(
                                Currency.wrap(address(_token0))
                            );
                            _token0.safeTransfer(
                                address(pancakeVault),
                                balances.balance
                            );
                            pancakeVault.settle();
                        }
                    }
                }
            }
        }

        // #endregion swap.

        {
            // #region get how much left over we have on poolManager and mint.

            int256 amt0 = pancakeVault.currencyDelta(
                address(this), poolKey_.currency0
            );

            int256 amt1 = pancakeVault.currencyDelta(
                address(this), poolKey_.currency1
            );

            _rebalanceSettle(self, poolKey_, amt0, amt1);

            // #endregion get how much left over we have on poolManager and mint.
        }

        // #endregion collect and sent fees to manager.
    }

    function _collectAndSendFeesToManager(
        IVault pancakeVault_,
        PoolKey memory poolKey_,
        address manager_,
        uint256 managerFeePIPS_,
        uint256 fee0_,
        uint256 fee1_
    ) internal returns (uint256 managerFee0, uint256 managerFee1) {
        managerFee0 = FullMath.mulDiv(fee0_, managerFeePIPS_, PIPS);
        if (managerFee0 > 0) {
            pancakeVault_.take(
                poolKey_.currency0, manager_, managerFee0
            );
        }

        managerFee1 = FullMath.mulDiv(fee1_, managerFeePIPS_, PIPS);
        if (managerFee1 > 0) {
            pancakeVault_.take(
                poolKey_.currency1, manager_, managerFee1
            );
        }

        if (managerFee0 > 0 || managerFee1 > 0) {
            emit IArrakisLPModule.LogWithdrawManagerBalance(
                manager_, managerFee0, managerFee1
            );
        }
    }

    function _modifyLiquidity(
        ICLPoolManager poolManager_,
        PoolKey memory poolKey_,
        IPancakeSwapV4StandardModule.LiquidityRange[] memory
            liquidityRanges_,
        SwapPayload memory swapPayload_,
        IPancakeSwapV4StandardModule.Range[] storage ranges_,
        mapping(bytes32 => bool) storage activeRanges_
    ) internal returns (RebalanceResult memory rebalanceResult) {
        uint256 length = liquidityRanges_.length;
        for (uint256 i; i < length; i++) {
            IPancakeSwapV4StandardModule.LiquidityRange memory lrange =
                liquidityRanges_[i];

            if (lrange.liquidity > 0) {
                (BalanceDelta callerDelta, BalanceDelta feesAccrued) =
                _addLiquidity(
                    poolManager_,
                    poolKey_,
                    ranges_,
                    activeRanges_,
                    SafeCast.toUint128(
                        SafeCast.toUint256(lrange.liquidity)
                    ),
                    lrange.range.tickLower,
                    lrange.range.tickUpper
                );

                BalanceDelta principalDelta =
                    callerDelta - feesAccrued;

                /// @dev principalDelta has negative values.
                rebalanceResult.amount0Minted += SafeCast.toUint256(
                    int256(-principalDelta.amount0())
                );
                rebalanceResult.amount1Minted += SafeCast.toUint256(
                    int256(-principalDelta.amount1())
                );

                rebalanceResult.fee0 +=
                    SafeCast.toUint256(int256(feesAccrued.amount0()));
                rebalanceResult.fee1 +=
                    SafeCast.toUint256(int256(feesAccrued.amount1()));
            } else if (lrange.liquidity < 0) {
                (BalanceDelta callerDelta, BalanceDelta feesAccrued) =
                _removeLiquidity(
                    poolManager_,
                    poolKey_,
                    ranges_,
                    activeRanges_,
                    SafeCast.toUint128(
                        SafeCast.toUint256(-lrange.liquidity)
                    ),
                    lrange.range.tickLower,
                    lrange.range.tickUpper
                );

                BalanceDelta principalDelta =
                    callerDelta - feesAccrued;

                rebalanceResult.amount0Burned += SafeCast.toUint256(
                    int256(principalDelta.amount0())
                );
                rebalanceResult.amount1Burned += SafeCast.toUint256(
                    int256(principalDelta.amount1())
                );

                rebalanceResult.fee0 +=
                    SafeCast.toUint256(int256(feesAccrued.amount0()));
                rebalanceResult.fee1 +=
                    SafeCast.toUint256(int256(feesAccrued.amount1()));
            } else {
                BalanceDelta feesAccrued = _collectFee(
                    poolManager_,
                    poolKey_,
                    activeRanges_,
                    lrange.range.tickLower,
                    lrange.range.tickUpper
                );

                rebalanceResult.fee0 +=
                    SafeCast.toUint256(int256(feesAccrued.amount0()));
                rebalanceResult.fee1 +=
                    SafeCast.toUint256(int256(feesAccrued.amount1()));
            }
        }
    }

    function _rebalanceSettle(
        IPancakeSwapV4StandardModule self,
        PoolKey memory poolKey_,
        int256 amount0_,
        int256 amount1_
    ) internal {
        IVault pancakeVault = self.vault();
        if (amount0_ > 0) {
            pancakeVault.take(
                poolKey_.currency0,
                address(this),
                SafeCast.toUint256(amount0_)
            );
        } else if (amount0_ < 0) {
            uint256 valueToSend;

            if (poolKey_.currency0.isNative()) {
                valueToSend = SafeCast.toUint256(-amount0_);
            } else {
                pancakeVault.sync(poolKey_.currency0);
                IERC20Metadata(Currency.unwrap(poolKey_.currency0))
                    .safeTransfer(
                    address(pancakeVault),
                    SafeCast.toUint256(-amount0_)
                );
            }

            pancakeVault.settle{value: valueToSend}();
        }
        if (amount1_ > 0) {
            pancakeVault.take(
                poolKey_.currency1,
                address(this),
                SafeCast.toUint256(amount1_)
            );
        } else if (amount1_ < 0) {
            pancakeVault.sync(poolKey_.currency1);

            IERC20Metadata(Currency.unwrap(poolKey_.currency1))
                .safeTransfer(
                address(pancakeVault), SafeCast.toUint256(-amount1_)
            );

            pancakeVault.settle();
        }
    }

    function _collectFee(
        ICLPoolManager poolManager_,
        PoolKey memory poolKey_,
        mapping(bytes32 => bool) storage activeRanges_,
        int24 tickLower_,
        int24 tickUpper_
    ) internal returns (BalanceDelta feesAccrued) {
        bytes32 positionId = keccak256(
            abi.encode(poolKey_.toId(), tickLower_, tickUpper_)
        );

        if (!activeRanges_[positionId]) {
            revert IPancakeSwapV4StandardModule.RangeShouldBeActive(
                tickLower_, tickUpper_
            );
        }

        (, feesAccrued) = poolManager_.modifyLiquidity(
            poolKey_,
            ICLPoolManager.ModifyLiquidityParams({
                liquidityDelta: 0,
                tickLower: tickLower_,
                tickUpper: tickUpper_,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _addLiquidity(
        ICLPoolManager poolManager_,
        PoolKey memory poolKey_,
        IPancakeSwapV4StandardModule.Range[] storage ranges_,
        mapping(bytes32 => bool) storage activeRanges_,
        uint128 liquidityToAdd_,
        int24 tickLower_,
        int24 tickUpper_
    )
        internal
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        // #region effects.

        bytes32 positionId = keccak256(
            abi.encode(poolKey_.toId(), tickLower_, tickUpper_)
        );
        if (!activeRanges_[positionId]) {
            ranges_.push(
                IPancakeSwapV4StandardModule.Range({
                    tickLower: tickLower_,
                    tickUpper: tickUpper_
                })
            );
            activeRanges_[positionId] = true;
        }

        // #endregion effects.
        // #region interactions.

        (callerDelta, feesAccrued) = poolManager_.modifyLiquidity(
            poolKey_,
            ICLPoolManager.ModifyLiquidityParams({
                liquidityDelta: SafeCast.toInt256(
                    uint256(liquidityToAdd_)
                ),
                tickLower: tickLower_,
                tickUpper: tickUpper_,
                salt: bytes32(0)
            }),
            ""
        );

        // #endregion interactions.
    }

    function _removeLiquidity(
        ICLPoolManager poolManager_,
        PoolKey memory poolKey_,
        IPancakeSwapV4StandardModule.Range[] storage ranges_,
        mapping(bytes32 => bool) storage activeRanges_,
        uint128 liquidityToRemove_,
        int24 tickLower_,
        int24 tickUpper_
    )
        internal
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId poolId_ = poolKey_.toId();
        // #region get liqudity.

        uint128 liquidity = poolManager_.getLiquidity(
            poolId_, address(this), tickLower_, tickUpper_, bytes32(0)
        );

        // #endregion get liquidity.

        // #region effects.

        bytes32 positionId =
            keccak256(abi.encode(poolId_, tickLower_, tickUpper_));

        if (!activeRanges_[positionId]) {
            revert IPancakeSwapV4StandardModule.RangeShouldBeActive(
                tickLower_, tickUpper_
            );
        }

        if (liquidityToRemove_ > liquidity) {
            revert IPancakeSwapV4StandardModule.OverBurning();
        }

        if (liquidityToRemove_ == liquidity) {
            activeRanges_[positionId] = false;
            (uint256 indexToRemove, uint256 length) =
                _getRangeIndex(ranges_, tickLower_, tickUpper_);

            ranges_[indexToRemove] = ranges_[length - 1];
            ranges_.pop();
        }

        // #endregion effects.

        // #region interactions.

        (callerDelta, feesAccrued) = poolManager_.modifyLiquidity(
            poolKey_,
            ICLPoolManager.ModifyLiquidityParams({
                liquidityDelta: -SafeCast.toInt256(uint256(liquidityToRemove_)),
                tickLower: tickLower_,
                tickUpper: tickUpper_,
                salt: bytes32(0)
            }),
            ""
        );

        // #endregion interactions.
    }

    // #endregion rebalance.

    // #region withdraw.

    function withdraw(
        IPancakeSwapV4StandardModule self,
        Withdraw memory withdraw_,
        IPancakeSwapV4StandardModule.Range[] storage ranges_,
        mapping(bytes32 => bool) storage activeRanges_
    ) public returns (bytes memory result) {
        // #region get liquidity for each positions and burn.

        ICLPoolManager poolManager = self.poolManager();
        IVault pancakeVault = self.vault();
        PoolKey memory poolKey;
        (
            poolKey.currency0,
            poolKey.currency1,
            poolKey.hooks,
            poolKey.poolManager,
            poolKey.fee,
            poolKey.parameters
        ) = self.poolKey();

        {
            {
                (BalanceDelta delta, BalanceDelta fees) = _burnRanges(
                    poolKey,
                    withdraw_,
                    poolManager,
                    ranges_,
                    activeRanges_
                );

                withdraw_.amount0 =
                    SafeCast.toUint256(int256(delta.amount0()));
                withdraw_.amount1 =
                    SafeCast.toUint256(int256(delta.amount1()));
                withdraw_.fee0 =
                    SafeCast.toUint256(int256(fees.amount0()));
                withdraw_.fee1 =
                    SafeCast.toUint256(int256(fees.amount1()));
            }

            // #endregion get liquidity for each positions and burn.

            // #region get how much left over we have on poolManager and burn.

            {
                (uint256 leftOver0, uint256 leftOver1) =
                    _getLeftOvers(self, poolKey);

                // rounding up during mint only
                uint256 leftOver0ToBurn = FullMath.mulDiv(
                    leftOver0, withdraw_.proportion, BASE
                );
                uint256 leftOver1ToBurn = FullMath.mulDiv(
                    leftOver1, withdraw_.proportion, BASE
                );

                if (leftOver0ToBurn > 0) {
                    if (poolKey.currency0.isNative()) {
                        payable(withdraw_.receiver).sendValue(
                            leftOver0ToBurn
                        );
                    } else {
                        IERC20Metadata(
                            Currency.unwrap(poolKey.currency0)
                        ).safeTransfer(
                            withdraw_.receiver, leftOver0ToBurn
                        );
                    }
                }
                if (leftOver1ToBurn > 0) {
                    IERC20Metadata(Currency.unwrap(poolKey.currency1))
                        .safeTransfer(withdraw_.receiver, leftOver1ToBurn);
                }
            }
        }
        // #endregion get how much left over we have on poolManager and mint.

        // #region take and send token to receiver.

        /// @dev if receiver is a smart contract, the sm should implement receive
        /// fallback function.

        {
            IArrakisLPModule module = IArrakisLPModule(address(self));
            uint256 managerFeePIPS = module.managerFeePIPS();
            {
                uint256 managerFee0 = FullMath.mulDiv(
                    withdraw_.fee0, managerFeePIPS, PIPS
                );
                uint256 managerFee1 = FullMath.mulDiv(
                    withdraw_.fee1, managerFeePIPS, PIPS
                );

                {
                    uint256 amount0ToTake;
                    uint256 amount1ToTake;

                    /// @dev if proportion is 100% we take all fees, to prevent
                    /// rounding errors.
                    if (withdraw_.proportion == BASE) {
                        amount0ToTake =
                            withdraw_.amount0 - managerFee0;
                        amount1ToTake =
                            withdraw_.amount1 - managerFee1;
                    } else {
                        amount0ToTake = withdraw_.amount0
                            - withdraw_.fee0
                            + FullMath.mulDiv(
                                withdraw_.fee0 - managerFee0,
                                withdraw_.proportion,
                                BASE
                            );
                        amount1ToTake = withdraw_.amount1
                            - withdraw_.fee1
                            + FullMath.mulDiv(
                                withdraw_.fee1 - managerFee1,
                                withdraw_.proportion,
                                BASE
                            );
                    }

                    if (amount0ToTake > 0) {
                        pancakeVault.take(
                            poolKey.currency0,
                            withdraw_.receiver,
                            amount0ToTake
                        );

                        withdraw_.amount0 -= amount0ToTake;
                    }

                    if (amount1ToTake > 0) {
                        pancakeVault.take(
                            poolKey.currency1,
                            withdraw_.receiver,
                            amount1ToTake
                        );
                        withdraw_.amount1 -= amount1ToTake;
                    }

                    bool isInversed = self.isInversed();
                    result = isInversed
                        ? abi.encode(amount1ToTake, amount0ToTake)
                        : abi.encode(amount0ToTake, amount1ToTake);
                }

                // #region manager fees.

                address manager = module.metaVault().manager();

                if (managerFee0 > 0 || managerFee1 > 0) {
                    emit IArrakisLPModule.LogWithdrawManagerBalance(
                        manager, managerFee0, managerFee1
                    );
                }
                if (managerFee0 > 0) {
                    pancakeVault.take(
                        poolKey.currency0, manager, managerFee0
                    );

                    withdraw_.amount0 -= managerFee0;
                }
                if (managerFee1 > 0) {
                    pancakeVault.take(
                        poolKey.currency1, manager, managerFee1
                    );

                    withdraw_.amount1 -= managerFee1;
                }

                // #endregion manager fees.
            }
        }

        // #endregion take and send token to receiver.

        // #region mint extra collected fees.

        _withdrawCollectExtraFees(
            pancakeVault,
            poolKey,
            withdraw_.amount0,
            withdraw_.amount1
        );

        // #endregion mint extra collected fees.
    }

    function _burnRanges(
        PoolKey memory poolKey_,
        Withdraw memory withdraw_,
        ICLPoolManager poolManager_,
        IPancakeSwapV4StandardModule.Range[] storage ranges_,
        mapping(bytes32 => bool) storage activeRanges_
    ) internal returns (BalanceDelta delta, BalanceDelta fees) {
        uint256 length = ranges_.length;

        for (uint256 i; i < length; i++) {
            IPancakeSwapV4StandardModule.Range memory range =
                ranges_[length - 1 - i];

            uint256 liquidity;
            {
                PoolId poolId = poolKey_.toId();
                uint128 positionLiquidity = poolManager_.getLiquidity(
                    poolId,
                    address(this),
                    range.tickLower,
                    range.tickUpper,
                    bytes32(0)
                );

                /// @dev multiply -1 because we will remove liquidity.
                liquidity = FullMath.mulDiv(
                    uint256(positionLiquidity),
                    withdraw_.proportion,
                    BASE
                );

                if (liquidity == uint256(positionLiquidity)) {
                    bytes32 positionId = keccak256(
                        abi.encode(
                            poolId, range.tickLower, range.tickUpper
                        )
                    );
                    activeRanges_[positionId] = false;
                    uint256 l = ranges_.length;

                    ranges_[length - 1 - i] = ranges_[l - 1];
                    ranges_.pop();
                }
            }

            if (liquidity > 0) {
                (BalanceDelta callerDelta, BalanceDelta feesAccrued) =
                poolManager_.modifyLiquidity(
                    poolKey_,
                    ICLPoolManager.ModifyLiquidityParams({
                        liquidityDelta: -1 * SafeCast.toInt256(liquidity),
                        tickLower: range.tickLower,
                        tickUpper: range.tickUpper,
                        salt: bytes32(0)
                    }),
                    ""
                );

                delta = delta + callerDelta;
                fees = fees + feesAccrued;
            }
        }
    }

    function _withdrawCollectExtraFees(
        IVault pancakeVault_,
        PoolKey memory poolKey_,
        uint256 amount0_,
        uint256 amount1_
    ) internal {
        if (amount0_ > 0) {
            pancakeVault_.take(
                poolKey_.currency0, address(this), amount0_
            );
        }
        if (amount1_ > 0) {
            pancakeVault_.take(
                poolKey_.currency1, address(this), amount1_
            );
        }
    }

    // #endregion withdraw.

    // #region deposit.

    function deposit(
        IPancakeSwapV4StandardModule self,
        Deposit memory deposit_,
        IPancakeSwapV4StandardModule.Range[] storage ranges_
    ) public returns (bytes memory, bool) {
        PoolKey memory poolKey;
        (
            poolKey.currency0,
            poolKey.currency1,
            poolKey.hooks,
            poolKey.poolManager,
            poolKey.fee,
            poolKey.parameters
        ) = self.poolKey();
        ICLPoolManager poolManager = self.poolManager();
        IVault pancakeVault = self.vault();

        // #region get liquidity for each positions and mint.

        // #region fees computations.
        {
            // #endregion fees computations.
            uint256 length = ranges_.length;
            PoolId poolId = poolKey.toId();
            for (uint256 i; i < length; i++) {
                IPancakeSwapV4StandardModule.Range memory range =
                    ranges_[i];

                uint128 positionLiquidity = poolManager.getLiquidity(
                    poolId,
                    address(this),
                    range.tickLower,
                    range.tickUpper,
                    ""
                );

                /// @dev no need to rounding up because uni v4 should do it during minting.
                uint256 liquidity = FullMath.mulDivRoundingUp(
                    uint256(positionLiquidity),
                    deposit_.proportion,
                    BASE
                );

                if (liquidity > 0) {
                    (, BalanceDelta feesAccrued) = poolManager
                        .modifyLiquidity(
                        poolKey,
                        ICLPoolManager.ModifyLiquidityParams({
                            tickLower: range.tickLower,
                            tickUpper: range.tickUpper,
                            liquidityDelta: SafeCast.toInt256(liquidity),
                            salt: bytes32(0)
                        }),
                        ""
                    );

                    deposit_.fee0 += SafeCast.toUint256(
                        int256(feesAccrued.amount0())
                    );
                    deposit_.fee1 += SafeCast.toUint256(
                        int256(feesAccrued.amount1())
                    );
                }
            }
        }

        address manager;
        IArrakisLPModule module;

        {
            {
                // #region send manager fees.

                module = IArrakisLPModule(address(self));
                manager = module.metaVault().manager();
                uint256 _managerFeePIPS = module.managerFeePIPS();

                uint256 managerFee0 = FullMath.mulDiv(
                    deposit_.fee0, _managerFeePIPS, PIPS
                );
                uint256 managerFee1 = FullMath.mulDiv(
                    deposit_.fee1, _managerFeePIPS, PIPS
                );

                if (managerFee0 > 0) {
                    pancakeVault.take(
                        poolKey.currency0, manager, managerFee0
                    );
                }
                if (managerFee1 > 0) {
                    pancakeVault.take(
                        poolKey.currency1, manager, managerFee1
                    );
                }

                if (managerFee0 > 0 || managerFee1 > 0) {
                    emit IArrakisLPModule.LogWithdrawManagerBalance(
                        manager, managerFee0, managerFee1
                    );
                }

                // #endregion send manager fees.

                // #region mint extra collected fees.

                uint256 extraCollect0 = deposit_.fee0 - managerFee0;
                uint256 extraCollect1 = deposit_.fee1 - managerFee1;

                if (extraCollect0 > 0) {
                    pancakeVault.take(
                        poolKey.currency0,
                        address(this),
                        extraCollect0
                    );
                }
                if (extraCollect1 > 0) {
                    pancakeVault.take(
                        poolKey.currency1,
                        address(this),
                        extraCollect1
                    );
                }

                // #endregion mint extra collected fees.
            }
        }

        // #region get how much we should settle with poolManager.

        (uint256 amount0, uint256 amount1) =
            _checkCurrencyBalances(pancakeVault, poolKey);

        // #endregion get how much we should settle with poolManager.

        // #endregion get liquidity for each positions and mint.
        {
            // #region get how much left over we have on poolManager and mint.

            {
                (uint256 leftOver0, uint256 leftOver1) =
                    _getLeftOvers(self, poolKey);

                if (poolKey.currency0.isNative()) {
                    leftOver0 = leftOver0 - deposit_.value;
                }

                if (!deposit_.notFirstDeposit) {
                    if (leftOver0 > 0) {
                        if (poolKey.currency0.isNative()) {
                            payable(manager).sendValue(leftOver0);
                        } else {
                            IERC20Metadata(
                                Currency.unwrap(poolKey.currency0)
                            ).safeTransfer(manager, leftOver0);
                        }
                    }
                    if (leftOver1 > 0) {
                        IERC20Metadata(
                            Currency.unwrap(poolKey.currency1)
                        ).safeTransfer(manager, leftOver1);
                    }

                    (leftOver0, leftOver1) = module.getInits();

                    if (self.isInversed()) {
                        (leftOver0, leftOver1) =
                            (leftOver1, leftOver0);
                    }

                    deposit_.notFirstDeposit = true;
                }

                // rounding up during mint only.
                deposit_.leftOverToMint0 = FullMath.mulDivRoundingUp(
                    leftOver0, deposit_.proportion, BASE
                );
                deposit_.leftOverToMint1 = FullMath.mulDivRoundingUp(
                    leftOver1, deposit_.proportion, BASE
                );
            }

            uint256 amount0ToTransfer =
                amount0 + deposit_.leftOverToMint0;
            uint256 amount1ToTransfer =
                amount1 + deposit_.leftOverToMint1;

            if (amount0ToTransfer > 0) {
                if (!poolKey.currency0.isNative()) {
                    IERC20Metadata(Currency.unwrap(poolKey.currency0))
                        .safeTransferFrom(
                        deposit_.depositor,
                        address(this),
                        amount0ToTransfer
                    );
                }
            }

            if (amount1ToTransfer > 0) {
                IERC20Metadata(Currency.unwrap(poolKey.currency1))
                    .safeTransferFrom(
                    deposit_.depositor,
                    address(this),
                    amount1ToTransfer
                );
            }

            // #endregion get how much left over we have on poolManager and mint.
        }

        // #region settle.

        if (amount0 > 0) {
            pancakeVault.sync(poolKey.currency0);
            if (poolKey.currency0.isNative()) {
                /// @dev no need to use Address lib for PoolManager.
                pancakeVault.settle{value: amount0}();
            } else {
                IERC20Metadata(Currency.unwrap(poolKey.currency0))
                    .safeTransfer(address(pancakeVault), amount0);
                pancakeVault.settle();
            }
        }

        if (amount1 > 0) {
            /// @dev currency1 cannot be native coin because address(0).
            pancakeVault.sync(poolKey.currency1);
            IERC20Metadata(Currency.unwrap(poolKey.currency1))
                .safeTransfer(address(pancakeVault), amount1);
            pancakeVault.settle();
        }

        // #endregion settle.

        amount0 = amount0 + deposit_.leftOverToMint0;
        amount1 = amount1 + deposit_.leftOverToMint1;

        return self.isInversed()
            ? (abi.encode(amount1, amount0), deposit_.notFirstDeposit)
            : (abi.encode(amount0, amount1), deposit_.notFirstDeposit);
    }

    // #endregion deposit.

    // #region public functions underlying.

    function totalUnderlyingForMint(
        UnderlyingPayload memory underlyingPayload_,
        uint256 proportion_
    ) public view returns (uint256 amount0, uint256 amount1) {
        uint256 fee0;
        uint256 fee1;
        for (uint256 i; i < underlyingPayload_.ranges.length; i++) {
            {
                (uint256 a0, uint256 a1, uint256 f0, uint256 f1) =
                underlyingMint(
                    RangeData({
                        self: underlyingPayload_.self,
                        range: underlyingPayload_.ranges[i],
                        poolManager: underlyingPayload_.poolManager
                    }),
                    proportion_
                );
                amount0 += a0;
                amount1 += a1;
                fee0 += f0;
                fee1 += f1;
            }
        }

        uint256 managerFeePIPS =
            IArrakisLPModule(underlyingPayload_.self).managerFeePIPS();

        fee0 = fee0 - FullMath.mulDiv(fee0, managerFeePIPS, PIPS);

        fee1 = fee1 - FullMath.mulDiv(fee1, managerFeePIPS, PIPS);

        amount0 += FullMath.mulDivRoundingUp(
            proportion_, fee0 + underlyingPayload_.leftOver0, BASE
        );
        amount1 += FullMath.mulDivRoundingUp(
            proportion_, fee1 + underlyingPayload_.leftOver1, BASE
        );
    }

    function totalUnderlyingAtPriceWithFees(
        UnderlyingPayload memory underlyingPayload_,
        uint160 sqrtPriceX96_
    )
        public
        view
        returns (
            uint256 amount0,
            uint256 amount1,
            uint256 fee0,
            uint256 fee1
        )
    {
        return _totalUnderlyingWithFees(
            underlyingPayload_, sqrtPriceX96_
        );
    }

    function underlyingMint(
        RangeData memory underlying_,
        uint256 proportion_
    )
        public
        view
        returns (
            uint256 amount0,
            uint256 amount1,
            uint256 fee0,
            uint256 fee1
        )
    {
        int24 tick;
        uint160 sqrtPriceX96;
        (sqrtPriceX96, tick,,) = underlying_.poolManager.getSlot0(
            PoolIdLibrary.toId(underlying_.range.poolKey)
        );

        PositionUnderlying memory positionUnderlying =
        PositionUnderlying({
            sqrtPriceX96: sqrtPriceX96,
            poolManager: underlying_.poolManager,
            poolKey: underlying_.range.poolKey,
            self: underlying_.self,
            tick: tick,
            lowerTick: underlying_.range.lowerTick,
            upperTick: underlying_.range.upperTick
        });

        (amount0, amount1, fee0, fee1) =
            getUnderlyingBalancesMint(positionUnderlying, proportion_);
    }

    function underlying(
        RangeData memory underlying_,
        uint160 sqrtPriceX96_
    )
        public
        view
        returns (
            uint256 amount0,
            uint256 amount1,
            uint256 fee0,
            uint256 fee1
        )
    {
        int24 tick;
        if (sqrtPriceX96_ == 0) {
            (sqrtPriceX96_, tick,,) = underlying_.poolManager.getSlot0(
                PoolIdLibrary.toId(underlying_.range.poolKey)
            );
        } else {
            (, tick,,) = underlying_.poolManager.getSlot0(
                PoolIdLibrary.toId(underlying_.range.poolKey)
            );
        }

        PositionUnderlying memory positionUnderlying =
        PositionUnderlying({
            sqrtPriceX96: sqrtPriceX96_,
            poolManager: underlying_.poolManager,
            poolKey: underlying_.range.poolKey,
            self: underlying_.self,
            tick: tick,
            lowerTick: underlying_.range.lowerTick,
            upperTick: underlying_.range.upperTick
        });

        (amount0, amount1, fee0, fee1) =
            getUnderlyingBalances(positionUnderlying);
    }

    function getUnderlyingBalancesMint(
        PositionUnderlying memory positionUnderlying_,
        uint256 proportion_
    )
        public
        view
        returns (
            uint256 amount0Current,
            uint256 amount1Current,
            uint256 fee0,
            uint256 fee1
        )
    {
        PoolId poolId =
            PoolIdLibrary.toId(positionUnderlying_.poolKey);

        // compute current fees earned
        CLPosition.Info memory positionInfo;
        positionInfo = positionUnderlying_.poolManager.getPosition(
            poolId,
            positionUnderlying_.self,
            positionUnderlying_.lowerTick,
            positionUnderlying_.upperTick,
            ""
        );
        (fee0, fee1) = _getFeesEarned(
            GetFeesPayload({
                feeGrowthInside0Last: positionInfo
                    .feeGrowthInside0LastX128,
                feeGrowthInside1Last: positionInfo
                    .feeGrowthInside1LastX128,
                poolId: poolId,
                poolManager: positionUnderlying_.poolManager,
                liquidity: positionInfo.liquidity,
                tick: positionUnderlying_.tick,
                lowerTick: positionUnderlying_.lowerTick,
                upperTick: positionUnderlying_.upperTick
            })
        );

        int128 liquidity = SafeCast.toInt128(
            SafeCast.toInt256(
                FullMath.mulDivRoundingUp(
                    uint256(positionInfo.liquidity), proportion_, BASE
                )
            )
        );

        // compute current holdings from liquidity
        (amount0Current, amount1Current) = getAmountsForDelta(
            positionUnderlying_.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(positionUnderlying_.lowerTick),
            TickMath.getSqrtRatioAtTick(positionUnderlying_.upperTick),
            liquidity
        );
    }

    // solhint-disable-next-line function-max-lines
    function getUnderlyingBalances(
        PositionUnderlying memory positionUnderlying_
    )
        public
        view
        returns (
            uint256 amount0Current,
            uint256 amount1Current,
            uint256 fee0,
            uint256 fee1
        )
    {
        PoolId poolId =
            PoolIdLibrary.toId(positionUnderlying_.poolKey);

        // compute current fees earned
        CLPosition.Info memory positionInfo;
        positionInfo = positionUnderlying_.poolManager.getPosition(
            poolId,
            positionUnderlying_.self,
            positionUnderlying_.lowerTick,
            positionUnderlying_.upperTick,
            ""
        );
        (fee0, fee1) = _getFeesEarned(
            GetFeesPayload({
                feeGrowthInside0Last: positionInfo
                    .feeGrowthInside0LastX128,
                feeGrowthInside1Last: positionInfo
                    .feeGrowthInside1LastX128,
                poolId: poolId,
                poolManager: positionUnderlying_.poolManager,
                liquidity: positionInfo.liquidity,
                tick: positionUnderlying_.tick,
                lowerTick: positionUnderlying_.lowerTick,
                upperTick: positionUnderlying_.upperTick
            })
        );

        // compute current holdings from liquidity
        (amount0Current, amount1Current) = LiquidityAmounts
            .getAmountsForLiquidity(
            positionUnderlying_.sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(positionUnderlying_.lowerTick),
            TickMath.getSqrtRatioAtTick(positionUnderlying_.upperTick),
            positionInfo.liquidity
        );
    }

    function getAmountsForDelta(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        int128 liquidity
    ) public pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtRatioAX96 > sqrtRatioBX96) {
            (sqrtRatioAX96, sqrtRatioBX96) =
                (sqrtRatioBX96, sqrtRatioAX96);
        }

        if (sqrtRatioX96 < sqrtRatioAX96) {
            amount0 = SafeCast.toUint256(
                -SqrtPriceMath.getAmount0Delta(
                    sqrtRatioAX96, sqrtRatioBX96, liquidity
                )
            );
        } else if (sqrtRatioX96 < sqrtRatioBX96) {
            amount0 = SafeCast.toUint256(
                -SqrtPriceMath.getAmount0Delta(
                    sqrtRatioX96, sqrtRatioBX96, liquidity
                )
            );
            amount1 = SafeCast.toUint256(
                -SqrtPriceMath.getAmount1Delta(
                    sqrtRatioAX96, sqrtRatioX96, liquidity
                )
            );
        } else {
            amount1 = SafeCast.toUint256(
                -SqrtPriceMath.getAmount1Delta(
                    sqrtRatioAX96, sqrtRatioBX96, liquidity
                )
            );
        }
    }

    // #endregion public functions underlying.

    function _getTokens(
        IPancakeSwapV4StandardModule self,
        PoolKey memory poolKey_
    ) internal view returns (address _token0, address _token1) {
        _token0 = Currency.unwrap(poolKey_.currency0);
        _token1 = Currency.unwrap(poolKey_.currency1);
    }

    // solhint-disable-next-line function-max-lines
    function _totalUnderlyingWithFees(
        UnderlyingPayload memory underlyingPayload_,
        uint160 sqrtPriceX96_
    )
        private
        view
        returns (
            uint256 amount0,
            uint256 amount1,
            uint256 fee0,
            uint256 fee1
        )
    {
        for (uint256 i; i < underlyingPayload_.ranges.length; i++) {
            {
                (uint256 a0, uint256 a1, uint256 f0, uint256 f1) =
                underlying(
                    RangeData({
                        self: underlyingPayload_.self,
                        range: underlyingPayload_.ranges[i],
                        poolManager: underlyingPayload_.poolManager
                    }),
                    sqrtPriceX96_
                );
                amount0 += a0;
                amount1 += a1;
                fee0 += f0;
                fee1 += f1;
            }
        }

        amount0 += fee0 + underlyingPayload_.leftOver0;
        amount1 += fee1 + underlyingPayload_.leftOver1;
    }

    function _getLeftOvers(
        IPancakeSwapV4StandardModule self_,
        PoolKey memory poolKey_
    ) internal view returns (uint256 leftOver0, uint256 leftOver1) {
        leftOver0 = Currency.unwrap(poolKey_.currency0) == address(0)
            ? address(this).balance
            : IERC20Metadata(Currency.unwrap(poolKey_.currency0))
                .balanceOf(address(this));
        leftOver1 = IERC20Metadata(
            Currency.unwrap(poolKey_.currency1)
        ).balanceOf(address(this));
    }

    function _getPoolRanges(
        IPancakeSwapV4StandardModule.Range[] storage ranges_,
        PoolKey memory poolKey_
    ) internal view returns (PoolRange[] memory poolRanges) {
        uint256 length = ranges_.length;
        poolRanges = new PoolRange[](length);
        for (uint256 i; i < length; i++) {
            IPancakeSwapV4StandardModule.Range memory range =
                ranges_[i];
            poolRanges[i] = PoolRange({
                lowerTick: range.tickLower,
                upperTick: range.tickUpper,
                poolKey: poolKey_
            });
        }
    }

    function _checkTokens(
        PoolKey memory poolKey_,
        address token0_,
        address token1_,
        bool isInversed_
    ) internal pure {
        if (isInversed_) {
            /// @dev Currency.unwrap(poolKey_.currency1) == address(0) is not possible
            /// @dev because currency0 should be lower currency1.

            if (token0_ == NATIVE_COIN) {
                revert
                    IPancakeSwapV4StandardModule
                    .NativeCoinCannotBeToken1();
            } else if (Currency.unwrap(poolKey_.currency1) != token0_)
            {
                revert IPancakeSwapV4StandardModule.Currency1DtToken0(
                    Currency.unwrap(poolKey_.currency1), token0_
                );
            }

            if (token1_ == NATIVE_COIN) {
                if (Currency.unwrap(poolKey_.currency0) != address(0))
                {
                    revert
                        IPancakeSwapV4StandardModule
                        .Currency0DtToken1(
                        Currency.unwrap(poolKey_.currency0), token1_
                    );
                }
            } else if (Currency.unwrap(poolKey_.currency0) != token1_)
            {
                revert IPancakeSwapV4StandardModule.Currency0DtToken1(
                    Currency.unwrap(poolKey_.currency0), token1_
                );
            }
        } else {
            if (token0_ == NATIVE_COIN) {
                if (Currency.unwrap(poolKey_.currency0) != address(0))
                {
                    revert
                        IPancakeSwapV4StandardModule
                        .Currency0DtToken0(
                        Currency.unwrap(poolKey_.currency0), token0_
                    );
                }
            } else if (Currency.unwrap(poolKey_.currency0) != token0_)
            {
                revert IPancakeSwapV4StandardModule.Currency0DtToken0(
                    Currency.unwrap(poolKey_.currency0), token0_
                );
            }

            if (token1_ == NATIVE_COIN) {
                revert
                    IPancakeSwapV4StandardModule
                    .NativeCoinCannotBeToken1();
            } else if (Currency.unwrap(poolKey_.currency1) != token1_)
            {
                revert IPancakeSwapV4StandardModule.Currency1DtToken1(
                    Currency.unwrap(poolKey_.currency1), token1_
                );
            }
        }
    }

    function _checkPermissions(
        PoolKey memory poolKey_
    ) internal {
        if (
            poolKey_.parameters.hasOffsetEnabled(
                HOOKS_BEFORE_REMOVE_LIQUIDITY_OFFSET
            )
                || poolKey_.parameters.hasOffsetEnabled(
                    HOOKS_AFTER_REMOVE_LIQUIDITY_OFFSET
                )
                || poolKey_.parameters.hasOffsetEnabled(
                    HOOKS_AFTER_ADD_LIQUIDITY_OFFSET
                )
        ) {
            revert
                IPancakeSwapV4StandardModule
                .NoRemoveOrAddLiquidityHooks();
        }
    }

    // solhint-disable-next-line function-max-lines
    function _getFeesEarned(
        GetFeesPayload memory feeInfo_
    ) private view returns (uint256 fee0, uint256 fee1) {
        Tick.Info memory lower = feeInfo_.poolManager.getPoolTickInfo(
            feeInfo_.poolId, feeInfo_.lowerTick
        );
        Tick.Info memory upper = feeInfo_.poolManager.getPoolTickInfo(
            feeInfo_.poolId, feeInfo_.upperTick
        );

        ComputeFeesPayload memory payload = ComputeFeesPayload({
            feeGrowthInsideLast: feeInfo_.feeGrowthInside0Last,
            feeGrowthOutsideLower: lower.feeGrowthOutside0X128,
            feeGrowthOutsideUpper: upper.feeGrowthOutside0X128,
            feeGrowthGlobal: 0,
            poolId: feeInfo_.poolId,
            poolManager: feeInfo_.poolManager,
            liquidity: feeInfo_.liquidity,
            tick: feeInfo_.tick,
            lowerTick: feeInfo_.lowerTick,
            upperTick: feeInfo_.upperTick
        });

        (payload.feeGrowthGlobal,) =
            feeInfo_.poolManager.getFeeGrowthGlobals(feeInfo_.poolId);

        fee0 = _computeFeesEarned(payload);
        payload.feeGrowthInsideLast = feeInfo_.feeGrowthInside1Last;
        payload.feeGrowthOutsideLower = lower.feeGrowthOutside1X128;
        payload.feeGrowthOutsideUpper = upper.feeGrowthOutside0X128;
        (, payload.feeGrowthGlobal) =
            feeInfo_.poolManager.getFeeGrowthGlobals(feeInfo_.poolId);
        fee1 = _computeFeesEarned(payload);
    }

    function _computeFeesEarned(
        ComputeFeesPayload memory computeFees_
    ) private pure returns (uint256 fee) {
        unchecked {
            // calculate fee growth below
            uint256 feeGrowthBelow;
            if (computeFees_.tick >= computeFees_.lowerTick) {
                feeGrowthBelow = computeFees_.feeGrowthOutsideLower;
            } else {
                feeGrowthBelow = computeFees_.feeGrowthGlobal
                    - computeFees_.feeGrowthOutsideLower;
            }

            // calculate fee growth above
            uint256 feeGrowthAbove;
            if (computeFees_.tick < computeFees_.upperTick) {
                feeGrowthAbove = computeFees_.feeGrowthOutsideUpper;
            } else {
                feeGrowthAbove = computeFees_.feeGrowthGlobal
                    - computeFees_.feeGrowthOutsideUpper;
            }

            uint256 feeGrowthInside = computeFees_.feeGrowthGlobal
                - feeGrowthBelow - feeGrowthAbove;
            fee = FullMath.mulDiv(
                computeFees_.liquidity,
                feeGrowthInside - computeFees_.feeGrowthInsideLast,
                0x100000000000000000000000000000000
            );
        }
    }

    function _checkMinReturn(
        IPancakeSwapV4StandardModule self,
        bool zeroForOne_,
        uint256 expectedMinReturn_,
        uint256 amountIn_,
        uint8 decimals0_,
        uint8 decimals1_
    ) internal view {
        if (zeroForOne_) {
            if (
                FullMath.mulDiv(
                    expectedMinReturn_, 10 ** decimals0_, amountIn_
                )
                    < FullMath.mulDiv(
                        self.oracle().getPrice0(),
                        PIPS - self.maxSlippage(),
                        PIPS
                    )
            ) {
                revert
                    IPancakeSwapV4StandardModule
                    .ExpectedMinReturnTooLow();
            }
        } else {
            if (
                FullMath.mulDiv(
                    expectedMinReturn_, 10 ** decimals1_, amountIn_
                )
                    < FullMath.mulDiv(
                        self.oracle().getPrice1(),
                        PIPS - self.maxSlippage(),
                        PIPS
                    )
            ) {
                revert
                    IPancakeSwapV4StandardModule
                    .ExpectedMinReturnTooLow();
            }
        }
    }

    function _checkCurrencyBalances(
        IVault pancakeVault_,
        PoolKey memory poolKey_
    ) internal view returns (uint256, uint256) {
        int256 currency0BalanceRaw = pancakeVault_.currencyDelta(
            address(this), poolKey_.currency0
        );
        int256 currency1BalanceRaw = pancakeVault_.currencyDelta(
            address(this), poolKey_.currency1
        );
        return _checkCurrencyDelta(
            currency0BalanceRaw, currency1BalanceRaw
        );
    }

    function _checkCurrencyDelta(
        int256 currency0BalanceRaw_,
        int256 currency1BalanceRaw_
    ) internal view returns (uint256, uint256) {
        if (currency0BalanceRaw_ > 0) {
            revert IPancakeSwapV4StandardModule.InvalidCurrencyDelta();
        }
        uint256 currency0Balance =
            SafeCast.toUint256(-currency0BalanceRaw_);
        if (currency1BalanceRaw_ > 0) {
            revert IPancakeSwapV4StandardModule.InvalidCurrencyDelta();
        }
        uint256 currency1Balance =
            SafeCast.toUint256(-currency1BalanceRaw_);

        return (currency0Balance, currency1Balance);
    }

    function _getRangeIndex(
        IPancakeSwapV4StandardModule.Range[] storage ranges_,
        int24 tickLower_,
        int24 tickUpper_
    ) internal view returns (uint256, uint256) {
        uint256 length = ranges_.length;

        for (uint256 i; i < length; i++) {
            IPancakeSwapV4StandardModule.Range memory range =
                ranges_[i];
            if (
                range.tickLower == tickLower_
                    && range.tickUpper == tickUpper_
            ) {
                return (i, length);
            }
        }
    }
}
