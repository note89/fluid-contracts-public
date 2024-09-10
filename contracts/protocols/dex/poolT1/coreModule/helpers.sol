// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";

import { Variables } from "../common/variables.sol";
import { ImmutableVariables } from "./immutableVariables.sol";
import { Events } from "./events.sol";
import { ErrorTypes } from "../../errorTypes.sol";
import { IHook, ICenterPrice } from "./interfaces.sol";
import { LiquiditySlotsLink } from "../../../../libraries/liquiditySlotsLink.sol";
import { LiquidityCalcs } from "../../../../libraries/liquidityCalcs.sol";
import { DexSlotsLink } from "../../../../libraries/dexSlotsLink.sol";
import { DexCalcs } from "../../../../libraries/dexCalcs.sol";
import { SafeTransfer } from "../../../../libraries/safeTransfer.sol";
import { BigMathMinified } from "../../../../libraries/bigMathMinified.sol";
import { AddressCalcs } from "../../../../libraries/addressCalcs.sol";

abstract contract Helpers is Variables, ImmutableVariables, Events {
    using BigMathMinified for uint256;

    /// @dev Given an input amount of asset and pair reserves, returns the maximum output amount of the other asset
    /// @param amountIn_ The amount of input asset.
    /// @param iReserveIn_ Imaginary token reserve with input amount.
    /// @param iReserveOut_ Imaginary token reserve of output amount.
    function _getAmountOut(
        uint256 amountIn_,
        uint iReserveIn_,
        uint iReserveOut_
    ) internal pure returns (uint256 amountOut_) {
        // Both numerator and denominator are scaled to 1e6 to factor in fee scaling.
        uint256 numerator_ = amountIn_ * iReserveOut_;
        uint256 denominator_ = iReserveIn_ + amountIn_;

        // Using the swap formula: (AmountIn * iReserveY) / (iReserveX + AmountIn)
        amountOut_ = numerator_ / denominator_;
    }
    
    /// @dev Given an output amount of asset and pair reserves, returns the input amount of the other asset
    /// @param amountOut_ Desired output amount of the asset.
    /// @param iReserveIn_ Imaginary token reserve of input amount.
    /// @param iReserveOut_ Imaginary token reserve of output amount.
    function _getAmountIn(
        uint256 amountOut_,
        uint iReserveIn_,
        uint iReserveOut_
    ) internal pure returns (uint256 amountIn_) {
        // Both numerator and denominator are scaled to 1e6 to factor in fee scaling.
        uint256 numerator_ = amountOut_ * iReserveIn_;
        uint256 denominator_ = iReserveOut_ - amountOut_;

        // Using the swap formula: (AmountOut * iReserveX) / (iReserveY - AmountOut)
        amountIn_ = numerator_ / denominator_;
    }

    /// @dev This function calculates the new value of a parameter after a shifting process.
    /// @param current_ The current value is the final value where the shift ends
    /// @param old_ The old value from where shifting started.
    /// @param timePassed_ The time passed since shifting started.
    /// @param shiftDuration_ The total duration of the shift when old_ reaches current_
    /// @return The new value of the parameter after the shift.
    function _calcShiftingDone(uint current_, uint old_, uint timePassed_, uint shiftDuration_) internal pure returns (uint) {
        if (current_ > old_) {
            uint diff_ = current_ - old_;
            current_ = old_ + (diff_ * timePassed_ / shiftDuration_);
        } else {
            uint diff_ = old_ - current_;
            current_ = old_ - (diff_ * timePassed_ / shiftDuration_);
        }
        return current_;
    }

    /// @dev Calculates the new upper and lower range values during an active range shift
    /// @param upperRange_ The target upper range value
    /// @param lowerRange_ The target lower range value
    /// @param dexVariables2_ needed in case shift is ended and we need to update dexVariables2
    /// @return The updated upper range, lower range, and dexVariables2
    /// @notice This function handles the gradual shifting of range values over time
    /// @notice If the shift is complete, it updates the state and clears the shift data
    function _calcRangeShifting(uint upperRange_, uint lowerRange_, uint dexVariables2_) internal returns (uint, uint, uint) {
        uint rangeShift_ = _rangeShift;
        uint oldUpperRange_ = rangeShift_ & X20;
        uint oldLowerRange_ = (rangeShift_ >> 20) & X20;
        uint shiftDuration_ = (rangeShift_ >> 40) & X20;
        uint startTimeStamp_ = ((rangeShift_ >> 60) & X33);
        if ((startTimeStamp_ + shiftDuration_) < block.timestamp) {
            // shifting fully done
            delete _rangeShift;
            // making active shift as 0 because shift is over
            // fetching from storage and storing in storage, aside from admin module dexVariables2 only updates from this function and _calcThresholdShifting.
            dexVariables2_ = dexVariables2_ & ~uint(1 << 26);
            dexVariables2 = dexVariables2_;
            return (upperRange_, lowerRange_, dexVariables2_);
        }
        uint timePassed_ = block.timestamp - startTimeStamp_;
        return (
            _calcShiftingDone(upperRange_, oldUpperRange_, timePassed_, shiftDuration_),
            _calcShiftingDone(lowerRange_, oldLowerRange_, timePassed_, shiftDuration_),
            dexVariables2_
        );
    }

    /// @dev Calculates the new upper and lower threshold values during an active threshold shift
    /// @param upperThreshold_ The target upper threshold value
    /// @param lowerThreshold_ The target lower threshold value
    /// @param thresholdTime_ The time passed since shifting started
    /// @return The updated upper threshold, lower threshold, and threshold time
    /// @notice This function handles the gradual shifting of threshold values over time
    /// @notice If the shift is complete, it updates the state and clears the shift data
    function _calcThresholdShifting(uint upperThreshold_, uint lowerThreshold_, uint thresholdTime_) internal returns (uint, uint, uint) {
        uint thresholdShift_ = _thresholdShift;
        uint oldUpperThreshold_ = thresholdShift_ & X20;
        uint oldLowerThreshold_ = (thresholdShift_ >> 20) & X20;
        uint shiftDuration_ = (thresholdShift_ >> 40) & X20;
        uint startTimeStamp_ = ((thresholdShift_ >> 60) & X33);
        uint oldThresholdTime_ = (thresholdShift_ >> 93) & X24;
        if ((startTimeStamp_ + shiftDuration_) < block.timestamp) { 
            // shifting fully done
            delete _thresholdShift;
            // making active shift as 0 because shift is over
            // fetching from storage and storing in storage, aside from admin module dexVariables2 only updates from this function and _calcRangeShifting.
            dexVariables2 = dexVariables2 & ~uint(1 << 67);
            return (upperThreshold_, lowerThreshold_, thresholdTime_);
        }
        uint timePassed_ = block.timestamp - startTimeStamp_; 
        return (
            _calcShiftingDone(upperThreshold_, oldUpperThreshold_, timePassed_, shiftDuration_),
            _calcShiftingDone(lowerThreshold_, oldLowerThreshold_, timePassed_, shiftDuration_),
            _calcShiftingDone(thresholdTime_, oldThresholdTime_, timePassed_, shiftDuration_)
        );
    }

    /// @dev Calculates the new center price during an active price shift
    /// @param dexVariables_ The current state of dex variables
    /// @param dexVariables2_ Additional dex variables
    /// @return newCenterPrice_ The updated center price
    /// @notice This function gradually shifts the center price towards a new target price over time
    /// @notice It uses an external price source (via ICenterPrice) to determine the target price
    /// @notice The shift continues until the current price reaches the target, or the shift duration ends
    /// @notice Once the shift is complete, it updates the state and clears the shift data
    /// @notice The shift rate is dynamic and depends on:
    /// @notice - Time remaining in the shift duration
    /// @notice - The new center price (fetched externally, which may change)
    /// @notice - The current (old) center price
    /// @notice This results in a fuzzy shifting mechanism where the rate can change as these parameters evolve
    /// @notice The externally fetched new center price is expected to not differ significantly from the last externally fetched center price
    function _calcCenterPrice(uint dexVariables_, uint dexVariables2_) internal returns (uint newCenterPrice_) {
        uint oldCenterPrice_ = (dexVariables_ >> 81) & X40;
        oldCenterPrice_ = (oldCenterPrice_ >> DEFAULT_EXPONENT_SIZE) << (oldCenterPrice_ & DEFAULT_EXPONENT_MASK);
        uint centerPriceShift_ = _centerPriceShift;
        uint startTimeStamp_ = centerPriceShift_ & X33;
        uint percent_ = (centerPriceShift_ >> 33) & X20;
        uint time_ = (centerPriceShift_ >> 53) & X20;

        uint fromTimeStamp_ = (dexVariables_ >> 121) & X33;
        fromTimeStamp_ = fromTimeStamp_ > startTimeStamp_ ? fromTimeStamp_ : startTimeStamp_;

        newCenterPrice_ = ICenterPrice(AddressCalcs.addressCalc(DEPLOYER_CONTRACT, ((dexVariables2_ >> 112) & X30))).centerPrice();
        uint priceShift_ = (oldCenterPrice_ * percent_ * (block.timestamp - fromTimeStamp_)) / (time_ * SIX_DECIMALS);

        if (newCenterPrice_ > oldCenterPrice_) {
            // shift on positive side
            oldCenterPrice_ += priceShift_;
            if (newCenterPrice_ > oldCenterPrice_) {
                newCenterPrice_ = oldCenterPrice_;
            } else {
                // shifting fully done
                delete _centerPriceShift;
                // making active shift as 0 because shift is over
                // fetching from storage and storing in storage, aside from admin module dexVariables2 only updates these shift function.
                dexVariables2 = dexVariables2 & ~uint(1 << 248);
            }
        } else {
            unchecked {
                oldCenterPrice_ = oldCenterPrice_ > priceShift_ ? oldCenterPrice_ - priceShift_ : 0;
                // In case of oldCenterPrice_ ending up 0, which could happen when a lot of time has passed (pool has no swaps for many days or weeks)
                // then below we get into the else logic which will fully conclude shifting and return newCenterPrice_
                // as it was fetched from the external center price source.
                // not ideal that this would ever happen unless the pool is not in use and all/most users have left leaving not enough liquidity to trade on
            }
            if (newCenterPrice_ < oldCenterPrice_) {
                newCenterPrice_ = oldCenterPrice_;
            } else {
                // shifting fully done
                delete _centerPriceShift;
                // making active shift as 0 because shift is over
                // fetching from storage and storing in storage, aside from admin module dexVariables2 only updates these shift function.
                dexVariables2 = dexVariables2 & ~uint(1 << 248);
            }
        }
    }
    
    /// @notice Calculates and returns the current prices and exchange prices for the pool
    /// @param dexVariables_ The first set of DEX variables containing various pool parameters
    /// @param dexVariables2_ The second set of DEX variables containing additional pool parameters
    /// @return pex_ A struct containing the calculated prices and exchange prices:
    ///         - pex_.lastStoredPrice: The last stored price in 1e27 decimals
    ///         - pex_.centerPrice: The calculated or fetched center price in 1e27 decimals
    ///         - pex_.upperRange: The upper range price limit in 1e27 decimals
    ///         - pex_.lowerRange: The lower range price limit in 1e27 decimals
    ///         - pex_.geometricMean: The geometric mean of upper range & lower range in 1e27 decimals
    ///         - pex_.supplyToken0ExchangePrice: The current exchange price for supplying token0
    ///         - pex_.borrowToken0ExchangePrice: The current exchange price for borrowing token0
    ///         - pex_.supplyToken1ExchangePrice: The current exchange price for supplying token1
    ///         - pex_.borrowToken1ExchangePrice: The current exchange price for borrowing token1
    /// @dev This function performs the following operations:
    ///      1. Determines the center price (either from storage, external source, or calculated)
    ///      2. Retrieves the last stored price from dexVariables_
    ///      3. Calculates the upper and lower range prices based on the center price and range percentages
    ///      4. Checks if rebalancing is needed based on threshold settings
    ///      5. Adjusts prices if necessary based on the time elapsed and threshold conditions
    ///      6. Update the dexVariables2_ if changes were made
    ///      7. Returns the calculated prices and exchange prices in the PricesAndExchangePrice struct
    function _getPricesAndExchangePrices(
        uint dexVariables_,
        uint dexVariables2_
    ) internal returns (
        PricesAndExchangePrice memory pex_
    ) {
        uint centerPrice_;

        if (((dexVariables2_ >> 248) & 1) == 0) {
            // centerPrice_ => center price hook
            centerPrice_ = (dexVariables2_ >> 112) & X30;
            if (centerPrice_ == 0) {
                centerPrice_ = (dexVariables_ >> 81) & X40;
                centerPrice_ = (centerPrice_ >> DEFAULT_EXPONENT_SIZE) << (centerPrice_ & DEFAULT_EXPONENT_MASK);
            } else {
                // center price should be fetched from external source. For exmaple, in case of wstETH <> ETH pool,
                // we would want the center price to be pegged to wstETH exchange rate into ETH
                centerPrice_ = ICenterPrice(AddressCalcs.addressCalc(DEPLOYER_CONTRACT, centerPrice_)).centerPrice();
            }
        } else {
            // an active centerPrice_ shift is going on
            centerPrice_ = _calcCenterPrice(dexVariables_, dexVariables2_);
        }

        uint lastStoredPrice_ = (dexVariables_ >> 41) & X40;
        lastStoredPrice_ = (lastStoredPrice_ >> DEFAULT_EXPONENT_SIZE) << (lastStoredPrice_ & DEFAULT_EXPONENT_MASK);

        uint upperRange_ = ((dexVariables2_ >> 27) & X20);
        uint lowerRange_ = ((dexVariables2_ >> 47) & X20);
        if (((dexVariables2_ >> 26) & 1) == 1) {
            // an active range shift is going on
            (upperRange_, lowerRange_, dexVariables2_) = _calcRangeShifting(upperRange_, lowerRange_, dexVariables2_);
        }
        // 1% = 1e4, 100% = 1e6
        upperRange_ = (centerPrice_ * SIX_DECIMALS) / (SIX_DECIMALS - upperRange_);
        // 1% = 1e4, 100% = 1e6
        lowerRange_ = (centerPrice_ * (SIX_DECIMALS - lowerRange_)) / SIX_DECIMALS; 

        bool changed_;
        {
            // goal will be to keep threshold percents 0 if center price is fetched from external source
            // checking if threshold are set non 0 then only rebalancing is on
            if (((dexVariables2_ >> 68) & X20) > 0) {
                uint upperThreshold_ = (dexVariables2_ >> 68) & X10;
                uint lowerThreshold_ = (dexVariables2_ >> 78) & X10;
                uint shiftingTime_ = (dexVariables2_ >> 88) & X24;
                if (((dexVariables2_ >> 67) & 1) == 1) {
                    // if active shift is going on for threshold then calculate threshold real time
                    (upperThreshold_, lowerThreshold_, shiftingTime_) = _calcThresholdShifting(upperThreshold_, lowerThreshold_, shiftingTime_);
                }
                
                if (lastStoredPrice_ > (centerPrice_ + (upperRange_ - centerPrice_) * (THREE_DECIMALS - upperThreshold_) / THREE_DECIMALS)) {
                    uint timeElapsed_ = block.timestamp - ((dexVariables_ >> 121) & X33); 
                    // price shifting towards upper range
                    if (timeElapsed_ < shiftingTime_) {
                        centerPrice_ = centerPrice_ + ((upperRange_ - centerPrice_) * timeElapsed_) / shiftingTime_;
                    } else {
                        // 100% price shifted
                        centerPrice_ = upperRange_;
                    }

                    changed_ = true;
                } else if (lastStoredPrice_ < (centerPrice_ - (centerPrice_ - lowerRange_) * (THREE_DECIMALS - lowerThreshold_) / THREE_DECIMALS)) {
                    uint timeElapsed_ = block.timestamp - ((dexVariables_ >> 121) & X33); 
                    // price shifting towards lower range
                    if (timeElapsed_ < shiftingTime_) {
                        centerPrice_ = centerPrice_ - ((centerPrice_ - lowerRange_) * timeElapsed_) / shiftingTime_;
                    } else {
                        // 100% price shifted
                        centerPrice_ = lowerRange_;
                    }
                    changed_ = true;
                } 
            }
        }

        // temp_ => max center price
        uint temp_ = (dexVariables2 >> 172) & X28;
        temp_ = (temp_ >> DEFAULT_EXPONENT_SIZE) << (temp_ & DEFAULT_EXPONENT_MASK);
        if (centerPrice_ > temp_) {
            // if center price is greater than max center price
            centerPrice_ = temp_;
            changed_ = true;
        } else {
            // check if center price is less than min center price
            // temp_ => min center price
            temp_ = (dexVariables2 >> 200) & X28;
            temp_ = (temp_ >> DEFAULT_EXPONENT_SIZE) << (temp_ & DEFAULT_EXPONENT_MASK);
            if (centerPrice_ < temp_) {
                centerPrice_ = temp_;
                changed_ = true;
            }
        }

        // if centerPrice_ is changed then calculating upper and lower range again
        if (changed_) {
            upperRange_ = ((dexVariables2_ >> 27) & X20);
            lowerRange_ = ((dexVariables2_ >> 47) & X20);
            if (((dexVariables2_ >> 26) & 1) == 1) {
                (upperRange_, lowerRange_, dexVariables2_) = _calcRangeShifting(upperRange_, lowerRange_, dexVariables2_);
            }
            // 1% = 1e4, 100% = 1e6
            upperRange_ = (centerPrice_ * SIX_DECIMALS) / (SIX_DECIMALS - upperRange_); 
            // 1% = 1e4, 100% = 1e6
            lowerRange_ = (centerPrice_ * (SIX_DECIMALS - lowerRange_)) / SIX_DECIMALS; 
        }

        pex_.lastStoredPrice = lastStoredPrice_;
        pex_.centerPrice = centerPrice_;
        pex_.upperRange = upperRange_;
        pex_.lowerRange = lowerRange_;

        if (upperRange_ < 1e38) {
            // 1e38 * 1e38 = 1e76 which is less than max uint limit
            pex_.geometricMean = FixedPointMathLib.sqrt(upperRange_ * lowerRange_);
        } else {
            // upperRange_ price is pretty large hence lowerRange_ will also be pretty large
            pex_.geometricMean = FixedPointMathLib.sqrt((upperRange_ / 1e18) * (lowerRange_ / 1e18)) * 1e18;
        }

        // Exchange price will remain same as Liquidity Layer

        (pex_.supplyToken0ExchangePrice, pex_.borrowToken0ExchangePrice) = LiquidityCalcs.calcExchangePrices(
            LIQUIDITY.readFromStorage(EXCHANGE_PRICE_TOKEN_0_SLOT)
        );

        (pex_.supplyToken1ExchangePrice, pex_.borrowToken1ExchangePrice) = LiquidityCalcs.calcExchangePrices(
            LIQUIDITY.readFromStorage(EXCHANGE_PRICE_TOKEN_1_SLOT)
        );
    }

    /// @dev getting reserves outside range.
    /// @param gp_ is geometric mean pricing of upper percent & lower percent
    /// @param pa_ price of upper range or lower range
    /// @param rx_ real reserves of token0 or token1
    /// @param ry_ whatever is rx_ the other will be ry_
    function _calculateReservesOutsideRange(
        uint gp_,
        uint pa_,
        uint rx_,
        uint ry_
    ) internal pure returns (
        uint xa_,
        uint yb_
    ) {
        // equations we have:
        // 1. x*y = k
        // 2. xa*ya = k
        // 3. xb*yb = k
        // 4. Pa = ya / xa = upperRange_ (known)
        // 5. Pb = yb / xb = lowerRange_ (known)
        // 6. x - xa = rx = real reserve of x (known)
        // 7. y - yb = ry = real reserve of y (known)
        // With solving we get:
        // ((Pa*Pb)^(1/2) - Pa)*xa^2 + (rx * (Pa*Pb)^(1/2) + ry)*xa + rx*ry = 0
        // yb = yb = xa * (Pa * Pb)^(1/2)

        // xa = (GP⋅rx + ry + (-rx⋅ry⋅4⋅(GP - Pa) + (GP⋅rx + ry)^2)^0.5) / (2Pa - 2GP)
        // multiply entire equation by 1e27 to remove the price decimals precision of 1e27
        // xa = (GP⋅rx + ry⋅1e27 + (rx⋅ry⋅4⋅(Pa - GP)⋅1e27 + (GP⋅rx + ry⋅1e27)^2)^0.5) / 2*(Pa - GP)
        // dividing the equation with 2*(Pa - GP). Pa is always > GP so answer will be positive.
        // xa = (((GP⋅rx + ry⋅1e27) / 2*(Pa - GP)) + (((rx⋅ry⋅4⋅(Pa - GP)⋅1e27) / 4*(Pa - GP)^2) + ((GP⋅rx + ry⋅1e27) / 2*(Pa - GP))^2)^0.5)
        // xa = (((GP⋅rx + ry⋅1e27) / 2*(Pa - GP)) + (((rx⋅ry⋅1e27) / (Pa - GP)) + ((GP⋅rx + ry⋅1e27) / 2*(Pa - GP))^2)^0.5)

        // dividing in 3 parts for simplification:
        // part1 = (Pa - GP)
        // part2 = (GP⋅rx + ry⋅1e27) / (2*part1)
        // part3 = rx⋅ry
        // note: part1 will almost always be < 1e28 but in case it goes above 1e27 then it's extremely unlikely it'll go above > 1e29
        uint p1_ = pa_ - gp_;
        uint p2_ = ((gp_ * rx_) + (ry_ * 1e27)) / (2 * p1_);
        uint p3_ = rx_ * ry_;
        // to avoid overflowing
        p3_ = (p3_ < 1e50) ? ((p3_ * 1e27) / p1_) : (p3_ / p1_) * 1e27;

        // xa = part2 + (part3 + (part2 * part2))^(1/2)
        // yb = xa_ * gp_
        xa_ = p2_ + FixedPointMathLib.sqrt((p3_ + (p2_ * p2_)));
        yb_ = (xa_ * gp_) / 1e27;
    }

    /// @dev Retrieves collateral amount from liquidity layer for a given token
    /// @param supplyTokenSlot_ The storage slot for the supply token data
    /// @param tokenExchangePrice_ The exchange price of the token
    /// @param isToken0_ Boolean indicating if the token is token0 (true) or token1 (false)
    /// @return tokenSupply_ The calculated liquidity collateral amount
    function _getLiquidityCollateral(
        bytes32 supplyTokenSlot_,
        uint tokenExchangePrice_,
        bool isToken0_
    ) internal view returns (uint tokenSupply_) {
        uint tokenSupplyData_ = LIQUIDITY.readFromStorage(supplyTokenSlot_);
        tokenSupply_ = (tokenSupplyData_ >> LiquiditySlotsLink.BITS_USER_SUPPLY_AMOUNT) & X64;
        tokenSupply_ = (tokenSupply_ >> DEFAULT_EXPONENT_SIZE) << (tokenSupply_ & DEFAULT_EXPONENT_MASK);

        if (tokenSupplyData_ & 1 == 1) {
            // supply with interest is on
            tokenSupply_ = (tokenSupply_ * tokenExchangePrice_) / LiquidityCalcs.EXCHANGE_PRICES_PRECISION;
        }

        tokenSupply_ = isToken0_ ?
            ((tokenSupply_ * TOKEN_0_NUMERATOR_PRECISION) / TOKEN_0_DENOMINATOR_PRECISION) :
            ((tokenSupply_ * TOKEN_1_NUMERATOR_PRECISION) / TOKEN_1_DENOMINATOR_PRECISION);
    }

    /// @notice Calculates the real and imaginary reserves for collateral tokens
    /// @dev This function retrieves the supply of both tokens from the liquidity layer,
    ///      adjusts them based on exchange prices, and calculates imaginary reserves
    ///      based on the geometric mean and price range
    /// @param geometricMean_ The geometric mean of the token prices
    /// @param upperRange_ The upper price range
    /// @param lowerRange_ The lower price range
    /// @param token0SupplyExchangePrice_ The exchange price for token0 from liquidity layer
    /// @param token1SupplyExchangePrice_ The exchange price for token1 from liquidity layer
    /// @return c_ A struct containing the calculated real and imaginary reserves for both tokens:
    ///         - token0RealReserves: The real reserves of token0
    ///         - token1RealReserves: The real reserves of token1
    ///         - token0ImaginaryReserves: The imaginary reserves of token0
    ///         - token1ImaginaryReserves: The imaginary reserves of token1
    function getCollateralReserves(
        uint geometricMean_,
        uint upperRange_,
        uint lowerRange_,
        uint token0SupplyExchangePrice_,
        uint token1SupplyExchangePrice_
    ) public view returns (CollateralReserves memory c_) {
        uint token0Supply_ = _getLiquidityCollateral(SUPPLY_TOKEN_0_SLOT, token0SupplyExchangePrice_, true);
        uint token1Supply_ = _getLiquidityCollateral(SUPPLY_TOKEN_1_SLOT, token1SupplyExchangePrice_, false);

        if (geometricMean_ < 1e27) {
            (c_.token0ImaginaryReserves, c_.token1ImaginaryReserves) = _calculateReservesOutsideRange(geometricMean_, upperRange_, token0Supply_, token1Supply_);
        } else {
            // inversing, something like `xy = k` so for calculation we are making everything related to x into y & y into x
            // 1 / geometricMean for new geometricMean
            // 1 / lowerRange will become upper range
            // 1 / upperRange will become lower range
            (c_.token1ImaginaryReserves, c_.token0ImaginaryReserves) = _calculateReservesOutsideRange((1e54 / geometricMean_), (1e54 / lowerRange_), token1Supply_, token0Supply_);
        }

        c_.token0RealReserves = token0Supply_;
        c_.token1RealReserves = token1Supply_;
        c_.token0ImaginaryReserves += token0Supply_;
        c_.token1ImaginaryReserves += token1Supply_;
    }

    /// @notice Calculates the real and imaginary debt reserves for both tokens
    /// @dev This function uses a quadratic equation to determine the debt reserves
    ///      based on the geometric mean price and the current debt amounts
    /// @param gp_ The geometric mean price of upper range & lower range
    /// @param pb_ The price of lower range
    /// @param dx_ The debt amount of one token
    /// @param dy_ The debt amount of the other token
    /// @return rx_ The real debt reserve of the first token
    /// @return ry_ The real debt reserve of the second token
    /// @return irx_ The imaginary debt reserve of the first token
    /// @return iry_ The imaginary debt reserve of the second token
    function _calculateDebtReserves(
        uint gp_,
        uint pb_,
        uint dx_,
        uint dy_
    ) internal pure returns (
        uint rx_,
        uint ry_,
        uint irx_,
        uint iry_
    ) {
        // Assigning letter to knowns:
        // c = debtA
        // d = debtB
        // e = upperPrice
        // f = lowerPrice
        // g = upperPrice^1/2
        // h = lowerPrice^1/2

        // c = 1
        // d = 2000
        // e = 2222.222222
        // f = 1800
        // g = 2222.222222^1/2
        // h = 1800^1/2

        // Assigning letter to unknowns:
        // w = realDebtReserveA
        // x = realDebtReserveB
        // y = imaginaryDebtReserveA
        // z = imaginaryDebtReserveB
        // k = k

        // below quadratic will give answer of realDebtReserveB
        // A, B, C of quadratic equation:
        // A = h
        // B = dh - cfg
        // C = -cfdh

        // A = lowerPrice^1/2
        // B = debtB⋅lowerPrice^1/2 - debtA⋅lowerPrice⋅upperPrice^1/2
        // C = -(debtA⋅lowerPrice⋅debtB⋅lowerPrice^1/2)

        // x = (cfg − dh + (4cdf(h^2)+(cfg−dh)^2))^(1/2)) / 2h
        // simplifying dividing by h, note h = f^1/2
        // x = ((c⋅g⋅(f^1/2) − d) / 2 + ((4⋅c⋅d⋅f⋅f) / (4h^2) + ((c⋅f⋅g) / 2h − (d⋅h) / 2h)^2))^(1/2))
        // x = ((c⋅g⋅(f^1/2) − d) / 2 + ((c⋅d⋅f) + ((c⋅g⋅(f^1/2) − d) / 2)^2))^(1/2))

        // dividing in 3 parts for simplification:
        // part1 = (c⋅g⋅(f^1/2) − d) / 2
        // part2 = (c⋅d⋅f)
        // x = (part1 + (part2 + part1^2)^(1/2))
        // note: part1 will almost always be < 1e27 but in case it goes above 1e27 then it's extremely unlikely it'll go above > 1e28
        
        // part1 = ((debtA * upperPrice^1/2 * lowerPrice^1/2) - debtB) / 2
        // note: upperPrice^1/2 * lowerPrice^1/2 = geometric mean
        // part1 = ((debtA * geometricMean) - debtB) / 2
        // part2 = debtA * debtB * lowerPrice

        // converting decimals properly as price is in 1e27 decimals
        // part1 = ((debtA * geometricMean) - (debtB * 1e27)) / (2 * 1e27)
        // part2 = (debtA * debtB * lowerPrice) / 1e27
        // final x equals:
        // x = (part1 + (part2 + part1^2)^(1/2))
        int p1_ = (int(dx_ * gp_) - int(dy_ * 1e27)) / (2 * 1e27);
        uint p2_ = (dx_ * dy_);
        p2_ = p2_ < 1e50 ? (p2_ * pb_) / 1e27 : (p2_ / 1e27) * pb_;
        ry_ = uint(p1_ + int(FixedPointMathLib.sqrt((p2_ + uint(p1_ * p1_)))));

        // finding z:
        // x^2 - zx + cfz = 0
        // z*(x - cf) = x^2
        // z = x^2 / (x - cf)
        // z = x^2 / (x - debtA * lowerPrice)
        // converting decimals properly as price is in 1e27 decimals
        // z = (x^2 * 1e27) / ((x * 1e27) - (debtA * lowerPrice))

        iry_ = ((ry_ * 1e27) - (dx_ * pb_));
        if (iry_ < SIX_DECIMALS) {
            // almost impossible situation to ever get here
            revert FluidDexError(ErrorTypes.DexT1__DebtReservesTooLow);
        }
        if (ry_ < 1e25) {
            iry_ = (ry_ * ry_ * 1e27) / iry_;
        } else {
            // note: it can never result in negative as final result will always be in positive
            iry_ = (ry_ * ry_) / (iry_ / 1e27);
        }

        // finding y
        // x = z * c / (y + c)
        // y + c = z * c / x
        // y = (z * c / x) - c
        // y = (z * debtA / x) - debtA
        irx_ = ((iry_ * dx_) / ry_) - dx_;

        // finding w
        // w = y * d / (z + d)
        // w = (y * debtB) / (z + debtB)
        rx_ = (irx_ * dy_) / (iry_ + dy_);
    }

    /// @notice Calculates the debt amount for a given token from liquidity layer
    /// @param borrowTokenSlot_ The storage slot for the token's borrow data
    /// @param tokenExchangePrice_ The current exchange price of the token
    /// @param isToken0_ Boolean indicating if this is for token0 (true) or token1 (false)
    /// @return tokenDebt_ The calculated debt amount for the token
    function _getLiquidityDebt(
        bytes32 borrowTokenSlot_,
        uint tokenExchangePrice_,
        bool isToken0_
    ) internal view returns (uint tokenDebt_) {
        uint tokenBorrowData_ = LIQUIDITY.readFromStorage(borrowTokenSlot_);

        tokenDebt_ = (tokenBorrowData_ >> LiquiditySlotsLink.BITS_USER_BORROW_AMOUNT) & X64;
        tokenDebt_ = (tokenDebt_ >> 8) << (tokenDebt_ & X8);

        if (tokenBorrowData_ & 1 == 1) {
            // borrow with interest is on
            tokenDebt_ = (tokenDebt_ * tokenExchangePrice_) / LiquidityCalcs.EXCHANGE_PRICES_PRECISION;
        }

        tokenDebt_ = isToken0_ ?
            ((tokenDebt_ * TOKEN_0_NUMERATOR_PRECISION) / TOKEN_0_DENOMINATOR_PRECISION) :
            ((tokenDebt_ * TOKEN_1_NUMERATOR_PRECISION) / TOKEN_1_DENOMINATOR_PRECISION);
    }

    /// @notice Calculates the debt reserves for both tokens
    /// @param geometricMean_ The geometric mean of the upper and lower price ranges
    /// @param upperRange_ The upper price range
    /// @param lowerRange_ The lower price range
    /// @param token0BorrowExchangePrice_ The exchange price of token0 from liquidity layer
    /// @param token1BorrowExchangePrice_ The exchange price of token1 from liquidity layer
    /// @return d_ The calculated debt reserves for both tokens, containing:
    ///         - token0Debt: The debt amount of token0
    ///         - token1Debt: The debt amount of token1
    ///         - token0RealReserves: The real reserves of token0 derived from token1 debt
    ///         - token1RealReserves: The real reserves of token1 derived from token0 debt
    ///         - token0ImaginaryReserves: The imaginary debt reserves of token0
    ///         - token1ImaginaryReserves: The imaginary debt reserves of token1
    function getDebtReserves(
        uint geometricMean_,
        uint upperRange_,
        uint lowerRange_,
        uint token0BorrowExchangePrice_,
        uint token1BorrowExchangePrice_
    ) public view returns (DebtReserves memory d_) {
        uint token0Debt_ = _getLiquidityDebt(BORROW_TOKEN_0_SLOT, token0BorrowExchangePrice_, true);
        uint token1Debt_ = _getLiquidityDebt(BORROW_TOKEN_1_SLOT, token1BorrowExchangePrice_, false);

        d_.token0Debt = token0Debt_;
        d_.token1Debt = token1Debt_;

        if (geometricMean_ < 1e27) {
            (d_.token0RealReserves, d_.token1RealReserves, d_.token0ImaginaryReserves, d_.token1ImaginaryReserves) = _calculateDebtReserves(geometricMean_, lowerRange_, token0Debt_, token1Debt_);
        } else {
            // inversing, something like `xy = k` so for calculation we are making everything related to x into y & y into x
            // 1 / geometricMean for new geometricMean
            // 1 / lowerRange will become upper range
            // 1 / upperRange will become lower range
            (d_.token1RealReserves, d_.token0RealReserves, d_.token1ImaginaryReserves, d_.token0ImaginaryReserves) = _calculateDebtReserves((1e54 / geometricMean_), (1e54 / upperRange_), token1Debt_, token0Debt_);
        }

    }

    /// @param t total amount in
    /// @param x imaginary reserves of token out of collateral
    /// @param y imaginary reserves of token in of collateral
    /// @param x2 imaginary reserves of token out of debt
    /// @param y2 imaginary reserves of token in of debt
    /// @return a_ how much swap should go through collateral pool. Remaining will go from debt
    /// note if a < 0 then entire trade route through debt pool and debt pool arbitrage with col pool
    /// note if a > t then entire trade route through col pool and col pool arbitrage with debt pool
    /// note if a > 0 & a < t then swap will route through both pools
    function _swapRoutingIn(
        uint t,
        uint x,
        uint y,
        uint x2,
        uint y2
    ) internal pure returns (
        int a_
    ) {
        // Main equations:
        // 1. out = x * a / (y + a)
        // 2. out2 = x2 * (t - a) / (y2 + (t - a))
        // final price should be same
        // 3. (y + a) / (x - out) = (y2 + (t - a)) / (x2 - out2)
        // derivation: https://chatgpt.com/share/dce6f381-ee5f-4d5f-b6ea-5996e84d5b57

        // adding 1e18 precision
        uint xyRoot_ = FixedPointMathLib.sqrt(x * y * 1e18);
        uint x2y2Root_ = FixedPointMathLib.sqrt(x2 * y2 * 1e18);

        a_ = (int(y2 * xyRoot_ + t * xyRoot_) - int(y * x2y2Root_)) / int(xyRoot_ + x2y2Root_);
    }

    /// @param t total amount out
    /// @param x imaginary reserves of token in of collateral
    /// @param y imaginary reserves of token out of collateral
    /// @param x2 imaginary reserves of token in of debt
    /// @param y2 imaginary reserves of token out of debt
    /// @return a_ how much swap should go through collateral pool. Remaining will go from debt
    /// note if a < 0 then entire trade route through debt pool and debt pool arbitrage with col pool
    /// note if a > t then entire trade route through col pool and col pool arbitrage with debt pool
    /// note if a > 0 & a < t then swap will route through both pools
    function _swapRoutingOut(
        uint t,
        uint x,
        uint y,
        uint x2,
        uint y2
    ) internal pure returns (
        int a_
    ) {
        // Main equations:
        // 1. in = (x * a) / (y - a)
        // 2. in2 = (x2 * (t - a)) / (y2 - (t - a))
        // final price should be same
        // 3. (y - a) / (x + in) = (y2 - (t - a)) / (x2 + in2)
        // derivation: https://chatgpt.com/share/6585bc28-841f-49ec-aea2-1e5c5b7f4fa9

        // adding 1e18 precision
        uint xyRoot_ = FixedPointMathLib.sqrt(x * y * 1e18);
        uint x2y2Root_ = FixedPointMathLib.sqrt(x2 * y2 * 1e18);

        // 1e18 precision gets cancelled out in division
        a_ = (int(t * xyRoot_ + y * x2y2Root_) - int(y2 * xyRoot_)) / int(xyRoot_ + x2y2Root_);
    }

    /// @param c_ tokenA amount to swap and deposit
    /// @param d_ tokenB imaginary reserves
    /// @param e_ tokenA imaginary reserves
    /// @param f_ tokenA real reserves
    /// @param i_ tokenB real reserves
    function _getSwapAndDeposit(
        uint c_,
        uint d_,
        uint e_,
        uint f_,
        uint i_
    ) internal pure returns (
        uint shares_
    ) {
        // swap and deposit in equal proportion

        // tokenAx = c
        // imaginaryTokenBReserves = d
        // imaginaryTokenAReserves = e
        // tokenAReserves = f
        // tokenBReserves = i

        // Quadratic equations, A, B & C are:
        // A = i
        // B = (ie - ic + dc + fd)
        // C = -iec

        // final equation:
        // token to swap = (−(c⋅d−c⋅i+d⋅f+e⋅i) + (4⋅c⋅e⋅i^2 + (c⋅d−c⋅i+d⋅f+e⋅i)^2)^0.5) / 2⋅i
        // B = (c⋅d−c⋅i+d⋅f+e⋅i)
        // token to swap = (−B + (4⋅c⋅e⋅i^2 + (B)^2)^0.5) / 2⋅i
        // simplifying above equation by dividing the entire equation by i:
        // token to swap = (−B/i + (4⋅c⋅e + (B/i)^2)^0.5) / 2
        // note: d > i always, so dividing won't be an issue

        // temp_ => B/i
        uint temp_ = (c_ * d_ + d_ * f_ + e_ * i_ - c_ * i_) / i_; 
        uint temp2_ = 4 * c_ * e_;
        uint amtToSwap_ = (FixedPointMathLib.sqrt((temp2_ + (temp_ * temp_))) - temp_) / 2;

        // Ensure the amount to swap is within reasonable bounds:
        // - Not greater than 99.9999% of the input amount (c_)
        // - Not less than 0.0001% of the input amount (c_)
        // This prevents extreme scenarios and maybe potential precision issues
        if (
            (amtToSwap_ > ((c_ * SIX_DECIMALS - 1) / SIX_DECIMALS)) || 
            (amtToSwap_ < (c_ / SIX_DECIMALS))
        ) revert FluidDexError(ErrorTypes.DexT1__SwapAndDepositTooLowOrTooHigh);

        // temp_ => amt0ToDeposit 
        temp_ = c_ - amtToSwap_;
        // (imaginaryTokenBReserves * amtToSwap_) / (imaginaryTokenAReserves + amtToSwap_)
        // temp2_ => amt1ToDeposit_
        temp2_ = (d_ * amtToSwap_) / (e_ + amtToSwap_);

        // temp_ => shares1
        temp_ = temp_ * 1e18 / (f_ + amtToSwap_);
        // temp2_ => shares1
        temp2_ = temp2_ * 1e18 / (i_ - temp2_);
        // temp_ & temp2 should be same. Although, due to some possible precision loss taking the lower one
        shares_ = temp_ > temp2_ ? temp2_ : temp_;
    }

    /// @notice Updates collateral reserves based on minting or burning of shares
    /// @param newShares_ The number of new shares being minted or burned
    /// @param totalOldShares_ The total number of shares before the operation
    /// @param c_ The current collateral reserves
    /// @param mintOrBurn_ True if minting shares, false if burning shares
    /// @return c2_ The updated collateral reserves after the operation
    function _getUpdatedColReserves(
        uint newShares_,
        uint totalOldShares_,
        CollateralReserves memory c_,
        bool mintOrBurn_ // true if mint, false if burn 
    ) internal pure returns (
        CollateralReserves memory c2_
    ) {
        if (mintOrBurn_) {
            // If minting, increase reserves proportionally to new shares
            c2_.token0RealReserves = c_.token0RealReserves + c_.token0RealReserves * newShares_ / totalOldShares_;
            c2_.token1RealReserves = c_.token1RealReserves + c_.token1RealReserves * newShares_ / totalOldShares_;
            c2_.token0ImaginaryReserves = c_.token0ImaginaryReserves + c_.token0ImaginaryReserves * newShares_ / totalOldShares_;
            c2_.token1ImaginaryReserves = c_.token1ImaginaryReserves + c_.token1ImaginaryReserves * newShares_ / totalOldShares_;
        } else {
            // If burning, decrease reserves proportionally to burned shares
            c2_.token0RealReserves = c_.token0RealReserves - (c_.token0RealReserves * newShares_ / totalOldShares_);
            c2_.token1RealReserves = c_.token1RealReserves - (c_.token1RealReserves * newShares_ / totalOldShares_);
            c2_.token0ImaginaryReserves = c_.token0ImaginaryReserves - (c_.token0ImaginaryReserves * newShares_ / totalOldShares_);
            c2_.token1ImaginaryReserves = c_.token1ImaginaryReserves - (c_.token1ImaginaryReserves * newShares_ / totalOldShares_);
        }
        return c2_;
    }

    /// @param c_ tokenA current real reserves (aka reserves before withdraw & swap)
    /// @param d_ tokenB current real reserves (aka reserves before withdraw & swap)
    /// @param e_ tokenA: final imaginary reserves - real reserves (aka reserves outside range after withdraw & swap)
    /// @param f_ tokenB: final imaginary reserves - real reserves (aka reserves outside range after withdraw & swap)
    /// @param g_ tokenA perfect amount to withdraw
    function _getWithdrawAndSwap(
        uint c_,
        uint d_,
        uint e_,
        uint f_,
        uint g_
    ) internal pure returns (
        uint shares_
    ) {
        // Equations we have:
        // 1. tokenAxa / tokenBxb = tokenAReserves / tokenBReserves (Withdraw in equal proportion)
        // 2. newTokenAReserves = tokenAReserves - tokenAxa
        // 3. newTokenBReserves = tokenBReserves - tokenBxb
        // 4 (known). finalTokenAReserves = tokenAReserves - tokenAx
        // 5 (known). finalTokenBReserves = tokenBReserves

        // Note: Xnew * Ynew = k = Xfinal * Yfinal (Xfinal & Yfinal is final imaginary reserve of token A & B).
        // Now as we know finalTokenAReserves & finalTokenAReserves, hence we can also calculate
        // imaginaryReserveMinusRealReservesA = finalImaginaryAReserves - finalTokenAReserves
        // imaginaryReserveMinusRealReservesB = finalImaginaryBReserves - finalTokenBReserves
        // Swaps only happen on real reserves hence before and after swap imaginaryReserveMinusRealReservesA &
        // imaginaryReserveMinusRealReservesB should have exactly the same value.

        // 6. newImaginaryTokenAReserves = imaginaryReserveMinusRealReservesA + newTokenAReserves
        // newImaginaryTokenAReserves = imaginaryReserveMinusRealReservesA + tokenAReserves - tokenAxa
        // 7. newImaginaryTokenBReserves = imaginaryReserveMinusRealReservesB + newTokenBReserves
        // newImaginaryTokenBReserves = imaginaryReserveMinusRealReservesB + tokenBReserves - tokenBxb
        // 8. tokenAxb = (newImaginaryTokenAReserves * tokenBxb) / (newImaginaryTokenBReserves + tokenBxb)
        // 9. tokenAxa + tokenAxb = tokenAx

        // simplifying knowns in 1 letter to make things clear:
        // c = tokenAReserves
        // d = tokenBReserves
        // e = imaginaryReserveMinusRealReservesA
        // f = imaginaryReserveMinusRealReservesB
        // g = tokenAx

        // A, B, C of quadratic are:
        // A = d
        // B = -(de + 2cd + cf)
        // C = cfg + cdg

        // tokenAxa = ((d⋅e + 2⋅c⋅d + c⋅f) - ((d⋅e + 2⋅c⋅d + c⋅f)^2 - 4⋅d⋅(c⋅f⋅g + c⋅d⋅g))^0.5) / 2d
        // dividing 2d first to avoid overflowing
        // B = (d⋅e + 2⋅c⋅d + c⋅f) / 2d
        // (B - ((B)^2 - (4⋅d⋅(c⋅f⋅g + c⋅d⋅g) / 4⋅d^2))^0.5)
        // (B - ((B)^2 - ((c⋅f⋅g + c⋅d⋅g) / d))^0.5)

        // temp_ = B/2A
        uint temp_ = (d_ * e_ + 2 * c_ * d_ + c_ * f_) / (2 * d_);
        // temp2_ = 4AC / 4A^2 = C / A
        // to avoid overflowing in any case multiplying with g_ later
        uint temp2_ = (((c_ * f_) / d_) + c_) * g_;

        // tokenAxa = (-B - (B^2 - 4AC)^0.5) / 2A
        uint tokenAxa_ = temp_ - FixedPointMathLib.sqrt((temp_ * temp_) - temp2_);

        // Ensure the amount to withdraw is within reasonable bounds:
        // - Not greater than 99.9999% of the input amount (g_)
        // - Not less than 0.0001% of the input amount (g_)
        // This prevents extreme scenarios and maybe potential precision issues
        if (
            tokenAxa_ > ((g_ * SIX_DECIMALS - 1) / SIX_DECIMALS) ||
            tokenAxa_ < (g_ / SIX_DECIMALS)
        ) revert FluidDexError(ErrorTypes.DexT1__WithdrawAndSwapTooLowOrTooHigh);

        shares_ = tokenAxa_ * 1e18 / c_;
    }

    /// @param c_ tokenA current debt before swap (aka debt before borrow & swap)
    /// @param d_ tokenB current debt before swap (aka debt before borrow & swap)
    /// @param e_ tokenA final imaginary reserves (reserves after borrow & swap)
    /// @param f_ tokenB final imaginary reserves (reserves after borrow & swap)
    /// @param g_ tokenA perfect amount to borrow
    function _getBorrowAndSwap(
        uint c_,
        uint d_,
        uint e_,
        uint f_,
        uint g_
    ) internal pure returns (
        uint shares_
    ) {
        // 1. tokenAxa / tokenADebt = tokenBxb / tokenBDebt (borrowing in equal proportion)
        // 2. newImaginaryTokenAReserves = tokenAFinalImaginaryReserves + tokenAxb
        // 3. newImaginaryTokenBReserves = tokenBFinalImaginaryReserves - tokenBxb
        // // Note: I assumed reserve of tokenA and debt of token A while solving which is fine.
        // // But in other places I use debtA to find reserveB
        // 4. tokenAxb = (newImaginaryTokenAReserves * tokenBxb) / (newImaginaryTokenBReserves + tokenBxb)
        // 5. tokenAxa + tokenAxb = tokenAx

        // Inserting 2 & 3 into 4:
        // 6. tokenAxb = ((tokenAFinalImaginaryReserves + tokenAxb) * tokenBxb) / ((tokenBFinalImaginaryReserves - tokenBxb) + tokenBxb)
        // 6. tokenAxb = ((tokenAFinalImaginaryReserves + tokenAxb) * tokenBxb) / (tokenBFinalImaginaryReserves)

        // Making 1 in terms of tokenBxb:
        // 1. tokenBxb = tokenAxa * tokenBDebt / tokenADebt

        // Inserting 5 into 6:
        // 7. (tokenAx - tokenAxa) = ((tokenAFinalImaginaryReserves + (tokenAx - tokenAxa)) * tokenBxb) / (tokenBFinalImaginaryReserves)

        // Inserting 1 into 7:
        // 8. (tokenAx - tokenAxa) * tokenBFinalImaginaryReserves = ((tokenAFinalImaginaryReserves + (tokenAx - tokenAxa)) * (tokenAxa * tokenBDebt / tokenADebt))

        // Replacing knowns with:
        // c = tokenADebt
        // d = tokenBDebt
        // e = tokenAFinalImaginaryReserves
        // f = tokenBFinalImaginaryReserves
        // g = tokenAx

        // 8. (g - tokenAxa) * f * c = ((e + (g - tokenAxa)) * (tokenAxa * d))
        // 8. cfg - cf*tokenAxa = de*tokenAxa + dg*tokenAxa - d*tokenAxa^2
        // 8. d*tokenAxa^2 - cf*tokenAxa - de*tokenAxa - dg*tokenAxa + cfg = 0
        // 8. d*tokenAxa^2 - (cf + de + dg)*tokenAxa + cfg = 0

        // A, B, C of quadratic are:
        // A = d
        // B = -(cf + de + dg)
        // C = cfg

        // temp_ = B/2A
        uint temp_ = (c_ * f_ + d_ * e_ + d_ * g_) / (2 * d_);        

        // temp2_ = 4AC / 4A^2 = C / A
        // to avoid overflowing in any case multiplying with g_ later
        uint temp2_ = (c_ * f_ * g_) / d_;

        // tokenAxa = (-B - (B^2 - 4AC)^0.5) / 2A
        uint tokenAxa_ = temp_ - FixedPointMathLib.sqrt((temp_ * temp_) - temp2_);

        // Ensure the amount to borrow is within reasonable bounds:
        // - Not greater than 99.9999% of the input amount (g_)
        // - Not less than 0.0001% of the input amount (g_)
        // This prevents extreme scenarios and maybe potential precision issues
        if (
            tokenAxa_ > ((g_ * SIX_DECIMALS - 1) / SIX_DECIMALS) ||
            tokenAxa_ < (g_ / SIX_DECIMALS)
        ) revert FluidDexError(ErrorTypes.DexT1__BorrowAndSwapTooLowOrTooHigh);

        shares_ = tokenAxa_ * 1e18 / c_;
    }

    /// @notice Updates debt and reserves based on minting or burning shares
    /// @param shares_ The number of shares to mint or burn
    /// @param totalShares_ The total number of shares before the operation
    /// @param d_ The current debt and reserves
    /// @param mintOrBurn_ True if minting, false if burning
    /// @return d2_ The updated debt and reserves
    /// @dev This function calculates the new debt and reserves when minting or burning shares.
    /// @dev It updates the following for both tokens:
    /// @dev - Debt
    /// @dev - Real Reserves
    /// @dev - Imaginary Reserves
    /// @dev The calculation is done proportionally based on the ratio of shares to total shares.
    /// @dev For minting, it adds the proportional amount.
    /// @dev For burning, it subtracts the proportional amount.
    function _getUpdateDebtReserves(
        uint shares_,
        uint totalShares_,
        DebtReserves memory d_,
        bool mintOrBurn_ // true if mint, false if burn
    ) internal pure returns (
        DebtReserves memory d2_
    ) {
        if (mintOrBurn_) {
            d2_.token0Debt = d_.token0Debt + d_.token0Debt * shares_ / totalShares_;
            d2_.token1Debt = d_.token1Debt + d_.token1Debt * shares_ / totalShares_;
            d2_.token0RealReserves = d_.token0RealReserves + d_.token0RealReserves * shares_ / totalShares_;
            d2_.token1RealReserves = d_.token1RealReserves + d_.token1RealReserves * shares_ / totalShares_;
            d2_.token0ImaginaryReserves = d_.token0ImaginaryReserves + d_.token0ImaginaryReserves * shares_ / totalShares_;
            d2_.token1ImaginaryReserves = d_.token1ImaginaryReserves + d_.token1ImaginaryReserves * shares_ / totalShares_;
        } else {
            d2_.token0Debt = d_.token0Debt - d_.token0Debt * shares_ / totalShares_;
            d2_.token1Debt = d_.token1Debt - d_.token1Debt * shares_ / totalShares_;
            d2_.token0RealReserves = d_.token0RealReserves - d_.token0RealReserves * shares_ / totalShares_;
            d2_.token1RealReserves = d_.token1RealReserves - d_.token1RealReserves * shares_ / totalShares_;
            d2_.token0ImaginaryReserves = d_.token0ImaginaryReserves - d_.token0ImaginaryReserves * shares_ / totalShares_;
            d2_.token1ImaginaryReserves = d_.token1ImaginaryReserves - d_.token1ImaginaryReserves * shares_ / totalShares_;
        }

        return d2_;
    }

    /// @param a_ tokenA new imaginary reserves (imaginary reserves after perfect payback but not swap yet)
    /// @param b_ tokenB new imaginary reserves (imaginary reserves after perfect payback but not swap yet)
    /// @param c_ tokenA current debt
    /// @param d_ tokenB current debt & final debt (tokenB current & final debt remains same)
    /// @param i_ tokenA new reserves (reserves after perfect payback but not swap yet)
    /// @param j_ tokenB new reserves (reserves after perfect payback but not swap yet)
    function _getSwapAndPaybackOneTokenPerfectShares(
        uint a_,
        uint b_,
        uint c_,
        uint d_,
        uint i_,
        uint j_
    ) internal pure returns (uint tokenAmt_) {
        // l_ => tokenA reserves outside range
        uint l_ = a_ - i_;
        // m_ => tokenB reserves outside range
        uint m_ = b_ - j_;
        // w_ => new K or final K will be same, xy = k
        uint w_ = a_ * b_;
        // z_ => final reserveB full, when entire debt is in tokenA
        uint z_ = w_ / l_;
        // y_ => final reserveA full, when entire debt is in tokenB
        uint y_ = w_ / m_;
        // v_ = final reserveB
        uint v_ = z_ - m_ - d_;
        // x_ = final tokenA debt
        uint x_ = (v_ * y_) / (m_ + v_);

        // amountA to payback, this amount will get swapped into tokenB to payback in perfect proportion
        tokenAmt_ = c_ - x_;

        // Ensure the amount to swap and payback is within reasonable bounds:
        // - Not greater than 99.9999% of the current debt (c_)
        // This prevents extreme scenarios where almost all debt is getting paid after swap,
        // which could maybe lead to precision issues & edge cases
        if (
            (tokenAmt_ > (c_ * (SIX_DECIMALS - 1)) / SIX_DECIMALS)
        ) revert FluidDexError(ErrorTypes.DexT1__SwapAndPaybackTooLowOrTooHigh);
    }

    /// @param c_ tokenA debt before swap & payback
    /// @param d_ tokenB debt before swap & payback
    /// @param e_ tokenA imaginary reserves before swap & payback
    /// @param f_ tokenB imaginary reserves before swap & payback
    /// @param g_ tokenA perfect amount to payback
    function _getSwapAndPayback(
        uint c_,
        uint d_,
        uint e_,
        uint f_,
        uint g_
    ) internal pure returns (
        uint shares_
    ) {
        // 1. tokenAxa / newTokenADebt = tokenBxb / newTokenBDebt (borrowing in equal proportion)
        // 2. newTokenADebt = tokenADebt - tokenAxb
        // 3. newTokenBDebt = tokenBDebt + tokenBxb
        // 4. imaginaryTokenAReserves = Calculated above from debtA
        // 5. imaginaryTokenBReserves = Calculated above from debtA
        // // Note: I assumed reserveA and debtA for same tokenA
        // // But in other places I used debtA to find reserveB
        // 6. tokenBxb = (imaginaryTokenBReserves * tokenAxb) / (imaginaryTokenAReserves + tokenAxb)
        // 7. tokenAxa + tokenAxb = tokenAx

        // Unknowns in the above equations are:
        // tokenAxa, tokenAxb, tokenBxb

        // simplifying knowns in 1 letter to make things clear:
        // c = tokenADebt
        // d = tokenBDebt
        // e = imaginaryTokenAReserves
        // f = imaginaryTokenBReserves
        // g = tokenAx

        // Restructuring 1:
        // 1. newTokenBDebt = (tokenBxb * newTokenADebt) / tokenAxa

        // Inserting 1 in 3:
        // 8. (tokenBxb * newTokenADebt) / tokenAxa = tokenBDebt + tokenBxb

        // Refactoring 8 w.r.t tokenBxb:
        // 8. (tokenBxb * newTokenADebt) - tokenAxa * tokenBxb = tokenBDebt * tokenAxa
        // 8. tokenBxb * (newTokenADebt - tokenAxa) = tokenBDebt * tokenAxa
        // 8. tokenBxb = (tokenBDebt * tokenAxa) / (newTokenADebt - tokenAxa)

        // Inserting 2 in 8:
        // 9. tokenBxb = (tokenBDebt * tokenAxa) / (tokenADebt - tokenAxb - tokenAxa)
        // 9. tokenBxb = (tokenBDebt * tokenAxa) / (tokenADebt - tokenAx)

        // Inserting 9 in 6:
        // 10. (tokenBDebt * tokenAxa) / (tokenADebt - tokenAx) = (imaginaryTokenBReserves * tokenAxb) / (imaginaryTokenAReserves + tokenAxb)
        // 10. (tokenBDebt * (tokenAx - tokenAxb)) / (tokenADebt - tokenAx) = (imaginaryTokenBReserves * tokenAxb) / (imaginaryTokenAReserves + tokenAxb)

        // Replacing with single digits:
        // 10. (d * (g - tokenAxb)) / (c - g) = (f * tokenAxb) / (e + tokenAxb)
        // 10. d * (g - tokenAxb) * (e + tokenAxb) = (f * tokenAxb) * (c - g)
        // 10. deg + dg*tokenAxb - de*tokenAxb - d*tokenAxb^2 = cf*tokenAxb - fg*tokenAxb
        // 10. d*tokenAxb^2 + cf*tokenAxb - fg*tokenAxb + de*tokenAxb - dg*tokenAxb - deg = 0
        // 10. d*tokenAxb^2 + (cf - fg + de - dg)*tokenAxb - deg = 0

        // A = d
        // B = (cf + de - fg - dg)
        // C = -deg

        // Solving Quadratic will give the value for tokenAxb, now that "tokenAxb" is known we can also know:
        // tokenAxa & tokenBxb

        // temp_ => B/A
        uint temp_ = (c_ * f_ + d_ * e_ - f_ * g_ - d_ * g_) / d_;

        // temp2_ = -AC / A^2
        uint temp2_ = 4 * e_ * g_;

        uint amtToSwap_ = (FixedPointMathLib.sqrt((temp2_ + (temp_ * temp_))) - temp_) / 2;

        // Ensure the amount to swap is within reasonable bounds:
        // - Not greater than 99.9999% of the input amount (g_)
        // - Not less than 0.0001% of the input amount (g_)
        // This prevents extreme scenarios and maybe potential precision issues
        if (
            (amtToSwap_ > (g_ * (SIX_DECIMALS - 1)) / SIX_DECIMALS) ||
            (amtToSwap_ < (g_ / SIX_DECIMALS))
        ) revert FluidDexError(ErrorTypes.DexT1__SwapAndPaybackTooLowOrTooHigh);

        // temp_ => amt0ToPayback 
        temp_ = g_ - amtToSwap_;
        // (imaginaryTokenBReserves * amtToSwap_) / (imaginaryTokenAReserves + amtToSwap_)
        // temp2_ => amt1ToPayback
        temp2_ = (f_ * amtToSwap_) / (e_ + amtToSwap_);

        // temp_ => shares0
        temp_ = temp_ * 1e18 / (c_ - amtToSwap_);
        // temp_ => shares1
        temp2_ = temp2_ * 1e18 / (d_ + temp2_);
        // temp_ & temp2 should be same. Although, due to some possible precision loss taking the lower one
        shares_ = temp_ > temp2_ ? temp2_ : temp_;
    }

    /// @notice Deposits or pays back in liquidity
    /// @param token_ The token to deposit or pay back
    /// @param depositAmt_ The amount to deposit
    /// @param paybackAmt_ The amount to pay back
    function _depositOrPaybackInLiquidity(address token_, uint depositAmt_, uint paybackAmt_) internal {
        // both cannot be greater than 0
        // if both are 0 then liquidity layer will revert
        // only 1 should be greater than 0
        if (depositAmt_ > 0 && paybackAmt_ > 0) revert(); 
        if (token_ == NATIVE_TOKEN) {
            uint amt_ = depositAmt_ > 0 ? depositAmt_ : paybackAmt_;
            if (msg.value > amt_) {
                SafeTransfer.safeTransferNative(msg.sender, msg.value - amt_);
            } else if (msg.value < amt_) {
                revert FluidDexError(ErrorTypes.DexT1__MsgValueLowOnDepositOrPayback);
            }
            // Note in case of native the abi.encode(msg.sender) below is also needed to 
            // profit of equal in out gas optimization implemented in liquidity
            LIQUIDITY.operate{ value: amt_ }(token_, int(depositAmt_), -int(paybackAmt_), address(0), address(0), abi.encode(msg.sender));
        } else {
            LIQUIDITY.operate(token_, int(depositAmt_), -int(paybackAmt_), address(0), address(0), abi.encode(msg.sender));
        }
    }

    function _updateOracle(
        uint newPrice_,
        uint centerPrice_,
        uint dexVariables_
    ) internal returns (uint) {
        // time difference between last & current swap
        uint timeDiff_ = block.timestamp - ((dexVariables_ >> 121) & X33);

        uint temp_;
        uint temp2_;
        uint temp3_;

        if (timeDiff_ > 0) {
            // update oracle
            
            // olderPrice_ => temp_
            temp_ = (dexVariables_ >> 1) & X40;
            temp_ = (temp_ >> DEFAULT_EXPONENT_SIZE) << (temp_ & DEFAULT_EXPONENT_MASK);

            // oldPrice_ => temp2_
            temp2_ = (dexVariables_ >> 41) & X40;
            temp2_ = (temp2_ >> DEFAULT_EXPONENT_SIZE) << (temp2_ & DEFAULT_EXPONENT_MASK);

            // check newPrice_ & oldPrice_ difference should not be more than 5%
            // old price w.r.t new price
            int priceDiff_ = int(ORACLE_PRECISION) - int((temp2_ * ORACLE_PRECISION) / newPrice_);

            if ((priceDiff_ > int(ORACLE_LIMIT)) || (priceDiff_ < -int(ORACLE_LIMIT))) {
                // if oracle price difference is more than 5% then revert
                // in 1 swap price should only change by <= 5%
                // if a total fall by let's say 8% then in current block price can only fall by 5% and
                // in next block it'll fall the remaining 3%
                revert FluidDexError(ErrorTypes.DexT1__OracleUpdateHugeSwapDiff);
            }

            // older price w.r.t old price
            priceDiff_ = int(ORACLE_PRECISION) - int((temp_ * ORACLE_PRECISION) / temp2_);

            // priceDiffInPercentAndSign_ => temp3_
            // priceDiff_ will always be lower than ORACLE_LIMIT due to above check
            if (priceDiff_ < 0) {
                temp3_ = (uint(-priceDiff_) * X22 / ORACLE_LIMIT) << 1;
            } else {
                // if greater than or equal to 0 then make sign flag 1
                temp3_ = ((uint(priceDiff_) * X22 / ORACLE_LIMIT) << 1) | 1;
            }
            
            if (timeDiff_ > X22) {
                // if time difference is this then that means DEX has been inactive ~45 days
                // that means oracle price of this DEX should not be used.
                timeDiff_ = X22;
            }

            // temp_ => lastTimeDiff_
            temp_ = (dexVariables_ >> 154) & X22;
            uint nextOracleSlot_ = ((dexVariables_ >> 176) & X3);
            uint oracleMap_ = (dexVariables_ >> 179) & X16;
            if (temp_ > X9) {
                if (nextOracleSlot_ > 0) {
                    // if greater than 0 then current slot has 2 or more oracle slot empty
                    // First 9 bits are of time, so not using that
                    temp3_ = (temp3_ << 41) | (temp_ << 9);
                    _oracle[oracleMap_] = _oracle[oracleMap_] | (temp3_ << (--nextOracleSlot_ * 32));
                    if (nextOracleSlot_ > 0) {
                        --nextOracleSlot_;
                    } else {
                        // if == 0 that means the oracle slots will get filled and shift to next oracle map
                        nextOracleSlot_ = 7;
                        oracleMap_ = (oracleMap_ + 1) % TOTAL_ORACLE_MAPPING;
                        _oracle[oracleMap_] = 0;
                    }
                } else {
                    // if == 0
                    // then seconds will be in last map
                    // precision will be in last map + 1
                    // Storing precision & sign slot in first precision & sign slot and leaving time slot empty
                    temp3_ = temp3_ << 9;
                    _oracle[oracleMap_] = _oracle[oracleMap_] | temp3_;
                    nextOracleSlot_ = 6; // storing 6 here as 7 is going to occupied right now
                    oracleMap_ = (oracleMap_ + 1) % TOTAL_ORACLE_MAPPING;
                    // Storing time in 2nd precision & sign and leaving time slot empty
                    _oracle[oracleMap_] = temp_ << ((7 * 32) + 9);
                }
            } else {
                temp3_ = (temp3_ << 9) | temp_;
                if (nextOracleSlot_ < 7) {
                    _oracle[oracleMap_] = _oracle[oracleMap_] | (temp3_ << (nextOracleSlot_ * 32));
                } else {
                    _oracle[oracleMap_] = temp3_ << ((7 * 32));
                }
                if (nextOracleSlot_ > 0) {
                    --nextOracleSlot_;
                } else {
                    nextOracleSlot_ = 7;
                    oracleMap_ = (oracleMap_ + 1) % TOTAL_ORACLE_MAPPING;
                }
            }

            // doing this due to stack too deep error when using params memory variables
            temp_ = newPrice_;
            temp2_ = centerPrice_;
            temp3_ = dexVariables_;

            // then update last price
            temp3_ = (temp3_ & 0xfffffffffffffff8000000000000000000000000000000000000000000000001) | 
                (((temp3_ >> 41) & X40) << 1) | 
                (temp_.toBigNumber(32, 8, BigMathMinified.ROUND_DOWN) << 41) | 
                (temp2_.toBigNumber(32, 8, BigMathMinified.ROUND_DOWN) << 81) |
                (block.timestamp << 121) | 
                (timeDiff_ << 154) | 
                (nextOracleSlot_ << 176) |
                (oracleMap_ << 179);
        } else {
            // temp_ => oldCenterPrice
            temp_ = (dexVariables_ >> 81) & X40;
            temp_ = (temp_ >> DEFAULT_EXPONENT_SIZE) << (temp_ & DEFAULT_EXPONENT_MASK);

            // Ensure that the center price is within the acceptable range of the old center price if it's not the first swap in the same block
            if (
                (centerPrice_ < ((EIGHT_DECIMALS - 1) * temp_ / EIGHT_DECIMALS)) || 
                (centerPrice_ > ((EIGHT_DECIMALS + 1) * temp_ / EIGHT_DECIMALS))
            ) {
                revert FluidDexError(ErrorTypes.DexT1__CenterPriceOutOfRange);
            }

            // olderPrice_ => temp_
            temp_ = (dexVariables_ >> 1) & X40;
            temp_ = (temp_ >> DEFAULT_EXPONENT_SIZE) << (temp_ & DEFAULT_EXPONENT_MASK);

            // check newPrice_ & olderPrice_ difference should not be more than 5%
            // older price w.r.t new price
            int priceDiff_ = int(ORACLE_PRECISION) - int((temp_ * ORACLE_PRECISION) / newPrice_);

            if ((priceDiff_ > int(ORACLE_LIMIT)) || (priceDiff_ < -int(ORACLE_LIMIT))) {
                // if oracle price difference is more than 5% then revert
                // in 1 swap price should only change by <= 5%
                // if a total fall by let's say 8% then in current block price can only fall by 5% and
                // in next block it'll fall the remaining 3%
                revert FluidDexError(ErrorTypes.DexT1__OracleUpdateHugeSwapDiff);
            }

            // doing this due to stack too deep error when using params memory variables
            temp_ = newPrice_;
            temp3_ = dexVariables_;
            // 2nd swap in same block no need to update anything around oracle, only need to update last swap price in dexVariables
            temp3_ = (temp3_ & 0xfffffffffffffffffffffffffffffffffffffffffffe0000000001ffffffffff) | 
                (temp_.toBigNumber(32, 8, BigMathMinified.ROUND_DOWN) << 41);
        }

        return temp3_;
    }

    function _updatingUserSupplyDataOnStorage(
        uint userSupplyData_,
        uint userSupply_,
        uint newWithdrawalLimit_
    ) internal {
        // calculate withdrawal limit to store as previous withdrawal limit in storage
        newWithdrawalLimit_ = DexCalcs.calcWithdrawalLimitAfterOperate(
            userSupplyData_,
            userSupply_,
            newWithdrawalLimit_
        );

        userSupply_ = userSupply_.toBigNumber(
            DEFAULT_COEFFICIENT_SIZE,
            DEFAULT_EXPONENT_SIZE,
            BigMathMinified.ROUND_DOWN
        );

        newWithdrawalLimit_ = newWithdrawalLimit_.toBigNumber(
            DEFAULT_COEFFICIENT_SIZE,
            DEFAULT_EXPONENT_SIZE,
            BigMathMinified.ROUND_DOWN
        );

        if (((userSupplyData_ >> DexSlotsLink.BITS_USER_SUPPLY_AMOUNT) & X64) == userSupply_) {
            // make sure that shares amount is not so small that it wouldn't affect storage update. if a difference
            // is present then rounding will be in the right direction to avoid any potential manipulation.
            revert FluidDexError(ErrorTypes.DexT1__SharesAmountInsufficient);
        }

        // Updating on storage, copied exactly the same from Liquidity Layer
        _userSupplyData[msg.sender] =
            // mask to update bits 1-161 (supply amount, withdrawal limit, timestamp)
            (userSupplyData_ & 0xfffffffffffffffffffffffc0000000000000000000000000000000000000001) |
            (userSupply_ << DexSlotsLink.BITS_USER_SUPPLY_AMOUNT) | // converted to BigNumber can not overflow
            (newWithdrawalLimit_ << DexSlotsLink.BITS_USER_SUPPLY_PREVIOUS_WITHDRAWAL_LIMIT) | // converted to BigNumber can not overflow
            (block.timestamp << DexSlotsLink.BITS_USER_SUPPLY_LAST_UPDATE_TIMESTAMP);
    }

    function _updatingUserBorrowDataOnStorage(
        uint userBorrowData_,
        uint userBorrow_,
        uint newBorrowLimit_
    ) internal {
        // calculate borrow limit to store as previous borrow limit in storage
        newBorrowLimit_ = DexCalcs.calcBorrowLimitAfterOperate(userBorrowData_, userBorrow_, newBorrowLimit_);

        // Converting user's borrowings into bignumber
        userBorrow_ = userBorrow_.toBigNumber(
            DEFAULT_COEFFICIENT_SIZE,
            DEFAULT_EXPONENT_SIZE,
            BigMathMinified.ROUND_UP
        );

        // Converting borrow limit into bignumber
        newBorrowLimit_ = newBorrowLimit_.toBigNumber(
            DEFAULT_COEFFICIENT_SIZE,
            DEFAULT_EXPONENT_SIZE,
            BigMathMinified.ROUND_DOWN
        );

        if (((userBorrowData_ >> DexSlotsLink.BITS_USER_BORROW_AMOUNT) & X64) == userBorrow_) {
            // make sure that shares amount is not so small that it wouldn't affect storage update. if a difference
            // is present then rounding will be in the right direction to avoid any potential manipulation.
            revert FluidDexError(ErrorTypes.DexT1__SharesAmountInsufficient);
        }

        // Updating on storage, copied exactly the same from Liquidity Layer
        _userBorrowData[msg.sender] =
            // mask to update bits 1-161 (borrow amount, borrow limit, timestamp)
            (userBorrowData_ & 0xfffffffffffffffffffffffc0000000000000000000000000000000000000001) |
            (userBorrow_ << DexSlotsLink.BITS_USER_BORROW_AMOUNT) | // converted to BigNumber can not overflow
            (newBorrowLimit_ << DexSlotsLink.BITS_USER_BORROW_PREVIOUS_BORROW_LIMIT) | // converted to BigNumber can not overflow
            (block.timestamp << DexSlotsLink.BITS_USER_BORROW_LAST_UPDATE_TIMESTAMP);
    }

    function _utilizationVerify(uint utilizationLimit_, bytes32 exchangePriceSlot_) internal view {
        if (utilizationLimit_ < THREE_DECIMALS) {
            utilizationLimit_ = utilizationLimit_ * 10;
            // extracting utilization of token from liquidity layer
            uint liquidityLayerUtilization_ = LIQUIDITY.readFromStorage(exchangePriceSlot_);
            liquidityLayerUtilization_ = (liquidityLayerUtilization_ >> LiquiditySlotsLink.BITS_EXCHANGE_PRICES_UTILIZATION) & X14;
            // Note: this can go slightly above the utilization limit if no update is written to storage at liquidity layer
            // if swap was not big enough to go far enough above or any other storage update threshold write cause there
            // so just to keep in mind when configuring the actual limit reachable can be utilizationLimit_ + storageUpdateThreshold at Liquidity
            if (liquidityLayerUtilization_ > utilizationLimit_) revert FluidDexError(ErrorTypes.DexT1__LiquidityLayerTokenUtilizationCapReached);
        }
    }

    function _hookVerify(uint hookAddress_, uint mode_, bool swap0to1_, uint price_) internal {
        try IHook(AddressCalcs.addressCalc(DEPLOYER_CONTRACT, hookAddress_)).dexPrice(mode_, swap0to1_, TOKEN_0, TOKEN_1, price_) returns (bool isOk_) {
            if (!isOk_) revert FluidDexError(ErrorTypes.DexT1__HookReturnedFalse);
        } catch (bytes memory /*lowLevelData*/) {
            // skip checking hook nothing
        }
    }

    constructor(ConstantViews memory constantViews_) ImmutableVariables(constantViews_) {}

}
