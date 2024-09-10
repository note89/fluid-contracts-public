// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import { IFluidLiquidity } from "../../../../liquidity/interfaces/iLiquidity.sol";
import { Structs } from "./structs.sol";
import { ConstantVariables } from "../common/constantVariables.sol";
import { IFluidDexFactory } from "../../interfaces/iDexFactory.sol";
import { Error } from "../../error.sol";
import { ErrorTypes } from "../../errorTypes.sol";

abstract contract ImmutableVariables is ConstantVariables, Structs, Error {
    /*//////////////////////////////////////////////////////////////
                          CONSTANTS / IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public immutable DEX_ID;

    /// @dev Address of token 0
    address internal immutable TOKEN_0;

    /// @dev Address of token 1
    address internal immutable TOKEN_1;

    uint256 internal immutable TOKEN_0_NUMERATOR_PRECISION;
    uint256 internal immutable TOKEN_0_DENOMINATOR_PRECISION;
    uint256 internal immutable TOKEN_1_NUMERATOR_PRECISION;
    uint256 internal immutable TOKEN_1_DENOMINATOR_PRECISION;

    /// @dev Address of liquidity contract
    IFluidLiquidity internal immutable LIQUIDITY;

    /// @dev Address of DEX factory contract
    IFluidDexFactory internal immutable DEX_FACTORY;

    /// @dev Address of Admin implementation
    address internal immutable ADMIN_IMPLEMENTATION;

    /// @dev Address of contract used for deploying center price & hook related contract
    address internal immutable DEPLOYER_CONTRACT;

    /// @dev Liquidity layer slots
    bytes32 internal immutable SUPPLY_TOKEN_0_SLOT;
    bytes32 internal immutable BORROW_TOKEN_0_SLOT;
    bytes32 internal immutable SUPPLY_TOKEN_1_SLOT;
    bytes32 internal immutable BORROW_TOKEN_1_SLOT;
    bytes32 internal immutable EXCHANGE_PRICE_TOKEN_0_SLOT;
    bytes32 internal immutable EXCHANGE_PRICE_TOKEN_1_SLOT;
    uint256 internal immutable TOTAL_ORACLE_MAPPING;

    /// @notice returns all Vault constants
    function constantsView() external view returns (ConstantViews memory constantsView_) {
        constantsView_.dexId = DEX_ID;
        constantsView_.liquidity = address(LIQUIDITY);
        constantsView_.factory = address(DEX_FACTORY);
        constantsView_.token0 = TOKEN_0;
        constantsView_.token1 = TOKEN_1;
        constantsView_.adminImplementation = ADMIN_IMPLEMENTATION;
        constantsView_.deployerContract = DEPLOYER_CONTRACT;
        constantsView_.supplyToken0Slot = SUPPLY_TOKEN_0_SLOT;
        constantsView_.borrowToken0Slot = BORROW_TOKEN_0_SLOT;
        constantsView_.supplyToken1Slot = SUPPLY_TOKEN_1_SLOT;
        constantsView_.borrowToken1Slot = BORROW_TOKEN_1_SLOT;
        constantsView_.exchangePriceToken0Slot = EXCHANGE_PRICE_TOKEN_0_SLOT;
        constantsView_.exchangePriceToken1Slot = EXCHANGE_PRICE_TOKEN_1_SLOT;
        constantsView_.oracleMapping = TOTAL_ORACLE_MAPPING;
    }

    /// @notice returns all Vault constants
    function constantsView2() external view returns (ConstantViews2 memory constantsView2_) {
        constantsView2_.token0NumeratorPrecision = TOKEN_0_NUMERATOR_PRECISION;
        constantsView2_.token0DenominatorPrecision = TOKEN_0_DENOMINATOR_PRECISION;
        constantsView2_.token1NumeratorPrecision = TOKEN_1_NUMERATOR_PRECISION;
        constantsView2_.token1DenominatorPrecision = TOKEN_1_DENOMINATOR_PRECISION;
    }

    function _calcNumeratorAndDenominator(address token_) private view returns (uint256 numerator_, uint256 denominator_) {
        uint256 decimals_ = _decimals(token_);
        if (decimals_ > TOKENS_DECIMALS_PRECISION) {
            numerator_ = 1;
            denominator_ = 10**(decimals_ - TOKENS_DECIMALS_PRECISION);
        } else {
            numerator_ = 10**(TOKENS_DECIMALS_PRECISION - decimals_);
            denominator_ = 1;
        }
    }

    constructor(ConstantViews memory constants_) {
        DEX_ID = constants_.dexId;
        LIQUIDITY = IFluidLiquidity(constants_.liquidity);
        DEX_FACTORY = IFluidDexFactory(constants_.factory);

        TOKEN_0 = constants_.token0;
        TOKEN_1 = constants_.token1;

        if (TOKEN_0 >= TOKEN_1) revert FluidDexError(ErrorTypes.DexT1__Token0ShouldBeSmallerThanToken1);

        (TOKEN_0_NUMERATOR_PRECISION, TOKEN_0_DENOMINATOR_PRECISION) = _calcNumeratorAndDenominator(TOKEN_0);
        (TOKEN_1_NUMERATOR_PRECISION, TOKEN_1_DENOMINATOR_PRECISION) = _calcNumeratorAndDenominator(TOKEN_1);

        ADMIN_IMPLEMENTATION = constants_.adminImplementation;

        DEPLOYER_CONTRACT = constants_.deployerContract;

        SUPPLY_TOKEN_0_SLOT = constants_.supplyToken0Slot;
        BORROW_TOKEN_0_SLOT = constants_.borrowToken0Slot;
        SUPPLY_TOKEN_1_SLOT = constants_.supplyToken1Slot;
        BORROW_TOKEN_1_SLOT = constants_.borrowToken1Slot;
        EXCHANGE_PRICE_TOKEN_0_SLOT = constants_.exchangePriceToken0Slot;
        EXCHANGE_PRICE_TOKEN_1_SLOT = constants_.exchangePriceToken1Slot;

        if (constants_.oracleMapping > X16) revert FluidDexError(ErrorTypes.DexT1__OracleMappingOverflow);

        TOTAL_ORACLE_MAPPING = constants_.oracleMapping;
    }

}
