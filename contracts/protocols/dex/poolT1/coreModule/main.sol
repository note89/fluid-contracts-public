// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import { Helpers } from "./helpers.sol";
import { SafeTransfer } from "../../../../libraries/safeTransfer.sol";
import { DexSlotsLink } from "../../../../libraries/dexSlotsLink.sol";
import { DexCalcs } from "../../../../libraries/dexCalcs.sol";
import { BigMathMinified } from "../../../../libraries/bigMathMinified.sol";
import { ErrorTypes } from "../../errorTypes.sol";
import { SafeTransfer } from "../../../../libraries/safeTransfer.sol";

/// @title FluidDexT1
/// @notice Implements core logics for Fluid Dex protocol.
/// Note Token transfers happen directly from user to Liquidity contract and vice-versa.
contract FluidDexT1 is Helpers {
    using BigMathMinified for uint256;

    function _check(uint dexVariables_, uint dexVariables2_) internal {
        if (dexVariables_ & 1 == 1) revert FluidDexError(ErrorTypes.DexT1__AlreadyEntered);
        if (dexVariables2_ & 3 == 0) revert FluidDexError(ErrorTypes.DexT1__PoolNotInitialized);
        // enabling re-entrancy
        dexVariables = dexVariables_ | 1;
    }

    /// @dev if token0 reserves are too low w.r.t token1 then revert, this is to avoid edge case scenario and making sure that precision on calculations should be high enough
    function _verifyToken0Reserves(uint token0Reserves_, uint token1Reserves_, uint centerPrice_, uint minLiquidity_) internal pure {
        if (((token0Reserves_) < (token1Reserves_ * 1e27 / (centerPrice_ * minLiquidity_)))) {
            revert FluidDexError(ErrorTypes.DexT1__TokenReservesTooLow);
        }
    }

    /// @dev if token1 reserves are too low w.r.t token0 then revert, this is to avoid edge case scenario and making sure that precision on calculations should be high enough
    function _verifyToken1Reserves(uint token0Reserves_, uint token1Reserves_, uint centerPrice_, uint minLiquidity_) internal pure {
        if (((token1Reserves_) < (token0Reserves_ * centerPrice_ / (1e27 * minLiquidity_)))) {
            revert FluidDexError(ErrorTypes.DexT1__TokenReservesTooLow);
        }
    }

    function _verifySwapAndNonPerfectActions(uint amountAdjusted_, uint amount_) internal pure {
        // after shifting amount should not become 0
        // limiting to six decimals which means in case of USDC, USDT it's 1 wei, for WBTC 100 wei, for ETH 1000 gwei
        if (
            amountAdjusted_ < SIX_DECIMALS || 
            amountAdjusted_ > X96 || 
            amount_ < TWO_DECIMALS ||
            amount_ > X128
        ) revert FluidDexError(ErrorTypes.DexT1__LimitingAmountsSwapAndNonPerfectActions);
    }

    function _verifyMint(uint amt_, uint totalAmt_) internal pure  {
        // not minting too less shares or too more
        // If totalAmt_ is worth $1 then user can at max mint $1B of new amt_ at once.
        // If totalAmt_ is worth $1B then user have to mint min of $1 of amt_.
        if (amt_ < (totalAmt_ / NINE_DECIMALS) || amt_ > (totalAmt_ * NINE_DECIMALS)) {
            revert FluidDexError(ErrorTypes.DexT1__MintAmtOverflow);
        }
    }

    function _verifyRedeem(uint amt_, uint totalAmt_) internal pure  {
        // If burning of amt_ is > 99.99% of totalAmt_ at once, then revert.
        if (amt_ > (totalAmt_ * 9999 / FOUR_DECIMALS)) {
            revert FluidDexError(ErrorTypes.DexT1__BurnAmtOverflow);
        }
    }

    /// @dev This function allows users to swap a specific amount of input tokens for output tokens
    /// @param swap0to1_ Direction of swap. If true, swaps token0 for token1; if false, swaps token1 for token0
    /// @param amountIn_ The exact amount of input tokens to swap
    /// @param amountOutMin_ The minimum amount of output tokens the user is willing to accept
    /// @param to_ Recipient of swapped tokens. If to_ == address(0) then out tokens will be sent to msg.sender. If to_ == ADDRESS_DEAD then function will revert with amountOut_
    /// @return amountOut_ The amount of output tokens received from the swap
    function swapIn(
        bool swap0to1_,
        uint256 amountIn_,
        uint256 amountOutMin_,
        address to_
    ) public payable returns (uint256 amountOut_) {
        uint dexVariables_ = dexVariables;
        uint dexVariables2_ = dexVariables2;

        if ((dexVariables2_ >> 255) == 1) revert FluidDexError(ErrorTypes.DexT1__SwapAndArbitragePaused);

        _check(dexVariables_, dexVariables2_);

        if (to_ == address(0)) to_ = msg.sender;

        SwapInMemory memory s_;

        if (swap0to1_) {
            (s_.tokenIn, s_.tokenOut) = (TOKEN_0, TOKEN_1);
            s_.amtInAdjusted = amountIn_ * TOKEN_0_NUMERATOR_PRECISION / TOKEN_0_DENOMINATOR_PRECISION;
        } else {
            (s_.tokenIn, s_.tokenOut) = (TOKEN_1, TOKEN_0);
            s_.amtInAdjusted = amountIn_ * TOKEN_1_NUMERATOR_PRECISION / TOKEN_1_DENOMINATOR_PRECISION;
        }

        _verifySwapAndNonPerfectActions(s_.amtInAdjusted, amountIn_);
        
        PricesAndExchangePrice memory pex_ = _getPricesAndExchangePrices(dexVariables_, dexVariables2_);

        if (msg.value > 0) {
            if (msg.value != amountIn_) revert FluidDexError(ErrorTypes.DexT1__EthAndAmountInMisMatch);
            if (s_.tokenIn != NATIVE_TOKEN) revert FluidDexError(ErrorTypes.DexT1__EthSentForNonNativeSwap);
        }

        // is smart collateral pool enabled
        uint temp_ = dexVariables2_ & 1;
        // is smart debt pool enabled
        uint temp2_ = (dexVariables2_ >> 1) & 1;

        uint temp3_;
        uint temp4_;

        // extracting fee
        temp3_ = ((dexVariables2_ >> 2) & X17);
        // converting revenue cut in 4 decimals, 1% = 10000
        // If fee is 1% and revenue cut is 10% then 0.1 * 10000 = 1000
        // hence revenueCut = 1e6 - 1000 = 999000
        // s_.revenueCut => 1 - revenue cut
        s_.revenueCut = SIX_DECIMALS - ((((dexVariables2_ >> 19) & X7) * temp3_) / 100);
        // 1 - fee. If fee is 1% then withoutFee will be 1e6 - 1e4
        // s_.fee => 1 - withdraw fee
        s_.fee = SIX_DECIMALS - temp3_;

        CollateralReservesSwap memory cs_;
        DebtReservesSwap memory ds_;
        if (temp_ == 1) {
            // smart collateral is enabled
            {
                CollateralReserves memory c_ = getCollateralReserves(pex_.geometricMean, pex_.upperRange, pex_.lowerRange, pex_.supplyToken0ExchangePrice, pex_.supplyToken1ExchangePrice);
                if (swap0to1_) {
                    (cs_.tokenInRealReserves, cs_.tokenOutRealReserves, cs_.tokenInImaginaryReserves, cs_.tokenOutImaginaryReserves) = 
                        (c_.token0RealReserves, c_.token1RealReserves, c_.token0ImaginaryReserves, c_.token1ImaginaryReserves);
                } else {
                    (cs_.tokenInRealReserves, cs_.tokenOutRealReserves, cs_.tokenInImaginaryReserves, cs_.tokenOutImaginaryReserves) = 
                        (c_.token1RealReserves, c_.token0RealReserves, c_.token1ImaginaryReserves, c_.token0ImaginaryReserves);
                }
            }
        }

        if (temp2_ == 1) {
            // smart debt is enabled
            {
                DebtReserves memory d_ = getDebtReserves(pex_.geometricMean, pex_.upperRange, pex_.lowerRange, pex_.borrowToken0ExchangePrice, pex_.borrowToken1ExchangePrice);
                if (swap0to1_) {
                    (ds_.tokenInDebt, ds_.tokenOutDebt, ds_.tokenInRealReserves, ds_.tokenOutRealReserves, ds_.tokenInImaginaryReserves, ds_.tokenOutImaginaryReserves) =
                        (d_.token0Debt, d_.token1Debt, d_.token0RealReserves, d_.token1RealReserves, d_.token0ImaginaryReserves, d_.token1ImaginaryReserves);
                } else {
                    (ds_.tokenInDebt, ds_.tokenOutDebt, ds_.tokenInRealReserves, ds_.tokenOutRealReserves, ds_.tokenInImaginaryReserves, ds_.tokenOutImaginaryReserves) = 
                        (d_.token1Debt, d_.token0Debt, d_.token1RealReserves, d_.token0RealReserves, d_.token1ImaginaryReserves, d_.token0ImaginaryReserves);
                }
            }
        }

        // limiting amtInAdjusted to be not more than 50% of both (collateral & debt) imaginary tokenIn reserves combined
        // basically, if this throws that means user is trying to swap 0.5x tokenIn if current tokenIn imaginary reserves is x
        // let's take x as token0 here, that means, initially the pool pricing might be:
        // token1Reserve / x and new pool pricing will become token1Reserve / 1.5x (token1Reserve will decrease after swap but for simplicity ignoring that)
        // So pool price is decreased by ~33.33% (oracle will throw error in this case as it only allows 5% price difference but better to limit it before hand)
        if (
            s_.amtInAdjusted > ((cs_.tokenInImaginaryReserves + ds_.tokenInImaginaryReserves) / 2)
        ) revert FluidDexError(ErrorTypes.DexT1__SwapInLimitingAmounts);

        if (temp_ == 1 && temp2_ == 1) {
            // unless both pools are enabled s_.swapRoutingAmt will be 0
            s_.swapRoutingAmt = _swapRoutingIn(s_.amtInAdjusted, cs_.tokenOutImaginaryReserves, cs_.tokenInImaginaryReserves, ds_.tokenOutImaginaryReserves, ds_.tokenInImaginaryReserves);
        }

        // In below if else statement temps are:
        // temp_ => deposit amt
        // temp2_ => withdraw amt
        // temp3_ => payback amt
        // temp4_ => borrow amt
        if (int(s_.amtInAdjusted) > s_.swapRoutingAmt && s_.swapRoutingAmt > 0) {
            // swap will route from the both pools
            // temp_ = amountInCol_
            temp_ = uint(s_.swapRoutingAmt);
            // temp3_ = amountInDebt_
            temp3_ = s_.amtInAdjusted - temp_;

            (temp2_, temp4_) = (0, 0);
            
            // debt pool price will be the same as collateral pool after the swap
            s_.withdrawTo = to_;
            s_.borrowTo = to_;
        } else if ((temp_ == 1 && temp2_ == 0) || (s_.swapRoutingAmt >= int(s_.amtInAdjusted))) {
            // entire swap will route through collateral pool
            (temp_, temp2_, temp3_, temp4_) = (s_.amtInAdjusted, 0, 0, 0);
            // price can slightly differ from debt pool but difference will be very small. Probably <0.01% for active DEX pools.
            s_.withdrawTo = to_;
        } else if ((temp_ == 0 && temp2_ == 1) || (s_.swapRoutingAmt <= 0)) {
            // entire swap will route through debt pool
            (temp_, temp2_, temp3_, temp4_) = (0, 0, s_.amtInAdjusted, 0);
            // price can slightly differ from collateral pool but difference will be very small. Probably <0.01% for active DEX pools.
            s_.borrowTo = to_;
        } else {
            // swap should never reach this point but if it does then reverting
            revert FluidDexError(ErrorTypes.DexT1__NoSwapRoute);
        }

        if (temp_ > 0) {
            // temp2_ = amountOutCol_
            temp2_ = _getAmountOut(((temp_ * s_.fee) / SIX_DECIMALS), cs_.tokenInImaginaryReserves, cs_.tokenOutImaginaryReserves);
            swap0to1_ ?
                _verifyToken1Reserves((cs_.tokenInRealReserves + temp_), (cs_.tokenOutRealReserves - temp2_), pex_.centerPrice, MINIMUM_LIQUIDITY_SWAP) :
                _verifyToken0Reserves((cs_.tokenOutRealReserves - temp2_), (cs_.tokenInRealReserves + temp_), pex_.centerPrice, MINIMUM_LIQUIDITY_SWAP);
        }
        if (temp3_ > 0) {
            // temp4_ = amountOutDebt_
            temp4_ = _getAmountOut(((temp3_ * s_.fee) / SIX_DECIMALS), ds_.tokenInImaginaryReserves, ds_.tokenOutImaginaryReserves);
            swap0to1_ ?
                _verifyToken1Reserves((ds_.tokenInRealReserves + temp3_), (ds_.tokenOutRealReserves - temp4_), pex_.centerPrice, MINIMUM_LIQUIDITY_SWAP) :
                _verifyToken0Reserves((ds_.tokenOutRealReserves - temp4_), (ds_.tokenInRealReserves + temp3_), pex_.centerPrice, MINIMUM_LIQUIDITY_SWAP);
        }

        // from whatever pool higher amount of swap is routing we are taking that as final price, does not matter much because both pools final price should be same
        if (temp_ > temp3_) {
            // new pool price from col pool
            s_.price = swap0to1_ ?
                ((cs_.tokenOutImaginaryReserves - temp2_) * 1e27) / (cs_.tokenInImaginaryReserves + temp_) :
                ((cs_.tokenInImaginaryReserves + temp_) * 1e27) / (cs_.tokenOutImaginaryReserves - temp2_);
        } else {
            // new pool price from debt pool
            s_.price = swap0to1_ ?
                ((ds_.tokenOutImaginaryReserves - temp4_) * 1e27) / (ds_.tokenInImaginaryReserves + temp3_) :
                ((ds_.tokenInImaginaryReserves + temp3_) * 1e27) / (ds_.tokenOutImaginaryReserves - temp4_);
        }

        // converting into normal token amounts
        if (swap0to1_) {
            temp_ = ((temp_ * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION);
            temp3_ = ((temp3_ * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION);
            temp2_ = ((temp2_ * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION);
            temp4_ = ((temp4_ * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION);
        } else {
            temp_ = ((temp_ * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION);
            temp3_ = ((temp3_ * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION);
            temp2_ = ((temp2_ * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION);
            temp4_ = ((temp4_ * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION);
        }

        amountOut_ = temp2_ + temp4_;

        // if address dead then reverting with amountOut
        if (to_ == ADDRESS_DEAD) revert FluidDexSwapResult(amountOut_);

        if (amountOut_ < amountOutMin_) revert FluidDexError(ErrorTypes.DexT1__NotEnoughAmountOut);

        // (temp_ + temp3_) == amountIn_ == msg.value (for native token), if there is revenue cut then this statement is not true
        temp_ = (temp_ * s_.revenueCut) / SIX_DECIMALS;
        temp3_ = (temp3_ * s_.revenueCut) / SIX_DECIMALS;
        // allocating to avoid stack-too-deep error
        s_.data = abi.encode(amountIn_, msg.sender);
        // deposit & payback token in at liquidity
        LIQUIDITY.operate{ value: msg.value }(s_.tokenIn, int(temp_), -int(temp3_), address(0), address(0), s_.data);
        // withdraw & borrow token out at liquidity
        LIQUIDITY.operate(s_.tokenOut, -int(temp2_), int(temp4_), s_.withdrawTo, s_.borrowTo, new bytes(0));

        // if hook exists then calling hook
        temp_ = (dexVariables2_ >> 142) & X30;
        if (temp_ > 0) {
            s_.swap0to1 = swap0to1_;
            _hookVerify(temp_, 1, s_.swap0to1, s_.price);
        }

        swap0to1_ ?
            _utilizationVerify(((dexVariables2_ >> 238) & X10), EXCHANGE_PRICE_TOKEN_1_SLOT) :
            _utilizationVerify(((dexVariables2_ >> 228) & X10), EXCHANGE_PRICE_TOKEN_0_SLOT);


        dexVariables = _updateOracle(
            s_.price,
            pex_.centerPrice,
            dexVariables_
        );

        emit Swap(swap0to1_, amountIn_, amountOut_, to_);
    }

    /// @dev Swap tokens with perfect amount out
    /// @param swap0to1_ Direction of swap. If true, swaps token0 for token1; if false, swaps token1 for token0
    /// @param amountOut_ The exact amount of tokens to receive after swap
    /// @param amountInMax_ Maximum amount of tokens to swap in
    /// @param to_ Recipient of swapped tokens. If to_ == address(0) then out tokens will be sent to msg.sender. If to_ == ADDRESS_DEAD then function will revert with amountIn_
    /// @return amountIn_ The amount of input tokens used for the swap
    function swapOut(
        bool swap0to1_,
        uint256 amountOut_,
        uint256 amountInMax_,
        address to_
    ) public payable returns (uint256 amountIn_) {
        uint dexVariables_ = dexVariables;
        uint dexVariables2_ = dexVariables2;

        if ((dexVariables2_ >> 255) == 1) revert FluidDexError(ErrorTypes.DexT1__SwapAndArbitragePaused);

        _check(dexVariables_, dexVariables2_);

        if (to_ == address(0)) to_ = msg.sender;

        SwapOutMemory memory s_;

        if (swap0to1_) {
            (s_.tokenIn, s_.tokenOut) = (TOKEN_0, TOKEN_1);
            s_.amtOutAdjusted = amountOut_ * TOKEN_1_NUMERATOR_PRECISION / TOKEN_1_DENOMINATOR_PRECISION;
        } else {
            (s_.tokenIn, s_.tokenOut) = (TOKEN_1, TOKEN_0);
            s_.amtOutAdjusted = amountOut_ * TOKEN_0_NUMERATOR_PRECISION / TOKEN_0_DENOMINATOR_PRECISION;
        }

        _verifySwapAndNonPerfectActions(s_.amtOutAdjusted, amountOut_);
        
        PricesAndExchangePrice memory pex_ = _getPricesAndExchangePrices(dexVariables_, dexVariables2_);

        if (msg.value > 0) {
            if (msg.value != amountInMax_) revert FluidDexError(ErrorTypes.DexT1__EthAndAmountInMisMatch);
            if (s_.tokenIn != NATIVE_TOKEN) revert FluidDexError(ErrorTypes.DexT1__EthSentForNonNativeSwap);
        }

        // is smart collateral pool enabled
        uint temp_ = dexVariables2_ & 1;
        // is smart debt pool enabled
        uint temp2_ = (dexVariables2_ >> 1) & 1;
        uint temp3_;
        uint temp4_;

        // extracting fee
        temp3_ = ((dexVariables2_ >> 2) & X17);
        // converting revenue cut in 4 decimals, 1% = 10000
        // If fee is 1% and revenue cut is 10% then 0.1 * 10000 = 1000
        // hence revenueCut = 1e6 - 1000 = 999000
        // s_.revenueCut => 1 - revenue cut
        s_.revenueCut = SIX_DECIMALS - ((((dexVariables2_ >> 19) & X7) * temp3_) / 100);
        // 1 - fee. If fee is 1% then withoutFee will be 1e6 - 1e4
        // s_.fee => 1 - withdraw fee
        s_.fee = SIX_DECIMALS - temp3_;

        CollateralReservesSwap memory cs_;
        DebtReservesSwap memory ds_;
        if (temp_ == 1) {
            // smart collateral is enabled
            {
                CollateralReserves memory c_ = getCollateralReserves(pex_.geometricMean, pex_.upperRange, pex_.lowerRange, pex_.supplyToken0ExchangePrice, pex_.supplyToken1ExchangePrice);
                if (swap0to1_) {
                    (cs_.tokenInRealReserves, cs_.tokenOutRealReserves, cs_.tokenInImaginaryReserves, cs_.tokenOutImaginaryReserves) = 
                        (c_.token0RealReserves, c_.token1RealReserves, c_.token0ImaginaryReserves, c_.token1ImaginaryReserves);
                } else {
                    (cs_.tokenInRealReserves, cs_.tokenOutRealReserves, cs_.tokenInImaginaryReserves, cs_.tokenOutImaginaryReserves) = 
                        (c_.token1RealReserves, c_.token0RealReserves, c_.token1ImaginaryReserves, c_.token0ImaginaryReserves);
                }
            }
        }

        if (temp2_ == 1) {
            // smart debt is enabled
            {
                DebtReserves memory d_ = getDebtReserves(pex_.geometricMean, pex_.upperRange, pex_.lowerRange, pex_.borrowToken0ExchangePrice, pex_.borrowToken1ExchangePrice);
                if (swap0to1_) {
                    (ds_.tokenInDebt, ds_.tokenOutDebt, ds_.tokenInRealReserves, ds_.tokenOutRealReserves, ds_.tokenInImaginaryReserves, ds_.tokenOutImaginaryReserves) =
                        (d_.token0Debt, d_.token1Debt, d_.token0RealReserves, d_.token1RealReserves, d_.token0ImaginaryReserves, d_.token1ImaginaryReserves);
                } else {
                    (ds_.tokenInDebt, ds_.tokenOutDebt, ds_.tokenInRealReserves, ds_.tokenOutRealReserves, ds_.tokenInImaginaryReserves, ds_.tokenOutImaginaryReserves) =
                        (d_.token1Debt, d_.token0Debt, d_.token1RealReserves, d_.token0RealReserves, d_.token1ImaginaryReserves, d_.token0ImaginaryReserves);
                }
            }
        }

        // limiting amtOutAdjusted to be not more than 50% of both (collateral & debt) imaginary tokenOut reserves combined
        // basically, if this throws that means user is trying to swap 0.5x tokenOut if current tokenOut imaginary reserves is x
        // let's take x as token0 here, that means, initially the pool pricing might be:
        // token1Reserve / x and new pool pricing will become token1Reserve / 0.5x (token1Reserve will decrease after swap but for simplicity ignoring that)
        // So pool price is increased by ~50% (oracle will throw error in this case as it only allows 5% price difference but better to limit it before hand)
        if (
            s_.amtOutAdjusted > ((cs_.tokenOutImaginaryReserves + ds_.tokenOutImaginaryReserves) / 2)
        ) revert FluidDexError(ErrorTypes.DexT1__SwapOutLimitingAmounts);

        if (temp_ == 1 && temp2_ == 1) {
            // if both pools are not enabled then s_.swapRoutingAmt will be 0
            s_.swapRoutingAmt = _swapRoutingOut(s_.amtOutAdjusted, cs_.tokenInImaginaryReserves, cs_.tokenOutImaginaryReserves, ds_.tokenInImaginaryReserves, ds_.tokenOutImaginaryReserves);
        }

        // In below if else statement temps are:
        // temp_ => withdraw amt
        // temp2_ => deposit amt
        // temp3_ => borrow amt
        // temp4_ => payback amt
        if (int(s_.amtOutAdjusted) > s_.swapRoutingAmt && s_.swapRoutingAmt > 0) {
            // swap will route from both pools
            // temp_ = amountOutCol_
            temp_ = uint(s_.swapRoutingAmt);
            // temp3_ = amountOutDebt_
            temp3_ = s_.amtOutAdjusted - temp_;

            (temp2_, temp4_) = (0, 0);
            
            // debt pool price will be the same as collateral pool after the swap
            s_.withdrawTo = to_;
            s_.borrowTo = to_;
        } else if ((temp_ == 1 && temp2_ == 0) || (s_.swapRoutingAmt >= int(s_.amtOutAdjusted))) {
            // entire swap will route through collateral pool
            (temp_, temp2_, temp3_, temp4_) = (s_.amtOutAdjusted, 0, 0, 0);
            // price can slightly differ from debt pool but difference will be very small. Probably <0.01% for active DEX pools.
            s_.withdrawTo = to_;
        } else if ((temp_ == 0 && temp2_ == 1) || (s_.swapRoutingAmt <= 0)) {
            // entire swap will route through debt pool
            (temp_, temp2_, temp3_, temp4_) = (0, 0, s_.amtOutAdjusted, 0);
            // price can slightly differ from collateral pool but difference will be very small. Probably <0.01% for active DEX pools.
            s_.borrowTo = to_;
        } else {
            // swap should never reach this point but if it does then reverting
            revert FluidDexError(ErrorTypes.DexT1__NoSwapRoute);
        }

        if (temp_ > 0) {
            // temp2_ = amountInCol_
            temp2_ = _getAmountIn(temp_, cs_.tokenInImaginaryReserves, cs_.tokenOutImaginaryReserves);
            temp2_ = (temp2_ * SIX_DECIMALS) / s_.fee;
            swap0to1_ ?
                _verifyToken1Reserves((cs_.tokenInRealReserves + temp2_), (cs_.tokenOutRealReserves - temp_), pex_.centerPrice, MINIMUM_LIQUIDITY_SWAP) :
                _verifyToken0Reserves((cs_.tokenOutRealReserves - temp_), (cs_.tokenInRealReserves + temp2_), pex_.centerPrice, MINIMUM_LIQUIDITY_SWAP);
        }
        if (temp3_ > 0) {
            // temp4_ = amountInDebt_
            temp4_ = _getAmountIn(temp3_, ds_.tokenInImaginaryReserves, ds_.tokenOutImaginaryReserves);
            temp4_ = (temp4_ * SIX_DECIMALS) / s_.fee;
            swap0to1_ ?
                _verifyToken1Reserves((ds_.tokenInRealReserves + temp4_), (ds_.tokenOutRealReserves - temp3_), pex_.centerPrice, MINIMUM_LIQUIDITY_SWAP) :
                _verifyToken0Reserves((ds_.tokenOutRealReserves - temp3_), (ds_.tokenInRealReserves + temp4_), pex_.centerPrice, MINIMUM_LIQUIDITY_SWAP);
        }

        // from whatever pool higher amount of swap is routing we are taking that as final price, does not matter much because both pools final price should be same
        if (temp_ > temp3_) {
            // new pool price from col pool
            s_.price = swap0to1_ ?
                ((cs_.tokenOutImaginaryReserves - temp_) * 1e27) / (cs_.tokenInImaginaryReserves + temp2_) :
                ((cs_.tokenInImaginaryReserves + temp2_) * 1e27) / (cs_.tokenOutImaginaryReserves - temp_);
        } else {
            // new pool price from debt pool
            s_.price = swap0to1_ ?
                ((ds_.tokenOutImaginaryReserves - temp3_) * 1e27) / (ds_.tokenInImaginaryReserves + temp4_) :
                ((ds_.tokenInImaginaryReserves + temp4_) * 1e27) / (ds_.tokenOutImaginaryReserves - temp3_);
        }
        
        // Converting into normal token amounts
        if (swap0to1_) {
            temp_ = (temp_ * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION;
            temp2_ = (temp2_ * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION;
            temp3_ = (temp3_ * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION;
            temp4_ = (temp4_ * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION;
        } else {
            temp_ = (temp_ * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION;
            temp2_ = (temp2_ * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION;
            temp3_ = (temp3_ * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION;
            temp4_ = (temp4_ * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION;
        }
        
        amountIn_ = temp2_ + temp4_;

        // If address dead then reverting with amountIn
        if (to_ == ADDRESS_DEAD) revert FluidDexSwapResult(amountIn_);

        if (amountIn_ > amountInMax_) revert FluidDexError(ErrorTypes.DexT1__ExceedsAmountInMax);

        // cutting revenue off of amount in.
        temp2_ = (temp2_ * s_.revenueCut) / SIX_DECIMALS;
        temp4_ = (temp4_ * s_.revenueCut) / SIX_DECIMALS;
        // allocating to avoid stack-too-deep error
        s_.data = abi.encode(amountIn_, msg.sender);
        // if native token then pass msg.value as amountIn_ else 0
        s_.msgValue = (s_.tokenIn == NATIVE_TOKEN) ? amountIn_ : 0;
        // Deposit & payback token in at liquidity
        LIQUIDITY.operate{ value: s_.msgValue }(s_.tokenIn, int(temp2_), -int(temp4_), address(0), address(0), s_.data);
        // Withdraw & borrow token out at liquidity
        LIQUIDITY.operate(s_.tokenOut, -int(temp_), int(temp3_), s_.withdrawTo, s_.borrowTo, new bytes(0));

        // If hook exists then calling hook
        temp_ = (dexVariables2_ >> 142) & X30;
        if (temp_ > 0) {
            s_.swap0to1 = swap0to1_;
            _hookVerify(temp_, 1, s_.swap0to1, s_.price);
        }

        swap0to1_ ?
            _utilizationVerify(((dexVariables2_ >> 238) & X10), EXCHANGE_PRICE_TOKEN_1_SLOT) :
            _utilizationVerify(((dexVariables2_ >> 228) & X10), EXCHANGE_PRICE_TOKEN_0_SLOT);

        dexVariables = _updateOracle(
            s_.price,
            pex_.centerPrice,
            dexVariables_
        );

        if (s_.tokenIn == NATIVE_TOKEN && amountIn_ < amountInMax_) {
            unchecked {
                SafeTransfer.safeTransferNative(msg.sender, amountInMax_ - amountIn_);
            }
        }

        // to avoid stack too deep error
        temp_ = amountOut_;
        emit Swap(swap0to1_, amountIn_, temp_, to_);
    }

    /// @dev Deposit tokens in equal proportion to the current pool ratio
    /// @param shares_ The number of shares to mint
    /// @param maxToken0Deposit_ Maximum amount of token0 to deposit
    /// @param maxToken1Deposit_ Maximum amount of token1 to deposit
    /// @param estimate_ If true, function will revert with estimated deposit amounts without executing the deposit
    /// @return token0Amt_ Amount of token0 deposited
    /// @return token1Amt_ Amount of token1 deposited
    function depositPerfect(
        uint shares_,
        uint maxToken0Deposit_,
        uint maxToken1Deposit_,
        bool estimate_
    ) public payable returns (uint token0Amt_, uint token1Amt_) {
        uint dexVariables_ = dexVariables;
        uint dexVariables2_ = dexVariables2;

        _check(dexVariables_, dexVariables2_);

        uint userSupplyData_ = _userSupplyData[msg.sender];

        // user collateral configs are not set yet
        if (userSupplyData_ & 1 == 0 && !estimate_) revert FluidDexError(ErrorTypes.DexT1__UserSupplyInNotOn);

        // is smart collateral pool enabled
        if ((dexVariables2_ & 1) == 1) {
            PricesAndExchangePrice memory pex_ = _getPricesAndExchangePrices(dexVariables_, dexVariables2_);

            // smart col in enabled
            uint totalSupplyShares_ = _totalSupplyShares;

            _verifyMint(shares_, totalSupplyShares_);

            // Adding col liquidity in equal proportion
            // Adding + 1, to keep protocol on the winning side
            token0Amt_ = (_getLiquidityCollateral(SUPPLY_TOKEN_0_SLOT, pex_.supplyToken0ExchangePrice, true) * shares_) / totalSupplyShares_;
            token1Amt_ = (_getLiquidityCollateral(SUPPLY_TOKEN_1_SLOT, pex_.supplyToken1ExchangePrice, false) * shares_) / totalSupplyShares_;

            // converting back into normal token amounts
            // Adding + 1, to keep protocol on the winning side
            token0Amt_ = (((token0Amt_ + 1) * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION) + 1;
            token1Amt_ = (((token1Amt_ + 1) * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION) + 1;

            if (estimate_) revert FluidDexPerfectLiquidityOutput(token0Amt_, token1Amt_);

            if (token0Amt_ > maxToken0Deposit_ || token1Amt_ > maxToken1Deposit_) {
                revert FluidDexError(ErrorTypes.DexT1__AboveDepositMax);
            }

            _depositOrPaybackInLiquidity(TOKEN_0, token0Amt_, 0);

            _depositOrPaybackInLiquidity(TOKEN_1, token1Amt_, 0);

            uint userSupply_ = (userSupplyData_ >> DexSlotsLink.BITS_USER_SUPPLY_AMOUNT) & X64;
            // extracting exisiting shares and then adding new shares in it
            userSupply_ = ((userSupply_ >> DEFAULT_EXPONENT_SIZE) << (userSupply_ & DEFAULT_EXPONENT_MASK));

            // calculate current, updated (expanded etc.) withdrawal limit
            uint256 newWithdrawalLimit_ = DexCalcs.calcWithdrawalLimitBeforeOperate(userSupplyData_, userSupply_);

            userSupply_ += shares_;

            // bigNumber the shares are not same as before
            _updatingUserSupplyDataOnStorage(userSupplyData_, userSupply_, newWithdrawalLimit_);

            // updating total shares on storage
            _totalSupplyShares = totalSupplyShares_ + shares_;
        } else {
            revert FluidDexError(ErrorTypes.DexT1__SmartColNotEnabled);
        }

        // uninitializing re-entrancy
        dexVariables = dexVariables_;

        emit LogDepositPerfectColLiquidity(shares_, token0Amt_, token1Amt_);
    }

    /// @dev This function allows users to withdraw a perfect amount of collateral liquidity
    /// @param shares_ The number of shares to withdraw
    /// @param minToken0Withdraw_ The minimum amount of token0 the user is willing to accept
    /// @param minToken1Withdraw_ The minimum amount of token1 the user is willing to accept
    /// @param estimate_ If true, the function will revert with the estimated withdrawal amounts without actually performing the withdrawal
    /// @return token0Amt_ The amount of token0 withdrawn
    /// @return token1Amt_ The amount of token1 withdrawn
    function withdrawPerfect(
        uint shares_,
        uint minToken0Withdraw_,
        uint minToken1Withdraw_,
        bool estimate_
    ) public returns (uint token0Amt_, uint token1Amt_) {
        uint dexVariables_ = dexVariables;
        uint dexVariables2_ = dexVariables2;

        _check(dexVariables_, dexVariables2_);

        uint userSupplyData_ = _userSupplyData[msg.sender];

        if (userSupplyData_ & 1 == 0 && !estimate_) {
            revert FluidDexError(ErrorTypes.DexT1__UserSupplyInNotOn);
        }

        // is smart collateral pool enabled
        if ((dexVariables2_ & 1) == 1) {
            PricesAndExchangePrice memory pex_ = _getPricesAndExchangePrices(dexVariables_, dexVariables2_);

            uint totalSupplyShares_ = _totalSupplyShares;

            _verifyRedeem(shares_, totalSupplyShares_);

            // smart col in enabled
            // Withdrawing col liquidity in equal proportion
            token0Amt_ = (_getLiquidityCollateral(SUPPLY_TOKEN_0_SLOT, pex_.supplyToken0ExchangePrice, true) * shares_) / totalSupplyShares_;
            token1Amt_ = (_getLiquidityCollateral(SUPPLY_TOKEN_1_SLOT, pex_.supplyToken1ExchangePrice, false) * shares_) / totalSupplyShares_;

            // converting back into normal token amounts
            token0Amt_ = (((token0Amt_ - 1) * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION) - 1;
            token1Amt_ = (((token1Amt_ - 1) * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION) - 1;

            if (estimate_) revert FluidDexPerfectLiquidityOutput(token0Amt_, token1Amt_);

            if (token0Amt_ < minToken0Withdraw_ || token1Amt_ < minToken1Withdraw_) {
                revert FluidDexError(ErrorTypes.DexT1__BelowWithdrawMin);
            }

            uint256 userSupply_ = (userSupplyData_ >> DexSlotsLink.BITS_USER_SUPPLY_AMOUNT) & X64;
            userSupply_ = (userSupply_ >> DEFAULT_EXPONENT_SIZE) << (userSupply_ & DEFAULT_EXPONENT_MASK);

            // calculate current, updated (expanded etc.) withdrawal limit
            uint256 newWithdrawalLimit_ = DexCalcs.calcWithdrawalLimitBeforeOperate(userSupplyData_, userSupply_);
            userSupply_ -= shares_;

            // withdraws below limit
            if (userSupply_ < newWithdrawalLimit_) revert FluidDexError(ErrorTypes.DexT1__WithdrawLimitReached);

            _updatingUserSupplyDataOnStorage(userSupplyData_, userSupply_, newWithdrawalLimit_);

            _totalSupplyShares = totalSupplyShares_ -  shares_;

            // withdraw
            // if token0Amt_ == 0 then Liqudity Layer will revert 
            LIQUIDITY.operate(TOKEN_0, -int(token0Amt_), 0, msg.sender, address(0), new bytes(0));

            // withdraw
            // if token1Amt_ == 0 then Liqudity Layer will revert 
            LIQUIDITY.operate(TOKEN_1, -int(token1Amt_), 0, msg.sender, address(0), new bytes(0));
        } else { 
            revert FluidDexError(ErrorTypes.DexT1__SmartColNotEnabled);
        }

        // uninitializing re-entrancy
        dexVariables = dexVariables_;

        emit LogWithdrawPerfectColLiquidity(shares_, token0Amt_, token1Amt_);
    }

    /// @dev This function allows users to borrow tokens in equal proportion to the current debt pool ratio
    /// @param shares_ The number of shares to borrow
    /// @param minToken0Borrow_ Minimum amount of token0 to borrow
    /// @param minToken1Borrow_ Minimum amount of token1 to borrow
    /// @param estimate_ If true, function will revert with estimated borrow amounts without executing the borrow
    /// @return token0Amt_ Amount of token0 borrowed
    /// @return token1Amt_ Amount of token1 borrowed
    function borrowPerfect(
        uint shares_,
        uint minToken0Borrow_,
        uint minToken1Borrow_,
        bool estimate_
    ) public returns (uint token0Amt_, uint token1Amt_) {
        uint dexVariables_ = dexVariables;
        uint dexVariables2_ = dexVariables2;

        _check(dexVariables_, dexVariables2_);

        uint userBorrowData_ = _userBorrowData[msg.sender]; 

        // user debt configs are not set yet
        if (userBorrowData_ & 1 == 0 && !estimate_) revert FluidDexError(ErrorTypes.DexT1__UserDebtInNotOn);

        // is smart debt pool enabled
        if (((dexVariables2_ >> 1) & 1) == 1) {
            PricesAndExchangePrice memory pex_ = _getPricesAndExchangePrices(dexVariables_, dexVariables2_);
            
            uint totalBorrowShares_ = _totalBorrowShares;

            _verifyMint(shares_, totalBorrowShares_);

            // Adding debt liquidity in equal proportion
            token0Amt_ = (_getLiquidityDebt(BORROW_TOKEN_0_SLOT, pex_.borrowToken0ExchangePrice, true) * shares_) / totalBorrowShares_;
            token1Amt_ = (_getLiquidityDebt(BORROW_TOKEN_1_SLOT, pex_.borrowToken1ExchangePrice, false) * shares_) / totalBorrowShares_;
            // converting back into normal token amounts
            token0Amt_ = (((token0Amt_ - 1) * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION) - 1;
            token1Amt_ = (((token1Amt_ - 1) * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION) - 1;

            if (estimate_) revert FluidDexPerfectLiquidityOutput(token0Amt_, token1Amt_);

            if (token0Amt_ < minToken0Borrow_ || token1Amt_ < minToken1Borrow_) {
                revert FluidDexError(ErrorTypes.DexT1__BelowBorrowMin);
            }

            // extract user borrow amount
            uint256 userBorrow_ = (userBorrowData_ >> DexSlotsLink.BITS_USER_BORROW_AMOUNT) & X64;
            userBorrow_ = (userBorrow_ >> DEFAULT_EXPONENT_SIZE) << (userBorrow_ & DEFAULT_EXPONENT_MASK);

            // calculate current, updated (expanded etc.) borrow limit
            uint256 newBorrowLimit_ = DexCalcs.calcBorrowLimitBeforeOperate(userBorrowData_, userBorrow_);

            userBorrow_ += shares_;

            // user above debt limit
            if (userBorrow_ > newBorrowLimit_) revert FluidDexError(ErrorTypes.DexT1__DebtLimitReached);

            // borrow
            // if token0Amt_ == 0 then Liqudity Layer will revert
            LIQUIDITY.operate(TOKEN_0, 0, int(token0Amt_), address(0), msg.sender, new bytes(0));

            // borrow
            // if token1Amt_ == 1 then Liqudity Layer will revert
            LIQUIDITY.operate(TOKEN_1, 0, int(token1Amt_), address(0), msg.sender, new bytes(0));

            _updatingUserBorrowDataOnStorage(userBorrowData_, userBorrow_, newBorrowLimit_);

            _totalBorrowShares = totalBorrowShares_ + shares_;
        } else {
            revert FluidDexError(ErrorTypes.DexT1__SmartDebtNotEnabled);
        }

        // uninitializing re-entrancy
        dexVariables = dexVariables_;

        emit LogBorrowPerfectDebtLiquidity(shares_, token0Amt_, token1Amt_);
    }

    /// @dev This function allows users to pay back borrowed tokens in equal proportion to the current debt pool ratio
    /// @param shares_ The number of shares to pay back
    /// @param maxToken0Payback_ Maximum amount of token0 to pay back
    /// @param maxToken1Payback_ Maximum amount of token1 to pay back
    /// @param estimate_ If true, function will revert with estimated payback amounts without executing the payback
    /// @return token0Amt_ Amount of token0 paid back
    /// @return token1Amt_ Amount of token1 paid back
    function paybackPerfect(
        uint shares_,
        uint maxToken0Payback_,
        uint maxToken1Payback_,
        bool estimate_
    ) public payable returns (uint token0Amt_, uint token1Amt_) {
        uint dexVariables_ = dexVariables;
        uint dexVariables2_ = dexVariables2;

        _check(dexVariables_, dexVariables2_);

        uint userBorrowData_ = _userBorrowData[msg.sender]; 

        if (userBorrowData_ & 1 == 0 && !estimate_) revert FluidDexError(ErrorTypes.DexT1__UserDebtInNotOn);

        // is smart debt pool enabled
        if (((dexVariables2_ >> 1) & 1) == 1) {
            uint totalBorrowShares_ = _totalBorrowShares;

            PricesAndExchangePrice memory pex_ = _getPricesAndExchangePrices(dexVariables_, dexVariables2_);

            _verifyRedeem(shares_, totalBorrowShares_);

            // Removing debt liquidity in equal proportion
            token0Amt_ = (_getLiquidityDebt(BORROW_TOKEN_0_SLOT, pex_.borrowToken0ExchangePrice, true) * shares_) / totalBorrowShares_;
            token1Amt_ = (_getLiquidityDebt(BORROW_TOKEN_1_SLOT, pex_.borrowToken1ExchangePrice, false) * shares_) / totalBorrowShares_;
            // converting back into normal token amounts
            token0Amt_ = (((token0Amt_ + 1) * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION) + 1;
            token1Amt_ = (((token1Amt_ + 1) * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION) + 1;

            if (estimate_) revert FluidDexPerfectLiquidityOutput(token0Amt_, token1Amt_);

            if (token0Amt_ > maxToken0Payback_ || token1Amt_ > maxToken1Payback_) {
                revert FluidDexError(ErrorTypes.DexT1__AbovePaybackMax);
            }

            _depositOrPaybackInLiquidity(TOKEN_0, 0, token0Amt_);

            _depositOrPaybackInLiquidity(TOKEN_1, 0, token1Amt_);

            // extract user borrow amount
            uint256 userBorrow_ = (userBorrowData_ >> DexSlotsLink.BITS_USER_BORROW_AMOUNT) & X64;
            userBorrow_ = (userBorrow_ >> DEFAULT_EXPONENT_SIZE) << (userBorrow_ & DEFAULT_EXPONENT_MASK);

            // calculate current, updated (expanded etc.) borrow limit
            uint256 newBorrowLimit_ = DexCalcs.calcBorrowLimitBeforeOperate(userBorrowData_, userBorrow_);

            userBorrow_ -= shares_;

            _updatingUserBorrowDataOnStorage(userBorrowData_, userBorrow_, newBorrowLimit_);

            _totalBorrowShares = totalBorrowShares_ - shares_;
        } else {
            revert FluidDexError(ErrorTypes.DexT1__SmartDebtNotEnabled);
        }

        // uninitializing re-entrancy
        dexVariables = dexVariables_;

        emit LogPaybackPerfectDebtLiquidity(shares_, token0Amt_, token1Amt_);
    }

    /// @dev This function allows users to deposit tokens in any proportion into the col pool
    /// @param token0Amt_ The amount of token0 to deposit
    /// @param token1Amt_ The amount of token1 to deposit
    /// @param minSharesAmt_ The minimum amount of shares the user expects to receive
    /// @param estimate_ If true, function will revert with estimated shares without executing the deposit
    /// @return shares_ The amount of shares minted for the deposit
    function deposit(
        uint token0Amt_,
        uint token1Amt_,
        uint minSharesAmt_,
        bool estimate_
    ) public payable returns (uint shares_) {
        uint dexVariables_ = dexVariables;
        uint dexVariables2_ = dexVariables2;

        _check(dexVariables_, dexVariables2_);

        uint userSupplyData_ = _userSupplyData[msg.sender];

        if (userSupplyData_ & 1 == 0 && !estimate_) revert FluidDexError(ErrorTypes.DexT1__UserSupplyInNotOn);

        // is smart collateral pool enabled
        if ((dexVariables2_ & 1) == 1) {
            PricesAndExchangePrice memory pex_ = _getPricesAndExchangePrices(dexVariables_, dexVariables2_);

            DepositColMemory memory d_;

            CollateralReserves memory c_ = getCollateralReserves(pex_.geometricMean, pex_.upperRange, pex_.lowerRange, pex_.supplyToken0ExchangePrice, pex_.supplyToken1ExchangePrice);
            CollateralReserves memory c2_ = c_;
            
            if (token0Amt_ > 0) {
                d_.token0AmtAdjusted = (((token0Amt_ - 1) * TOKEN_0_NUMERATOR_PRECISION) / TOKEN_0_DENOMINATOR_PRECISION) - 1;
                _verifySwapAndNonPerfectActions(d_.token0AmtAdjusted, token0Amt_);
                _verifyMint(d_.token0AmtAdjusted, c_.token0RealReserves);
            }

            if (token1Amt_ > 0) {
                d_.token1AmtAdjusted = (((token1Amt_ - 1) * TOKEN_1_NUMERATOR_PRECISION) / TOKEN_1_DENOMINATOR_PRECISION) - 1;
                _verifySwapAndNonPerfectActions(d_.token1AmtAdjusted, token1Amt_);
                _verifyMint(d_.token1AmtAdjusted, c_.token1RealReserves);
            }

            uint temp_;
            uint temp2_;
            
            uint totalSupplyShares_ = _totalSupplyShares;
            if ((d_.token0AmtAdjusted > 0 && d_.token1AmtAdjusted == 0) && (c_.token0RealReserves > 0) && (c_.token1RealReserves == 0)) {
                // only token0 liquidity exist and user wants to deposit token0. Hence deposit directly and mint shares.
                shares_ = d_.token0AmtAdjusted * 1e18 / c_.token0RealReserves;
                totalSupplyShares_ += shares_;
            } else if ((d_.token1AmtAdjusted > 0 && d_.token0AmtAdjusted == 0) && (c_.token1RealReserves > 0) && (c_.token0RealReserves == 0)) {
                // only token1 liquidity exist and user wants to deposit token1. Hence deposit directly and mint shares.
                shares_ = d_.token1AmtAdjusted * 1e18 / c_.token1RealReserves;
                totalSupplyShares_ += shares_;
            } else {
                if (d_.token0AmtAdjusted > 0 && d_.token1AmtAdjusted > 0) {
                    // mint shares in equal proportion
                    // temp_ => expected shares from token0 deposit
                    temp_ = d_.token0AmtAdjusted * 1e18 / c_.token0RealReserves;
                    // temp2_ => expected shares from token1 deposit
                    temp2_ = d_.token1AmtAdjusted * 1e18 / c_.token1RealReserves;
                    if (temp_ > temp2_) {
                        // use temp2_ shares
                        shares_ = (temp2_ * totalSupplyShares_) / 1e18;
                        // temp_ => token0 to swap
                        temp_ = ((temp_ - temp2_) * c_.token0RealReserves) / 1e18;
                        temp2_ = 0;
                    } else if (temp2_ > temp_) {
                        // use temp_ shares
                        shares_ = (temp_ * totalSupplyShares_) / 1e18;
                        // temp2_ => token1 to swap
                        temp2_ = ((temp2_ - temp_) * c_.token1RealReserves) / 1e18;
                        temp_ = 0;
                    } else {
                        // if equal then revert as swap will not be needed anymore which can create some issue, better to use depositPerfect in this case
                        revert FluidDexError(ErrorTypes.DexT1__InvalidDepositAmts);
                    }

                    // User deposited in equal proportion here. Hence updating col reserves and the swap will happen on updated col reserves
                    c2_ = _getUpdatedColReserves(shares_, totalSupplyShares_, c_, true);

                    totalSupplyShares_ += shares_;
                } else if (d_.token0AmtAdjusted > 0) {
                    temp_ = d_.token0AmtAdjusted;
                    temp2_ = 0;
                } else if (d_.token1AmtAdjusted > 0) {
                    temp_ = 0;
                    temp2_ = d_.token1AmtAdjusted;
                } else {
                    // user sent both amounts as 0
                    revert FluidDexError(ErrorTypes.DexT1__InvalidDepositAmts);
                }

                if (temp_ > 0) {
                    // swap token0
                    temp_ = _getSwapAndDeposit(
                        temp_, // token0 to divide and swap
                        c2_.token1ImaginaryReserves, // token1 imaginary reserves
                        c2_.token0ImaginaryReserves, // token0 imaginary reserves
                        c2_.token0RealReserves, // token0 real reserves
                        c2_.token1RealReserves // token1 real reserves
                    );
                } else if (temp2_ > 0) {
                    // swap token1
                    temp_ = _getSwapAndDeposit(
                        temp2_, // token1 to divide and swap
                        c2_.token0ImaginaryReserves, // token0 imaginary reserves
                        c2_.token1ImaginaryReserves, // token1 imaginary reserves
                        c2_.token1RealReserves, // token1 real reserves
                        c2_.token0RealReserves // token0 real reserves
                    );
                } else {
                    // maybe possible to happen due to some precision issue that both are 0
                    revert FluidDexError(ErrorTypes.DexT1__DepositAmtsZero);
                }

                // new shares minted from swap & deposit
                temp_ = temp_ * totalSupplyShares_ / 1e18;
                // adding fee in case of swap & deposit
                // 1 - fee. If fee is 1% then without fee will be 1e6 - 1e4
                // temp_ => withdraw fee
                temp_ = temp_ * (SIX_DECIMALS - ((dexVariables2_ >> 2) & X17)) / SIX_DECIMALS;
                // final new shares to mint for user
                shares_ += temp_;
                // final new collateral shares
                totalSupplyShares_ += temp_;
            }

            if (estimate_) revert FluidDexLiquidityOutput(shares_);

            if (shares_ < minSharesAmt_) revert FluidDexError(ErrorTypes.DexT1__SharesMintedLess);

            if (token0Amt_ > 0) {
                _verifyToken1Reserves((c_.token0RealReserves + d_.token0AmtAdjusted), (c_.token1RealReserves + d_.token1AmtAdjusted), pex_.centerPrice, MINIMUM_LIQUIDITY_USER_OPERATIONS);
                temp_ = token0Amt_;
                _depositOrPaybackInLiquidity(TOKEN_0, temp_, 0);
            }

            if (token1Amt_ > 0) {
                _verifyToken0Reserves((c_.token0RealReserves + d_.token0AmtAdjusted), (c_.token1RealReserves + d_.token1AmtAdjusted), pex_.centerPrice, MINIMUM_LIQUIDITY_USER_OPERATIONS);
                temp_ = token1Amt_;
                _depositOrPaybackInLiquidity(TOKEN_1, temp_, 0);
            }

            // userSupply_ => temp_
            temp_ = (userSupplyData_ >> DexSlotsLink.BITS_USER_SUPPLY_AMOUNT) & X64;
            // extracting exisiting shares and then adding new shares in it
            temp_ = ((temp_ >> DEFAULT_EXPONENT_SIZE) << (temp_ & DEFAULT_EXPONENT_MASK));

            // calculate current, updated (expanded etc.) withdrawal limit
            // newWithdrawalLimit_ => temp2_
            temp2_ = DexCalcs.calcWithdrawalLimitBeforeOperate(userSupplyData_, temp_);

            temp_ += shares_;

            _updatingUserSupplyDataOnStorage(userSupplyData_, temp_, temp2_);

            // updating total col shares in storage
            _totalSupplyShares = totalSupplyShares_;

            emit LogDepositColLiquidity(token0Amt_, token1Amt_, shares_);

            _arbitrage(dexVariables_, dexVariables2_, pex_);
        } else {
            revert FluidDexError(ErrorTypes.DexT1__SmartColNotEnabled);
        }
    }

    /// @dev This function allows users to withdraw tokens in any proportion from the col pool
    /// @param token0Amt_ The amount of token0 to withdraw
    /// @param token1Amt_ The amount of token1 to withdraw
    /// @param maxSharesAmt_ The maximum number of shares the user is willing to burn
    /// @param estimate_ If true, the function will revert with the estimated shares to burn without actually performing the withdrawal
    /// @return shares_ The number of shares burned for the withdrawal
    function withdraw(
        uint token0Amt_,
        uint token1Amt_,
        uint maxSharesAmt_,
        bool estimate_
    ) public returns (uint shares_) {
        uint dexVariables_ = dexVariables;
        uint dexVariables2_ = dexVariables2;

        _check(dexVariables_, dexVariables2_);

        uint userSupplyData_ = _userSupplyData[msg.sender];

        if (userSupplyData_ & 1 == 0 && !estimate_) revert FluidDexError(ErrorTypes.DexT1__UserSupplyInNotOn);

        // is smart collateral pool enabled
        if ((dexVariables2_ & 1) == 1) {
            PricesAndExchangePrice memory pex_ = _getPricesAndExchangePrices(dexVariables_, dexVariables2_);

            WithdrawColMemory memory w_;

            uint token0Reserves_ = _getLiquidityCollateral(SUPPLY_TOKEN_0_SLOT, pex_.supplyToken0ExchangePrice, true);
            uint token1Reserves_ = _getLiquidityCollateral(SUPPLY_TOKEN_1_SLOT, pex_.supplyToken1ExchangePrice, false);
            w_.token0ReservesInitial = token0Reserves_;
            w_.token1ReservesInitial = token1Reserves_;

            if (token0Amt_ > 0) {
                w_.token0AmtAdjusted = (((token0Amt_ + 1) * TOKEN_0_NUMERATOR_PRECISION) / TOKEN_0_DENOMINATOR_PRECISION) + 1;
                _verifySwapAndNonPerfectActions(w_.token0AmtAdjusted, token0Amt_);
                _verifyRedeem(w_.token0AmtAdjusted, token0Reserves_);
            }

            if (token1Amt_ > 0) {
                w_.token1AmtAdjusted = (((token1Amt_ + 1) * TOKEN_1_NUMERATOR_PRECISION) / TOKEN_1_DENOMINATOR_PRECISION) + 1;
                _verifySwapAndNonPerfectActions(w_.token1AmtAdjusted, token1Amt_);
                _verifyRedeem(w_.token1AmtAdjusted, token1Reserves_);
            }

            uint temp_;
            uint temp2_;

            uint totalSupplyShares_ = _totalSupplyShares;
            if ((w_.token0AmtAdjusted > 0 && w_.token1AmtAdjusted == 0) && (token0Reserves_ > 0) && (token1Reserves_ == 0)) {
                // only token0 liquidity exist and user wants to withdraw token0. Hence withdraw directly and burn shares.
                shares_ = (w_.token0AmtAdjusted * 1e18 / token0Reserves_);
                totalSupplyShares_ -= shares_;
            } else if ((w_.token1AmtAdjusted > 0 && w_.token0AmtAdjusted == 0) && (token1Reserves_ > 0) && (token0Reserves_ == 0)) {
                // only token1 liquidity exist and user wants to withdraw token1. Hence withdraw directly and burn shares.
                shares_ = (w_.token1AmtAdjusted * 1e18 / token1Reserves_);
                totalSupplyShares_ -= shares_;
            } else {
                if (w_.token0AmtAdjusted > 0 && w_.token1AmtAdjusted > 0) {
                    // mint shares in equal proportion
                    // temp_ => expected shares from token0 withdraw
                    temp_ = w_.token0AmtAdjusted * 1e18 / token0Reserves_;
                    // temp2_ => expected shares from token1 withdraw
                    temp2_ = w_.token1AmtAdjusted * 1e18 / token1Reserves_;
                    if (temp_ > temp2_) {
                        // use temp2_ shares
                        shares_ = ((temp2_ * totalSupplyShares_) / 1e18);
                        // temp_ => token0 to swap
                        temp_ = ((temp_ - temp2_) * token0Reserves_) / 1e18;
                        temp2_ = 0;
                    } else if (temp2_ > temp_) {
                        // use temp1_ shares
                        shares_ = ((temp_ * totalSupplyShares_) / 1e18);
                        // temp2_ => token1 to swap
                        temp2_ = ((temp2_ - temp_) * token1Reserves_) / 1e18;
                        temp_ = 0;
                    } else {
                        // if equal then revert as swap will not be needed anymore which can create some issue, better to use withdraw in perfect proportion for this
                        revert FluidDexError(ErrorTypes.DexT1__InvalidWithdrawAmts);
                    }

                    // User withdrew in equal proportion here. Hence updating col reserves and the swap will happen on updated col reserves
                    token0Reserves_ = token0Reserves_ - (token0Reserves_ * shares_ / totalSupplyShares_);
                    token1Reserves_ = token1Reserves_ - (token1Reserves_ * shares_ / totalSupplyShares_);
                    totalSupplyShares_ -= shares_;
                } else if (w_.token0AmtAdjusted > 0) {
                    temp_ = w_.token0AmtAdjusted;
                    temp2_ = 0;
                } else if (w_.token1AmtAdjusted > 0) {
                    temp_ = 0;
                    temp2_ = w_.token1AmtAdjusted;
                } else {
                    // user sent both amounts as 0
                    revert FluidDexError(ErrorTypes.DexT1__WithdrawAmtsZero);
                }

                uint token0ImaginaryReservesOutsideRangpex_;
                uint token1ImaginaryReservesOutsideRangpex_;

                if (pex_.geometricMean < 1e27) {
                    (token0ImaginaryReservesOutsideRangpex_, token1ImaginaryReservesOutsideRangpex_) = _calculateReservesOutsideRange(pex_.geometricMean, pex_.upperRange, (token0Reserves_ - temp_), (token1Reserves_ - temp2_));
                } else {
                    // inversing, something like `xy = k` so for calculation we are making everything related to x into y & y into x
                    // 1 / geometricMean for new geometricMean
                    // 1 / lowerRange will become upper range
                    // 1 / upperRange will become lower range
                    (token1ImaginaryReservesOutsideRangpex_, token0ImaginaryReservesOutsideRangpex_) = _calculateReservesOutsideRange((1e54 / pex_.geometricMean), (1e54 / pex_.lowerRange), (token1Reserves_ - temp2_), (token0Reserves_ - temp_));
                }

                if (temp_ > 0) {
                    // swap into token0
                    temp_ = _getWithdrawAndSwap(
                        token0Reserves_, // token0 real reserves
                        token1Reserves_, // token1 real reserves
                        token0ImaginaryReservesOutsideRangpex_, // token0 imaginary reserves
                        token1ImaginaryReservesOutsideRangpex_, // token1 imaginary reserves
                        temp_ // token0 to divide and swap into
                    );
                } else if (temp2_ > 0) {
                    // swap into token1
                    temp_ = _getWithdrawAndSwap(
                        token1Reserves_, // token1 real reserves
                        token0Reserves_, // token0 real reserves
                        token1ImaginaryReservesOutsideRangpex_, // token1 imaginary reserves
                        token0ImaginaryReservesOutsideRangpex_, // token0 imaginary reserves
                        temp2_ // token0 to divide and swap into
                    );
                } else {
                    // maybe possible to happen due to some precision issue that both are 0
                    revert FluidDexError(ErrorTypes.DexT1__WithdrawAmtsZero);
                }

                // shares to burn from withdraw & swap
                temp_ = (temp_ * totalSupplyShares_ / 1e18);
                // adding fee in case of withdraw & swap
                // 1 + fee. If fee is 1% then withdrawing withFepex_ will be 1e6 + 1e4
                temp_ = temp_ * (SIX_DECIMALS + ((dexVariables2_ >> 2) & X17)) / SIX_DECIMALS;
                // updating shares to burn for user
                shares_ += temp_;
                // final new collateral shares
                totalSupplyShares_ -= temp_;
            }

            if (estimate_) revert FluidDexLiquidityOutput(shares_);

            if (shares_ > maxSharesAmt_) revert FluidDexError(ErrorTypes.DexT1__WithdrawExcessSharesBurn);

            // userSupply_ => temp_
            temp_ = (userSupplyData_ >> DexSlotsLink.BITS_USER_SUPPLY_AMOUNT) & X64;
            temp_ = (temp_ >> DEFAULT_EXPONENT_SIZE) << (temp_ & DEFAULT_EXPONENT_MASK);

            // calculate current, updated (expanded etc.) withdrawal limit
            // newWithdrawalLimit_ => temp2_
            temp2_ = DexCalcs.calcWithdrawalLimitBeforeOperate(userSupplyData_, temp_);

            temp_ -= shares_;

            // withdrawal limit reached
            if (temp_ < temp2_) revert FluidDexError(ErrorTypes.DexT1__WithdrawLimitReached);

            _updatingUserSupplyDataOnStorage(userSupplyData_, temp_, temp2_);

            // updating total col shares in storage
            _totalSupplyShares = totalSupplyShares_;

            if (w_.token0AmtAdjusted > 0) {
                _verifyToken0Reserves((w_.token0ReservesInitial - w_.token0AmtAdjusted), (w_.token1ReservesInitial - w_.token1AmtAdjusted), pex_.centerPrice, MINIMUM_LIQUIDITY_USER_OPERATIONS);
                // withdraw
                temp_ = token0Amt_;
                LIQUIDITY.operate(TOKEN_0, -int(temp_), 0, msg.sender, address(0), new bytes(0));
            }

            if (w_.token1AmtAdjusted > 0) {
                _verifyToken1Reserves((w_.token0ReservesInitial - w_.token0AmtAdjusted), (w_.token1ReservesInitial - w_.token1AmtAdjusted), pex_.centerPrice, MINIMUM_LIQUIDITY_USER_OPERATIONS);
                // withdraw
                temp_ = token1Amt_;
                LIQUIDITY.operate(TOKEN_1, -int(temp_), 0, msg.sender, address(0), new bytes(0));
            }

            emit LogWithdrawColLiquidity(token0Amt_, token1Amt_, shares_);

            _arbitrage(dexVariables_, dexVariables2_, pex_);
        } else {
            revert FluidDexError(ErrorTypes.DexT1__SmartColNotEnabled);
        }

    }

    /// @dev This function allows users to borrow tokens in any proportion from the debt pool
    /// @param token0Amt_ The amount of token0 to borrow
    /// @param token1Amt_ The amount of token1 to borrow
    /// @param maxSharesAmt_ The maximum amount of shares the user is willing to receive
    /// @param estimate_ If true, only estimates the shares without actually borrowing
    /// @return shares_ The amount of borrow shares minted to represent the borrowed amount
    function borrow(
        uint token0Amt_,
        uint token1Amt_,
        uint maxSharesAmt_,
        bool estimate_
    ) public returns (uint shares_) {
        uint dexVariables_ = dexVariables;
        uint dexVariables2_ = dexVariables2;

        _check(dexVariables_, dexVariables2_);

        uint userBorrowData_ = _userBorrowData[msg.sender]; 

        if (userBorrowData_ & 1 == 0 && !estimate_) revert FluidDexError(ErrorTypes.DexT1__UserDebtInNotOn);

        // is smart debt pool enabled
        if (((dexVariables2_ >> 1) & 1) == 1) {
            PricesAndExchangePrice memory pex_ = _getPricesAndExchangePrices(dexVariables_, dexVariables2_);

            BorrowDebtMemory memory b_;

            uint token0Debt_ = _getLiquidityDebt(BORROW_TOKEN_0_SLOT, pex_.borrowToken0ExchangePrice, true);
            uint token1Debt_ = _getLiquidityDebt(BORROW_TOKEN_1_SLOT, pex_.borrowToken1ExchangePrice, false);
            b_.token0DebtInitial = token0Debt_;
            b_.token1DebtInitial = token1Debt_;

            if (token0Amt_ > 0) {
                b_.token0AmtAdjusted = (((token0Amt_ + 1) * TOKEN_0_NUMERATOR_PRECISION) / TOKEN_0_DENOMINATOR_PRECISION) + 1;
                _verifySwapAndNonPerfectActions(b_.token0AmtAdjusted, token0Amt_);
                _verifyMint(b_.token0AmtAdjusted, token0Debt_);
            }

            if (token1Amt_ > 0) {
                b_.token1AmtAdjusted = (((token1Amt_ + 1) * TOKEN_1_NUMERATOR_PRECISION) / TOKEN_1_DENOMINATOR_PRECISION) + 1;
                _verifySwapAndNonPerfectActions(b_.token1AmtAdjusted, token1Amt_);
                _verifyMint(b_.token1AmtAdjusted, token1Debt_);
            }

            uint temp_;
            uint temp2_;

            uint totalBorrowShares_ = _totalBorrowShares;
            if ((b_.token0AmtAdjusted > 0 && b_.token1AmtAdjusted == 0) && (token0Debt_ > 0) && (token1Debt_ == 0)) {
                // only token0 debt exist and user wants to borrow token0. Hence borrow directly and mint shares.
                shares_ = b_.token0AmtAdjusted * 1e18 / token0Debt_;
                totalBorrowShares_ += shares_;
            } else if ((b_.token1AmtAdjusted > 0 && b_.token0AmtAdjusted == 0) && (token1Debt_ > 0) && (token0Debt_ == 0)) {
                // only token1 liquidity exist and user wants to borrow token1. Hence borrow directly and mint shares.
                shares_ = b_.token1AmtAdjusted * 1e18 / token1Debt_;
                totalBorrowShares_ += shares_;
            } else {
                if (b_.token0AmtAdjusted > 0 && b_.token1AmtAdjusted > 0) {
                    // mint shares in equal proportion
                    // temp_ => expected shares from token0 payback
                    temp_ = b_.token0AmtAdjusted * 1e18 / token0Debt_;
                    // temp2_ => expected shares from token1 payback
                    temp2_ = b_.token1AmtAdjusted * 1e18 / token1Debt_;
                    if (temp_ > temp2_) {
                        // use temp2_ shares
                        shares_ = (temp2_ * totalBorrowShares_) / 1e18;
                        // temp_ => token0 to swap
                        temp_ = ((temp_ - temp2_) * token0Debt_) / 1e18;
                        temp2_ = 0;
                    } else if (temp2_ > temp_) {
                        // use temp1_ shares
                        shares_ = (temp_ * totalBorrowShares_) / 1e18;
                        // temp2_ => token1 to swap
                        temp2_ = ((temp2_ - temp_) * token1Debt_) / 1e18;
                        temp_ = 0;
                    } else {
                        // if equal then revert as swap will not be needed anymore which can create some issue, better to use perfect borrow in this case
                        revert FluidDexError(ErrorTypes.DexT1__InvalidBorrowAmts);
                    }

                    // User borrowed in equal proportion here. Hence updating col reserves and the swap will happen on updated col reserves
                    token0Debt_ = token0Debt_ + token0Debt_ * shares_ / totalBorrowShares_;
                    token1Debt_ = token1Debt_ + token1Debt_ * shares_ / totalBorrowShares_;
                    totalBorrowShares_ += shares_;
                } else if (b_.token0AmtAdjusted > 0) {
                    temp_ = b_.token0AmtAdjusted;
                    temp2_ = 0;
                } else if (b_.token1AmtAdjusted > 0) {
                    temp_ = 0;
                    temp2_ = b_.token1AmtAdjusted;
                } else {
                    // user sent both amounts as 0
                    revert FluidDexError(ErrorTypes.DexT1__InvalidBorrowAmts);
                }

                uint token0FinalImaginaryReserves_;
                uint token1FinalImaginaryReserves_;

                if (pex_.geometricMean < 1e27) {
                    (, , token0FinalImaginaryReserves_, token1FinalImaginaryReserves_) = 
                        _calculateDebtReserves(pex_.geometricMean, pex_.lowerRange, (token0Debt_ + temp_), (token1Debt_ + temp2_));
                } else {
                    // inversing, something like `xy = k` so for calculation we are making everything related to x into y & y into x
                    // 1 / geometricMean for new geometricMean
                    // 1 / lowerRange will become upper range
                    // 1 / upperRange will become lower range
                    (, , token1FinalImaginaryReserves_, token0FinalImaginaryReserves_) = 
                        _calculateDebtReserves((1e54 / pex_.geometricMean), (1e54 / pex_.upperRange), (token1Debt_ + temp2_), (token0Debt_ + temp_));
                }

                if (temp_ > 0) {
                    // swap into token0
                    temp_ = _getBorrowAndSwap(
                        token0Debt_, // token0 debt
                        token1Debt_, // token1 debt
                        token0FinalImaginaryReserves_, // token0 imaginary reserves
                        token1FinalImaginaryReserves_, // token1 imaginary reserves
                        temp_ // token0 to divide and swap into
                    );
                } else if (temp2_ > 0) {
                    // swap into token1
                    temp_ = _getBorrowAndSwap(
                        token1Debt_, // token1 debt
                        token0Debt_, // token0 debt
                        token1FinalImaginaryReserves_, // token1 imaginary reserves
                        token0FinalImaginaryReserves_, // token0 imaginary reserves
                        temp2_ // token1 to divide and swap into
                    );
                } else {
                    // maybe possible to happen due to some precision issue that both are 0
                    revert FluidDexError(ErrorTypes.DexT1__BorrowAmtsZero);
                }

                // new shares to mint from borrow & swap
                temp_ = temp_ * totalBorrowShares_ / 1e18;
                // adding fee in case of borrow & swap
                // 1 + fee. If fee is 1% then withdrawing withFepex_ will be 1e6 + 1e4
                temp_ = temp_ * (SIX_DECIMALS + ((dexVariables2_ >> 2) & X17)) / SIX_DECIMALS;
                // final new shares to mint for user
                shares_ += temp_;
                // final new debt shares
                totalBorrowShares_ += temp_;
            }

            if (estimate_) revert FluidDexLiquidityOutput(shares_);

            if (shares_ > maxSharesAmt_) revert FluidDexError(ErrorTypes.DexT1__BorrowExcessSharesMinted);

            // extract user borrow amount
            // userBorrow_ => temp_
            temp_ = (userBorrowData_ >> DexSlotsLink.BITS_USER_BORROW_AMOUNT) & X64;
            temp_ = (temp_ >> DEFAULT_EXPONENT_SIZE) << (temp_ & DEFAULT_EXPONENT_MASK);

            // calculate current, updated (expanded etc.) borrow limit
            // newBorrowLimit_ => temp2_
            temp2_ = DexCalcs.calcBorrowLimitBeforeOperate(userBorrowData_, temp_);

            temp_ += shares_;

            // user above debt limit
            if (temp_ > temp2_) revert FluidDexError(ErrorTypes.DexT1__DebtLimitReached);

            _updatingUserBorrowDataOnStorage(userBorrowData_, temp_, temp2_);

            if (b_.token0AmtAdjusted > 0) {
                // comparing debt here rather than reserves to simply code, impact won't be much overall
                _verifyToken1Reserves((b_.token0DebtInitial + b_.token0AmtAdjusted), (b_.token1DebtInitial + b_.token1AmtAdjusted), pex_.centerPrice, MINIMUM_LIQUIDITY_USER_OPERATIONS);
                // assigning token0Amt_ to temp_ to avoid compilation error (I don't know why it's throwing when using token0Amt_ directly)
                temp_ = token0Amt_;
                // borrow
                LIQUIDITY.operate(TOKEN_0, 0, int(temp_), address(0), msg.sender, new bytes(0));
            }

            if (b_.token1AmtAdjusted > 0) {
                // comparing debt here rather than reserves to simply code, impact won't be much overall
                _verifyToken0Reserves((b_.token0DebtInitial + b_.token0AmtAdjusted), (b_.token1DebtInitial + b_.token1AmtAdjusted), pex_.centerPrice, MINIMUM_LIQUIDITY_USER_OPERATIONS);
                // assigning token1Amt_ to temp_ to avoid compilation error (I don't know why it's throwing when using token0Amt_ directly)
                temp_ = token1Amt_;
                // borrow
                LIQUIDITY.operate(TOKEN_1, 0, int(temp_), address(0), msg.sender, new bytes(0));
            }

            // updating total debt shares in storage
            _totalBorrowShares = totalBorrowShares_;
            
            emit LogBorrowDebtLiquidity(token0Amt_, token1Amt_, shares_);

            _arbitrage(dexVariables_, dexVariables2_, pex_);
        } else {
            revert FluidDexError(ErrorTypes.DexT1__SmartDebtNotEnabled);
        }

    }

    /// @dev This function allows users to payback tokens in any proportion to the debt pool
    /// @param token0Amt_ The amount of token0 to payback
    /// @param token1Amt_ The amount of token1 to payback
    /// @param minSharesAmt_ The minimum amount of shares the user expects to burn
    /// @param estimate_ If true, function will revert with estimated shares without executing the payback
    /// @return shares_ The amount of borrow shares burned for the payback
    function payback(
        uint token0Amt_,
        uint token1Amt_,
        uint minSharesAmt_,
        bool estimate_
    ) public payable returns (uint shares_) {
        uint dexVariables_ = dexVariables;
        uint dexVariables2_ = dexVariables2;

        _check(dexVariables_, dexVariables2_);
        
        uint userBorrowData_ = _userBorrowData[msg.sender]; 

        if (userBorrowData_ & 1 == 0 && !estimate_) revert FluidDexError(ErrorTypes.DexT1__UserDebtInNotOn);


        // is smart debt pool enabled
        if (((dexVariables2_ >> 1) & 1) == 1) {
            PricesAndExchangePrice memory pex_ = _getPricesAndExchangePrices(dexVariables_, dexVariables2_);

            PaybackDebtMemory memory p_;
            
            DebtReserves memory d_ = getDebtReserves(pex_.geometricMean, pex_.upperRange, pex_.lowerRange, pex_.borrowToken0ExchangePrice, pex_.borrowToken1ExchangePrice);
            DebtReserves memory d2_ = d_;

            if (token0Amt_ > 0) {
                p_.token0AmtAdjusted = (((token0Amt_ - 1) * TOKEN_0_NUMERATOR_PRECISION) / TOKEN_0_DENOMINATOR_PRECISION) - 1;
                _verifySwapAndNonPerfectActions(p_.token0AmtAdjusted, token0Amt_);
                _verifyRedeem(p_.token0AmtAdjusted, d_.token0Debt);
            }

            if (token1Amt_ > 0) {
                p_.token1AmtAdjusted = (((token1Amt_ - 1) * TOKEN_1_NUMERATOR_PRECISION) / TOKEN_1_DENOMINATOR_PRECISION) - 1;
                _verifySwapAndNonPerfectActions(p_.token1AmtAdjusted, token1Amt_);
                _verifyRedeem(p_.token1AmtAdjusted, d_.token1Debt);
            }

            uint temp_;
            uint temp2_;

            uint totalBorrowShares_ = _totalBorrowShares;
            if ((p_.token0AmtAdjusted > 0 && p_.token1AmtAdjusted == 0) && (d_.token0Debt > 0) && (d_.token1Debt == 0)) {
                // only token0 debt exist and user wants to payback token0. Hence payback directly and burn shares.
                shares_ = (p_.token0AmtAdjusted * 1e18 / d_.token0Debt);
                totalBorrowShares_ -= shares_;
            } else if ((p_.token1AmtAdjusted > 0 && p_.token0AmtAdjusted == 0) && (d_.token1Debt > 0) && (d_.token0Debt == 0)) {
                // only token1 liquidity exist and user wants to payback token1. Hence payback directly and burn shares.
                shares_ = (p_.token1AmtAdjusted * 1e18 / d_.token1Debt);
                totalBorrowShares_ -= shares_;
            } else {
                if (p_.token0AmtAdjusted > 0 && p_.token1AmtAdjusted > 0) {
                    // burn shares in equal proportion
                    // temp_ => expected shares from token0 payback
                    temp_ = p_.token0AmtAdjusted * 1e18 / d_.token0Debt;
                    // temp2_ => expected shares from token1 payback
                    temp2_ = p_.token1AmtAdjusted * 1e18 / d_.token1Debt;
                    if (temp_ > temp2_) {
                        // use temp2_ shares
                        shares_ = ((temp2_ * totalBorrowShares_) / 1e18);
                        // temp_ => token0 to swap
                        temp_ = p_.token0AmtAdjusted - (temp2_ * p_.token0AmtAdjusted) / temp_;
                        temp2_ = 0;
                    } else if (temp2_ > temp_) {
                        // use temp_ shares
                        shares_ = ((temp_ * totalBorrowShares_) / 1e18);
                        // temp2_ => token1 to swap
                        temp2_ = p_.token1AmtAdjusted - ((temp_ * p_.token1AmtAdjusted) / temp2_); // to this
                        temp_ = 0;
                    } else {
                        // if equal then revert as swap will not be needed anymore which can create some issue, better to use perfect payback in this case
                        revert FluidDexError(ErrorTypes.DexT1__InvalidPaybackAmts);
                    }

                    // User paid back in equal proportion here. Hence updating debt reserves and the swap will happen on updated debt reserves
                    d2_ = _getUpdateDebtReserves(
                        shares_,
                        totalBorrowShares_,
                        d_,
                        false // true if mint, false if burn
                    );
                    totalBorrowShares_ -= shares_;
                } else if (p_.token0AmtAdjusted > 0) {
                    temp_ = p_.token0AmtAdjusted;
                    temp2_ = 0;
                } else if (p_.token1AmtAdjusted > 0) {
                    temp_ = 0;
                    temp2_ = p_.token1AmtAdjusted;
                } else {
                    // user sent both amounts as 0
                    revert FluidDexError(ErrorTypes.DexT1__InvalidPaybackAmts);
                }

                if (temp_ > 0) {
                    // swap token0 into token1 and payback equally
                    temp_ = _getSwapAndPayback(
                        d2_.token0Debt,
                        d2_.token1Debt,
                        d2_.token0ImaginaryReserves,
                        d2_.token1ImaginaryReserves,
                        temp_
                    );
                } else if (temp2_ > 0) {
                    // swap token1 into token0 and payback equally
                    temp_ = _getSwapAndPayback(
                        d2_.token1Debt,
                        d2_.token0Debt,
                        d2_.token1ImaginaryReserves,
                        d2_.token0ImaginaryReserves,
                        temp2_
                    );
                } else {
                    // maybe possible to happen due to some precision issue that both are 0
                    revert FluidDexError(ErrorTypes.DexT1__PaybackAmtsZero);
                }

                // new shares to burn from payback & swap
                temp_ = (temp_ * totalBorrowShares_ / 1e18);

                // adding fee in case of payback & swap
                // 1 - fee. If fee is 1% then withdrawing withFepex_ will be 1e6 - 1e4
                temp_ = temp_ * (SIX_DECIMALS - ((dexVariables2_ >> 2) & X17)) / SIX_DECIMALS;
                // final shares to burn for user
                shares_ += temp_;
                // final new debt shares
                totalBorrowShares_ -= temp_;
            }

            if (estimate_) revert FluidDexLiquidityOutput(shares_);

            if (shares_ < minSharesAmt_) revert FluidDexError(ErrorTypes.DexT1__PaybackSharedBurnedLess);

            if (token0Amt_ > 0) {
                // comparing debt here rather than reserves to simply code, impact won't be much overall
                _verifyToken0Reserves((d_.token0Debt - p_.token0AmtAdjusted), (d_.token1Debt - p_.token1AmtAdjusted), pex_.centerPrice, MINIMUM_LIQUIDITY_USER_OPERATIONS);
                // payback
                temp_ = token0Amt_;
                _depositOrPaybackInLiquidity(TOKEN_0, 0, temp_);
            }

            if (token1Amt_ > 0) {
                // comparing debt here rather than reserves to simply code, impact won't be much overall
                _verifyToken1Reserves((d_.token0Debt - p_.token0AmtAdjusted), (d_.token1Debt - p_.token1AmtAdjusted), pex_.centerPrice, MINIMUM_LIQUIDITY_USER_OPERATIONS);
                // payback
                temp_ = token1Amt_;
                _depositOrPaybackInLiquidity(TOKEN_1, 0, temp_);
            }

            // extract user borrow amount
            // userBorrow_ => temp_
            temp_ = (userBorrowData_ >> DexSlotsLink.BITS_USER_BORROW_AMOUNT) & X64;
            temp_ = (temp_ >> DEFAULT_EXPONENT_SIZE) << (temp_ & DEFAULT_EXPONENT_MASK);

            // calculate current, updated (expanded etc.) borrow limit
            // newBorrowLimit_ => temp2_
            temp2_ = DexCalcs.calcBorrowLimitBeforeOperate(userBorrowData_, temp_);
        
            temp_ -= shares_;

            _updatingUserBorrowDataOnStorage(userBorrowData_, temp_, temp2_);
            // updating total debt shares in storage
            _totalBorrowShares = totalBorrowShares_;

            emit LogPaybackDebtLiquidity(token0Amt_, token1Amt_, shares_);

            _arbitrage(dexVariables_, dexVariables2_, pex_);
        } else {
            revert FluidDexError(ErrorTypes.DexT1__SmartDebtNotEnabled);
        }
    }

    /// @dev This function allows users to withdraw their collateral with perfect shares in one token
    /// @param shares_ The number of shares to burn for withdrawal
    /// @param minToken0_ The minimum amount of token0 the user expects to receive (set to 0 if withdrawing in token1)
    /// @param minToken1_ The minimum amount of token1 the user expects to receive (set to 0 if withdrawing in token0)
    /// @param estimate_ If true, the function will revert with the estimated withdrawal amount without executing the withdrawal
    /// @return withdrawAmt_ The amount of tokens withdrawn in the chosen token
    function withdrawPerfectInOneToken(
        uint shares_,
        uint minToken0_,
        uint minToken1_,
        bool estimate_
    ) public returns (uint withdrawAmt_) {
        uint dexVariables_ = dexVariables;
        uint dexVariables2_ = dexVariables2;

        _check(dexVariables_, dexVariables2_);

        uint userSupplyData_ = _userSupplyData[msg.sender];

        if (userSupplyData_ & 1 == 0 && !estimate_) {
            revert FluidDexError(ErrorTypes.DexT1__UserSupplyInNotOn);
        }

        if ((minToken0_ > 0 && minToken1_ > 0) || (minToken0_ == 0 && minToken1_ == 0)) {
            // only 1 token should be > 0
            revert FluidDexError(ErrorTypes.DexT1__InvalidWithdrawAmts);
        }

        // is smart collateral pool enabled
        if ((dexVariables2_ & 1) == 1) {
            PricesAndExchangePrice memory pex_ = _getPricesAndExchangePrices(dexVariables_, dexVariables2_);

            uint totalSupplyShares_ = _totalSupplyShares;

            _verifyRedeem(shares_, totalSupplyShares_);

            uint token0Amt_;
            uint token1Amt_;

            CollateralReserves memory c_ = getCollateralReserves(pex_.geometricMean, pex_.upperRange, pex_.lowerRange, pex_.supplyToken0ExchangePrice, pex_.supplyToken1ExchangePrice);
            CollateralReserves memory c2_ = _getUpdatedColReserves(shares_, totalSupplyShares_, c_, false);
            // Storing exact token0 & token1 raw/adjusted withdrawal amount after burning shares
            token0Amt_ = c_.token0RealReserves - c2_.token0RealReserves - 1;
            token1Amt_ = c_.token1RealReserves - c2_.token1RealReserves - 1;

            if (minToken0_ > 0) {
                // user wants to withdraw entirely in token0, hence swapping token1 into token0
                token0Amt_ += _getAmountOut(token1Amt_, c2_.token1ImaginaryReserves, c2_.token0ImaginaryReserves);
                token1Amt_ = 0;
                _verifyToken0Reserves((c_.token0RealReserves - token0Amt_), c_.token1RealReserves, pex_.centerPrice, MINIMUM_LIQUIDITY_USER_OPERATIONS);

                // converting token0Amt_ from raw/adjusted to normal token amount
                token0Amt_ = (((token0Amt_ - 1) * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION) - 1;

                // deducting fee on withdrawing in 1 token
                token0Amt_ = token0Amt_ * (SIX_DECIMALS - ((dexVariables2_ >> 2) & X17)) / SIX_DECIMALS;

                withdrawAmt_ = token0Amt_;
                if (estimate_) revert FluidDexSingleTokenOutput(withdrawAmt_);
                if (withdrawAmt_ < minToken0_) revert FluidDexError(ErrorTypes.DexT1__WithdrawalNotEnough);
            } else {
                // user wants to withdraw entirely in token1, hence swapping token0 into token1
                token1Amt_ += _getAmountOut(token0Amt_, c2_.token0ImaginaryReserves, c2_.token1ImaginaryReserves);
                token0Amt_ = 0;
                _verifyToken1Reserves(c_.token0RealReserves, (c_.token1RealReserves - token1Amt_), pex_.centerPrice, MINIMUM_LIQUIDITY_USER_OPERATIONS);

                // converting token1Amt_ from raw/adjusted to normal token amount
                token1Amt_ = (((token1Amt_ - 1) * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION) - 1;

                // deducting fee on withdrawing in 1 token
                token1Amt_ = token1Amt_ * (SIX_DECIMALS - ((dexVariables2_ >> 2) & X17)) / SIX_DECIMALS;

                withdrawAmt_ = token1Amt_;
                if (estimate_) revert FluidDexSingleTokenOutput(withdrawAmt_);
                if (withdrawAmt_ < minToken1_) revert FluidDexError(ErrorTypes.DexT1__WithdrawalNotEnough);
            }

            uint256 userSupply_ = (userSupplyData_ >> DexSlotsLink.BITS_USER_SUPPLY_AMOUNT) & X64;
            userSupply_ = (userSupply_ >> DEFAULT_EXPONENT_SIZE) << (userSupply_ & DEFAULT_EXPONENT_MASK);

            // calculate current, updated (expanded etc.) withdrawal limit
            // temp_ => newWithdrawalLimit_
            uint256 temp_ = DexCalcs.calcWithdrawalLimitBeforeOperate(userSupplyData_, userSupply_);

            userSupply_ -= shares_;

            // withdraws below limit
            if (userSupply_ < temp_) revert FluidDexError(ErrorTypes.DexT1__WithdrawLimitReached);

            _updatingUserSupplyDataOnStorage(userSupplyData_, userSupply_, temp_);

            _totalSupplyShares = totalSupplyShares_ -  shares_;

            if (minToken0_ > 0) {
                // withdraw
                LIQUIDITY.operate(TOKEN_0, -int(token0Amt_), 0, msg.sender, address(0), new bytes(0));
            } else {
                // withdraw
                LIQUIDITY.operate(TOKEN_1, -int(token1Amt_), 0, msg.sender, address(0), new bytes(0));
            }

            // to avoid stack-too-deep error 
            temp_ = shares_;
            emit LogWithdrawColInOneToken(temp_, token0Amt_, token1Amt_);

            _arbitrage(dexVariables_, dexVariables2_, pex_);
        } else {
            revert FluidDexError(ErrorTypes.DexT1__SmartColNotEnabled);
        }
    }

    /// @dev This function allows users to payback their debt with perfect shares in one token
    /// @param shares_ The number of shares to burn for payback
    /// @param maxToken0_ The maximum amount of token0 the user is willing to pay (set to 0 if paying back in token1)
    /// @param maxToken1_ The maximum amount of token1 the user is willing to pay (set to 0 if paying back in token0)
    /// @param estimate_ If true, the function will revert with the estimated payback amount without executing the payback
    /// @return paybackAmt_ The amount of tokens paid back in the chosen token
    function paybackPerfectInOneToken(
        uint shares_,
        uint maxToken0_,
        uint maxToken1_,
        bool estimate_
    ) public payable returns (uint paybackAmt_) {
        uint dexVariables_ = dexVariables;
        uint dexVariables2_ = dexVariables2;

        _check(dexVariables_, dexVariables2_);

        uint userBorrowData_ = _userBorrowData[msg.sender]; 

        if (userBorrowData_ & 1 == 0 && !estimate_) revert FluidDexError(ErrorTypes.DexT1__UserDebtInNotOn);

        if ((maxToken0_ > 0 && maxToken1_ > 0) || (maxToken0_ == 0 && maxToken1_ == 0)) {
            // only 1 token should be > 0
            revert FluidDexError(ErrorTypes.DexT1__InvalidWithdrawAmts);
        }

        // is smart debt pool enabled
        if (((dexVariables2_ >> 1) & 1) == 1) {
            PricesAndExchangePrice memory pex_ = _getPricesAndExchangePrices(dexVariables_, dexVariables2_);

            uint totalBorrowShares_ = _totalBorrowShares;

            _verifyRedeem(shares_, totalBorrowShares_);

            uint token0Amt_;
            uint token1Amt_;

            // smart debt in enabled
            DebtReserves memory d_ = getDebtReserves(pex_.geometricMean, pex_.upperRange, pex_.lowerRange, pex_.borrowToken0ExchangePrice, pex_.borrowToken1ExchangePrice);
            // Removing debt liquidity in equal proportion
            DebtReserves memory d2_ = _getUpdateDebtReserves(shares_, totalBorrowShares_, d_, false);

            if (maxToken0_ > 0) {
                // entire payback is in token0_
                token0Amt_ = _getSwapAndPaybackOneTokenPerfectShares(
                    d2_.token0ImaginaryReserves,
                    d2_.token1ImaginaryReserves,
                    d_.token0Debt,
                    d_.token1Debt,
                    d2_.token0RealReserves,
                    d2_.token1RealReserves
                );
                _verifyToken0Reserves((d_.token0Debt - token0Amt_), d_.token1Debt, pex_.centerPrice, MINIMUM_LIQUIDITY_USER_OPERATIONS);

                // converting from raw/adjusted to normal token amounts
                token0Amt_ = (((token0Amt_ + 1) * TOKEN_0_DENOMINATOR_PRECISION) / TOKEN_0_NUMERATOR_PRECISION) + 1;

                // adding fee on paying back in 1 token
                token0Amt_ = token0Amt_ * (SIX_DECIMALS + ((dexVariables2_ >> 2) & X17)) / SIX_DECIMALS;

                paybackAmt_ = token0Amt_;
                if (estimate_) revert FluidDexSingleTokenOutput(paybackAmt_);
                if (paybackAmt_ > maxToken0_) revert FluidDexError(ErrorTypes.DexT1__PaybackAmtTooHigh);
                _depositOrPaybackInLiquidity(TOKEN_0, 0, paybackAmt_);
            } else {
                // entire payback is in token1_
                token1Amt_ = _getSwapAndPaybackOneTokenPerfectShares(
                    d2_.token1ImaginaryReserves,
                    d2_.token0ImaginaryReserves,
                    d_.token1Debt,
                    d_.token0Debt,
                    d2_.token1RealReserves,
                    d2_.token0RealReserves
                );
                _verifyToken1Reserves(d_.token0Debt, (d_.token1Debt - token1Amt_), pex_.centerPrice, MINIMUM_LIQUIDITY_USER_OPERATIONS);
                
                // converting from raw/adjusted to normal token amounts
                token1Amt_ = (((token1Amt_ + 1) * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION) + 1;

                // adding fee on paying back in 1 token
                token1Amt_ = token1Amt_ * (SIX_DECIMALS + ((dexVariables2_ >> 2) & X17)) / SIX_DECIMALS;

                paybackAmt_ = token1Amt_;
                if (estimate_) revert FluidDexSingleTokenOutput(paybackAmt_);
                if (paybackAmt_ > maxToken1_) revert FluidDexError(ErrorTypes.DexT1__PaybackAmtTooHigh);
                _depositOrPaybackInLiquidity(TOKEN_1, 0, paybackAmt_);
            }

            // extract user borrow amount
            uint256 userBorrow_ = (userBorrowData_ >> DexSlotsLink.BITS_USER_BORROW_AMOUNT) & X64;
            userBorrow_ = (userBorrow_ >> DEFAULT_EXPONENT_SIZE) << (userBorrow_ & DEFAULT_EXPONENT_MASK);

            // calculate current, updated (expanded etc.) borrow limit
            // temp_ => newBorrowLimit_
            uint256 temp_ = DexCalcs.calcBorrowLimitBeforeOperate(userBorrowData_, userBorrow_);
            userBorrow_ -= shares_;

            _updatingUserBorrowDataOnStorage(userBorrowData_, userBorrow_, temp_);

            _totalBorrowShares = totalBorrowShares_ - shares_;

            // to avoid stack-too-deep error 
            temp_ = shares_;
            emit LogPaybackDebtInOneToken(temp_, token0Amt_, token1Amt_);

            _arbitrage(dexVariables_, dexVariables2_, pex_);
        } else {
            revert FluidDexError(ErrorTypes.DexT1__SmartDebtNotEnabled);
        }
    }

    /// @dev This function performs arbitrage between the collateral and debt pools
    /// @param dexVariables_ The current state of dex variables
    /// @param dexVariables2_ Additional dex variables
    /// @param pex_ Struct containing prices and exchange rates
    /// @notice This function is called after user operations to balance the pools
    /// @notice It swaps tokens between the collateral and debt pools to align their prices
    /// @notice The function updates the oracle price based on the arbitrage results
    function _arbitrage(uint dexVariables_, uint dexVariables2_, PricesAndExchangePrice memory pex_) private {
        if ((dexVariables2_ >> 255) == 1) revert FluidDexError(ErrorTypes.DexT1__SwapAndArbitragePaused);

        CollateralReserves memory c_;
        DebtReserves memory d_;
        uint price_;
        if ((dexVariables2_ & 1) == 1) {
            c_ = getCollateralReserves(pex_.geometricMean, pex_.upperRange, pex_.lowerRange, pex_.supplyToken0ExchangePrice, pex_.supplyToken1ExchangePrice);
        }
        if ((dexVariables2_ & 2) == 2) {
            d_ = getDebtReserves(pex_.geometricMean, pex_.upperRange, pex_.lowerRange, pex_.borrowToken0ExchangePrice, pex_.borrowToken1ExchangePrice);
        }
        if ((dexVariables2_ & 3) < 3) {
            price_ = ((dexVariables2_ & 1) == 1) ?
                ((c_.token1ImaginaryReserves) * 1e27) / (c_.token0ImaginaryReserves) :
                ((d_.token1ImaginaryReserves) * 1e27) / (d_.token0ImaginaryReserves);
            // arbitrage should only happen if both smart debt & smart collateral are enabled
            // Storing in storage, it will also uninitialize re-entrancy
            dexVariables = _updateOracle(
                price_,
                pex_.centerPrice,
                dexVariables_
            );
            return;
        }

        uint temp_;
        uint amtOut_;
        uint amtIn_;

        // both smart debt & smart collateral enabled

        // always swapping token0 into token1
        int a_ = _swapRoutingIn(0, c_.token1ImaginaryReserves, c_.token0ImaginaryReserves, d_.token1ImaginaryReserves, d_.token0ImaginaryReserves);
        if (a_ > 0) {
            // swap will route through col pool
            temp_ = uint(a_);
            amtOut_ = _getAmountOut(temp_ , c_.token0ImaginaryReserves, c_.token1ImaginaryReserves);
            amtIn_ = _getAmountIn(temp_ , d_.token1ImaginaryReserves, d_.token0ImaginaryReserves);

            // new pool price
            // debt pool price will be the same as collateral pool after the swap
            // note: updating price here as in next line amtOut_ will get updated to normal amounts
            price_ = ((c_.token1ImaginaryReserves - amtOut_) * 1e27) / (c_.token0ImaginaryReserves + temp_);

            // converting into normal token form from DEX precisions
            a_ = (((a_) * int(TOKEN_0_DENOMINATOR_PRECISION)) / int(TOKEN_0_NUMERATOR_PRECISION));
            amtOut_ = (((amtOut_) * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION);
            amtIn_ = (((amtIn_) * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION);

            // deposit token0 and borrow token0
            // withdraw token1 and payback token1
            LIQUIDITY.operate(TOKEN_0, a_, a_, address(0), address(this), abi.encode(SKIP_TRANSFERS, address(this)));
            LIQUIDITY.operate(TOKEN_1, -int(amtOut_), -int(amtIn_), address(this), address(0), abi.encode(SKIP_TRANSFERS, address(this)));
        } else if (a_ < 0) {
            // swap will route through debt pool
            temp_ = uint(-a_);
            amtOut_ = _getAmountOut(temp_ , d_.token0ImaginaryReserves, d_.token1ImaginaryReserves);
            amtIn_ = _getAmountIn(temp_ , c_.token1ImaginaryReserves, c_.token0ImaginaryReserves);

            // new pool price
            // debt pool price will be the same as collateral pool after the swap
            // note: updating price here as in next line amtOut_ will get updated to normal amounts
            price_ = ((d_.token1ImaginaryReserves - amtOut_) * 1e27) / (d_.token0ImaginaryReserves + temp_);

            // converting into normal token form from DEX precisions
            a_ = ((a_ * int(TOKEN_0_DENOMINATOR_PRECISION)) / int(TOKEN_0_NUMERATOR_PRECISION));
            amtOut_ = ((amtOut_ * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION);
            amtIn_ = (((amtIn_) * TOKEN_1_DENOMINATOR_PRECISION) / TOKEN_1_NUMERATOR_PRECISION);

            // payback token0 and withdraw token0
            // deposit token1 and borrow token1
            LIQUIDITY.operate(TOKEN_0, a_, a_, address(this), address(0), abi.encode(SKIP_TRANSFERS, address(this)));
            LIQUIDITY.operate(TOKEN_1, int(amtIn_), int(amtOut_), address(0), address(this), abi.encode(SKIP_TRANSFERS, address(this)));
        } else {
            // reverting if nothing to arbitrage. Naturally to get here will have very low probability
            revert FluidDexError(ErrorTypes.DexT1__NothingToArbitrage);
        }

        // if hook exists then calling hook
        temp_ = (dexVariables2_ >> 142) & X30;
        if (temp_ > 0) {
            uint lastPrice_ = (dexVariables_ >> 41) & X40;
            lastPrice_ = (lastPrice_ >> DEFAULT_EXPONENT_SIZE) << (lastPrice_ & DEFAULT_EXPONENT_MASK);
            _hookVerify(temp_, 2, lastPrice_ > price_, price_);
        }

        // Storing in storage, it will also uninitialize re-entrancy
        dexVariables = _updateOracle(
            price_,
            pex_.centerPrice,
            dexVariables_
        );

        emit LogArbitrage(a_, amtOut_);
    }

    /// @dev liquidity callback for cheaper token transfers in case of deposit or payback.
    /// only callable by Liquidity during an operation.
    function liquidityCallback(address token_, uint amount_, bytes calldata data_) external {
        if (msg.sender != address(LIQUIDITY)) revert FluidDexError(ErrorTypes.DexT1__MsgSenderNotLiquidity);
        if (dexVariables & 1 == 0) revert FluidDexError(ErrorTypes.DexT1__ReentrancyBitShouldBeOn);

        if (data_.length == 64) {
            (uint amountWithRevenueCut_, address from_) = abi.decode(data_, (uint, address));
            // not checking if amountWithRevenueCut_ > amount_, because it will be and if it's less than liquidity layer will throw.
            SafeTransfer.safeTransferFrom(token_, from_, address(LIQUIDITY), amountWithRevenueCut_);
        } else {
            SafeTransfer.safeTransferFrom(token_, abi.decode(data_, (address)), address(LIQUIDITY), amount_);
        }
    }

    /// @dev the oracle assumes last set price of pool till the next swap happens.
    /// There's a possibility that during that time some interest is generated hence the last stored price is not the 100% correct price for the whole duration
    /// but the difference due to interest will be super low so this difference is ignored
    /// For example 2 swaps happened 10min (600 seconds) apart and 1 token has 10% higher interest than other.
    /// then that token will accrue about 10% * 600 / secondsInAYear = ~0.0002%
    /// @param secondsAgos_ array of seconds ago for which TWAP is needed. If user sends [10, 30, 60] then twaps_ will return [10-0, 30-10, 60-30]
    /// @return twaps_ twap price, lowest price (aka minima) & highest price (aka maxima) between secondsAgo checkpoints
    /// @return currentPrice_ price of pool after the most recent swap
    function oraclePrice(
        uint[] memory secondsAgos_
    ) external view returns (
        Oracle[] memory twaps_,
        uint currentPrice_
    ) {
        OraclePriceMemory memory o_;

        uint dexVariables_ = dexVariables;
        twaps_ = new Oracle[](secondsAgos_.length);

        uint totalTime_;
        uint time_;

        uint i;
        uint secondsAgo_ = secondsAgos_[0];

        currentPrice_ = (dexVariables_ >> 41) & X40;
        currentPrice_ = (currentPrice_ >> DEFAULT_EXPONENT_SIZE) << (currentPrice_ & DEFAULT_EXPONENT_MASK);
        uint price_ = currentPrice_;
        o_.lowestPrice1by0 = currentPrice_;
        o_.highestPrice1by0 = currentPrice_;

        uint twap1by0_;
        uint twap0by1_;

        uint j;

        o_.oracleSlot = (dexVariables_ >> 176) & X3;
        o_.oracleMap = (dexVariables_ >> 179) & X16;
        // if o_.oracleSlot == 7 then it'll enter the if statement in the below while loop
        o_.oracle = o_.oracleSlot < 7 ? _oracle[o_.oracleMap] : 0;

        uint slotData_;
        uint percentDiff_;

        if (((dexVariables_ >> 121) & X33) < block.timestamp) {
            // last swap didn't occured in this block.
            // hence last price is current price of pool & also the last price
            time_ = block.timestamp - ((dexVariables_ >> 121) & X33);
        } else {
            // last swap occured in this block, that means current price is active for 0 secs. Hence TWAP for it will be 0.
            ++j;
        }
        
        while (true) {
            if (j == 2) {
                if (++o_.oracleSlot == 8) { 
                    o_.oracleSlot = 0;
                    if (o_.oracleMap == 0) {
                        o_.oracleMap = TOTAL_ORACLE_MAPPING;
                    }
                    o_.oracle = _oracle[--o_.oracleMap]; 
                }

                slotData_ = o_.oracle >> (o_.oracleSlot * 32) & X32; 
                if (slotData_ > 0) {
                    time_ = slotData_ & X9;
                    if (time_ == 0) {
                        // time is in precision & sign bits
                        time_ = slotData_ >> 9;
                        // if o_.oracleSlot is 7 then precision & bits and stored in 1 less map
                        if (o_.oracleSlot == 7) {
                            o_.oracleSlot = 0;
                            if (o_.oracleMap == 0) {
                                o_.oracleMap = TOTAL_ORACLE_MAPPING;
                            }
                            o_.oracle = _oracle[--o_.oracleMap];
                            slotData_ = o_.oracle & X32;
                        } else {
                            ++o_.oracleSlot;
                            slotData_ = o_.oracle >> (o_.oracleSlot * 32) & X32;
                        }
                    }
                    percentDiff_ = slotData_ >> 10;
                    percentDiff_ = ORACLE_LIMIT * percentDiff_ / X22;
                    if (((slotData_ >> 9) & 1 == 1)) {
                        // if positive then old price was lower than current hence subtracting
                        price_ = price_ - price_ * percentDiff_ / ORACLE_PRECISION;
                    } else {
                        // if negative then old price was higher than current hence adding
                        price_ = price_ + price_ * percentDiff_ / ORACLE_PRECISION;
                    }
                } else {
                    // oracle data does not exist. Probably due to pool recently got initialized and not have much swaps.
                    revert FluidDexError(ErrorTypes.DexT1__InsufficientOracleData);
                }
            } else if (j == 1) {
                // last & last to last price
                price_ = (dexVariables_ >> 1) & X40;
                price_ = (price_ >> DEFAULT_EXPONENT_SIZE) << (price_ & DEFAULT_EXPONENT_MASK);
                time_ = (dexVariables_ >> 154) & X22;
                ++j;
            } else if (j == 0) {
                ++j;
            }

            totalTime_ += time_;
            if (o_.lowestPrice1by0 > price_) o_.lowestPrice1by0 = price_;
            if (o_.highestPrice1by0 < price_) o_.highestPrice1by0 = price_;
            if (totalTime_ < secondsAgo_) {
                twap1by0_ += price_ * time_;
                twap0by1_ += (1e54 / price_) * time_;
            } else {
                time_ = time_ + secondsAgo_ - totalTime_;
                twap1by0_ += price_ * time_;
                twap0by1_ += (1e54 / price_) * time_;
                // also auto checks that secondsAgos_ should not be == 0
                twap1by0_ = twap1by0_ / secondsAgo_;
                twap0by1_ = twap0by1_ / secondsAgo_;

                twaps_[i] = Oracle(twap1by0_, o_.lowestPrice1by0, o_.highestPrice1by0, twap0by1_ , (1e54 / o_.highestPrice1by0), (1e54 / o_.lowestPrice1by0));

                // TWAP for next secondsAgo will start with price_
                o_.lowestPrice1by0 = price_;
                o_.highestPrice1by0 = price_;

                while (++i < secondsAgos_.length) {
                    // secondsAgo_ = [60, 15, 0]
                    time_ = totalTime_ - secondsAgo_;
                    // updating total time as new seconds ago started
                    totalTime_ = time_;
                    // also auto checks that secondsAgos_[i + 1] > secondsAgos_[i]
                    secondsAgo_ = secondsAgos_[i] - secondsAgos_[i - 1];
                    if (totalTime_ < secondsAgo_) {
                        twap1by0_ = price_ * time_;
                        twap0by1_ = (1e54 / price_) * time_;
                        // if time_ comes out as 0 here then lowestPrice & highestPrice should not be price_, it should be next price_ that we will calculate
                        if (time_ == 0) {
                            o_.lowestPrice1by0 = type(uint).max;
                            o_.highestPrice1by0 = 0;
                        }
                        break;
                    } else {
                        time_ = time_ + secondsAgo_ - totalTime_;
                        // twap1by0_ = price_ here
                        twap1by0_ = price_ * time_;
                        // twap0by1_ = (1e54 / price_) * time_;
                        twap0by1_ = (1e54 / price_) * time_;
                        twap1by0_ = twap1by0_ / secondsAgo_;
                        twap0by1_ = twap0by1_ / secondsAgo_;
                        twaps_[i] = Oracle(twap1by0_, o_.lowestPrice1by0, o_.highestPrice1by0, twap0by1_ , (1e54 / o_.highestPrice1by0), (1e54 / o_.lowestPrice1by0));
                    }
                }
                if (i == secondsAgos_.length) return (twaps_, currentPrice_); // oracle fetch over
            }
        }
        
    }

    function getPricesAndExchangePrices() public {
        uint dexVariables_ = dexVariables;
        uint dexVariables2_ = dexVariables2;

        _check(dexVariables_, dexVariables2_);

        PricesAndExchangePrice memory pex_ = _getPricesAndExchangePrices(dexVariables, dexVariables2);

        revert FluidDexPricesAndExchangeRates(pex_);
    }

    constructor(ConstantViews memory constantViews_) Helpers(constantViews_) {}

    /// @dev Internal fallback function to handle calls to non-existent functions
    /// @notice This function is called when a transaction is sent to the contract without matching any other function
    /// @notice It checks if the caller is authorized, enables re-entrancy protection, delegates the call to the admin implementation, and then disables re-entrancy protection
    /// @notice Only authorized callers (global or dex auth) can trigger this function
    /// @notice This function uses assembly to perform a delegatecall to the admin implementation to update configs related to DEX
    function _fallback() private {
        if (!(DEX_FACTORY.isGlobalAuth(msg.sender) || DEX_FACTORY.isDexAuth(address(this), msg.sender))) {
            revert FluidDexError(ErrorTypes.DexT1__NotAnAuth);
        }

        uint dexVariables_ = dexVariables;
        if (dexVariables_ & 1 == 1) revert FluidDexError(ErrorTypes.DexT1__AlreadyEntered);
        // enabling re-entrancy
        dexVariables = dexVariables_ | 1;

        // Delegate the current call to `ADMIN_IMPLEMENTATION`.
        _spell(ADMIN_IMPLEMENTATION, msg.data);

        // disabling re-entrancy
        // directly fetching from storage so updates from Admin module will get auto covered
        dexVariables = dexVariables & ~uint(1);
    }

    fallback() external payable {
        _fallback();
    }

    receive() external payable {
        if (msg.sig != 0x00000000) {
            _fallback();
        }
    }

    /// @dev            do any arbitrary call
    /// @param target_  Address to which the call needs to be delegated
    /// @param data_    Data to execute at the delegated address
    function _spell(address target_, bytes memory data_) private returns (bytes memory response_) {
        assembly {
            let succeeded := delegatecall(gas(), target_, add(data_, 0x20), mload(data_), 0, 0)
            let size := returndatasize()

            response_ := mload(0x40)
            mstore(0x40, add(response_, and(add(add(size, 0x20), 0x1f), not(0x1f))))
            mstore(response_, size)
            returndatacopy(add(response_, 0x20), 0, size)

            if iszero(succeeded) {
                // throw if delegatecall failed
                returndatacopy(0x00, 0x00, size)
                revert(0x00, size)
            }
        }
    }
}
