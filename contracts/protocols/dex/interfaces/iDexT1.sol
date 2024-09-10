// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

interface IFluidDexT1 {
    /// @notice returns the dex id
    function DEX_ID() external view returns (uint256);

    /// @notice reads uint256 data `result_` from storage at a bytes32 storage `slot_` key.
    function readFromStorage(bytes32 slot_) external view returns (uint256 result_);

    struct ConstantViews {
        uint256 dexId;
        address liquidity;
        address factory;
        address adminImplementation;
        address deployerContract;
        address token0;
        address token1;
        bytes32 supplyToken0Slot;
        bytes32 borrowToken0Slot;
        bytes32 supplyToken1Slot;
        bytes32 borrowToken1Slot;
        bytes32 exchangePriceToken0Slot;
        bytes32 exchangePriceToken1Slot;
        uint256 oracleMapping;
        // TODO: need for any decimals?
    }
    
    function constantsView() external view returns (ConstantViews memory constantsView_);

    struct ConstantViews2 {
        uint token0NumeratorPrecision;
        uint token0DenominatorPrecision;
        uint token1NumeratorPrecision;
        uint token1DenominatorPrecision;
    }

    function constantsView2() external view returns (ConstantViews2 memory constantsView2_);

    function swapIn(
        bool swap0to1_,
        uint256 amountIn_,
        uint256 amountOutMin_,
        address to_
    ) external payable returns (uint256 amountOut_);

    function swapOut(
        bool swap0to1_,
        uint256 amountOut_,
        uint256 amountInMax_,
        address to_
    ) external payable returns (uint256 amountIn_);

    function depositPerfect(
        uint shares_,
        uint maxToken0Deposit_,
        uint maxToken1Deposit_,
        bool estimate_
    ) external payable returns (uint token0Amt_, uint token1Amt_);

    function withdrawPerfect(
        uint shares_,
        uint minToken0Withdraw_,
        uint minToken1Withdraw_,
        bool estimate_
    ) external returns (uint token0Amt_, uint token1Amt_);

    function borrowPerfect(
        uint shares_,
        uint minToken0Borrow_,
        uint minToken1Borrow_,
        bool estimate_
    ) external returns (uint token0Amt_, uint token1Amt_);

    function paybackPerfect(
        uint shares_,
        uint maxToken0Payback_,
        uint maxToken1Payback_,
        bool estimate_
    ) external payable returns (uint token0Amt_, uint token1Amt_);

    function deposit(
        uint token0Amt_,
        uint token1Amt_,
        uint minSharesAmt_,
        bool estimate_
    ) external payable returns (uint shares_);

    function withdraw(
        uint token0Amt_,
        uint token1Amt_,
        uint maxSharesAmt_,
        bool estimate_
    ) external returns (uint shares_);

    function borrow(
        uint token0Amt_,
        uint token1Amt_,
        uint maxSharesAmt_,
        bool estimate_
    ) external returns (uint shares_);

    function payback(
        uint token0Amt_,
        uint token1Amt_,
        uint minSharesAmt_,
        bool estimate_
    ) external payable returns (uint shares_);

    function getPricesAndExchangePrices() external;
    
}