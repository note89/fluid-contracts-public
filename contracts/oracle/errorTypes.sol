// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

library ErrorTypes {
    /***********************************|
    |           FluidOracleL2           | 
    |__________________________________*/

    /// @notice thrown when sequencer on a L2 has an outage and grace period has not yet passed.
    uint256 internal constant FluidOracleL2__SequencerOutage = 60000;

    /***********************************|
    |     UniV3CheckCLRSOracle          | 
    |__________________________________*/

    /// @notice thrown when the delta between main price source and check rate source is exceeding the allowed delta
    uint256 internal constant UniV3CheckCLRSOracle__InvalidPrice = 60001;

    /// @notice thrown when an invalid parameter is passed to a method
    uint256 internal constant UniV3CheckCLRSOracle__InvalidParams = 60002;

    /// @notice thrown when the exchange rate is zero, even after all possible fallbacks depending on config
    uint256 internal constant UniV3CheckCLRSOracle__ExchangeRateZero = 60003;

    /***********************************|
    |           FluidOracle             | 
    |__________________________________*/

    /// @notice thrown when an invalid info name is passed into a fluid oracle (e.g. not set or too long)
    uint256 internal constant FluidOracle__InvalidInfoName = 60010;

    /***********************************|
    |            sUSDe Oracle           | 
    |__________________________________*/

    /// @notice thrown when an invalid parameter is passed to a method
    uint256 internal constant SUSDeOracle__InvalidParams = 60102;

    /***********************************|
    |           Pendle Oracle           | 
    |__________________________________*/

    /// @notice thrown when an invalid parameter is passed to a method
    uint256 internal constant PendleOracle__InvalidParams = 60201;

    /// @notice thrown when the Pendle market Oracle has not been initialized yet
    uint256 internal constant PendleOracle__MarketNotInitialized = 60202;

    /// @notice thrown when the Pendle market does not have 18 decimals
    uint256 internal constant PendleOracle__MarketInvalidDecimals = 60203;

    /// @notice thrown when the Pendle market returns an unexpected price
    uint256 internal constant PendleOracle__InvalidPrice = 60204;

    /***********************************|
    |    CLRS2UniV3CheckCLRSOracleL2    | 
    |__________________________________*/

    /// @notice thrown when the exchange rate is zero, even after all possible fallbacks depending on config
    uint256 internal constant CLRS2UniV3CheckCLRSOracleL2__ExchangeRateZero = 60301;

    /***********************************|
    |    Ratio2xFallbackCLRSOracleL2    | 
    |__________________________________*/

    /// @notice thrown when the exchange rate is zero, even after all possible fallbacks depending on config
    uint256 internal constant Ratio2xFallbackCLRSOracleL2__ExchangeRateZero = 60311;

    /***********************************|
    |            WeETHsOracle           | 
    |__________________________________*/

    /// @notice thrown when an invalid parameter is passed to a method
    uint256 internal constant WeETHsOracle__InvalidParams = 60321;

    /***********************************|
    |          Chainlink Oracle         | 
    |__________________________________*/

    /// @notice thrown when an invalid parameter is passed to a method
    uint256 internal constant ChainlinkOracle__InvalidParams = 61001;

    /***********************************|
    |          UniswapV3 Oracle         | 
    |__________________________________*/

    /// @notice thrown when an invalid parameter is passed to a method
    uint256 internal constant UniV3Oracle__InvalidParams = 62001;

    /// @notice thrown when constructor is called with invalid ordered seconds agos values
    uint256 internal constant UniV3Oracle__InvalidSecondsAgos = 62002;

    /// @notice thrown when constructor is called with invalid delta values > 100%
    uint256 internal constant UniV3Oracle__InvalidDeltas = 62003;

    /***********************************|
    |            WstETh Oracle          | 
    |__________________________________*/

    /// @notice thrown when an invalid parameter is passed to a method
    uint256 internal constant WstETHOracle__InvalidParams = 63001;

    /***********************************|
    |           Redstone Oracle         | 
    |__________________________________*/

    /// @notice thrown when an invalid parameter is passed to a method
    uint256 internal constant RedstoneOracle__InvalidParams = 64001;

    /***********************************|
    |          Fallback Oracle          | 
    |__________________________________*/

    /// @notice thrown when an invalid parameter is passed to a method
    uint256 internal constant FallbackOracle__InvalidParams = 65001;

    /***********************************|
    |       FallbackCLRSOracle          | 
    |__________________________________*/

    /// @notice thrown when the exchange rate is zero, even for the fallback oracle source (if enabled)
    uint256 internal constant FallbackCLRSOracle__ExchangeRateZero = 66001;

    /***********************************|
    |         WstETHCLRSOracle          | 
    |__________________________________*/

    /// @notice thrown when the exchange rate is zero, even for the fallback oracle source (if enabled)
    uint256 internal constant WstETHCLRSOracle__ExchangeRateZero = 67001;

    /***********************************|
    |        CLFallbackUniV3Oracle      | 
    |__________________________________*/

    /// @notice thrown when the exchange rate is zero, even for the uniV3 rate
    uint256 internal constant CLFallbackUniV3Oracle__ExchangeRateZero = 68001;

    /***********************************|
    |  WstETHCLRS2UniV3CheckCLRSOracle  | 
    |__________________________________*/

    /// @notice thrown when the exchange rate is zero, even for the uniV3 rate
    uint256 internal constant WstETHCLRS2UniV3CheckCLRSOracle__ExchangeRateZero = 69001;

    /***********************************|
    |             WeETh Oracle          | 
    |__________________________________*/

    /// @notice thrown when an invalid parameter is passed to a method
    uint256 internal constant WeETHOracle__InvalidParams = 70001;
}
