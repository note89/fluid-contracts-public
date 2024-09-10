// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import { SSTORE2 } from "solmate/src/utils/SSTORE2.sol";

import { Error } from "../../error.sol";
import { ErrorTypes } from "../../errorTypes.sol";
import { IFluidDexFactory } from "../../interfaces/iDexFactory.sol";

import { LiquiditySlotsLink } from "../../../../libraries/liquiditySlotsLink.sol";

import { IFluidDexT1 } from "../../interfaces/iDexT1.sol";
import { FluidDexT1 } from "../../poolT1/coreModule/main.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
}

contract FluidDexT1DeploymentLogic is Error {
    address internal constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev SSTORE2 pointer for the PoolT1 creation code. Stored externally to reduce factory bytecode (in 2 parts)
    address internal immutable POOL_T1_CREATIONCODE_ADDRESS_1;
    address internal immutable POOL_T1_CREATIONCODE_ADDRESS_2;

    /// @notice address of liquidity contract
    address public immutable LIQUIDITY;

    /// @notice address of Admin implementation
    address public immutable ADMIN_IMPLEMENTATION;

    /// @notice address of Deployer Contract
    address public immutable CONTRACT_DEPLOYER;

    /// @notice address of Secondary implementation
    address public immutable SECONDARY_IMPLEMENTATION;

    /// @notice address of this contract
    address public immutable ADDRESS_THIS;

    /// @notice Emitted when a new dexT1 is deployed.
    /// @param dex The address of the newly deployed dex.
    /// @param dexId The id of the newly deployed dex.
    /// @param supplyToken The address of the supply token.
    /// @param borrowToken The address of the borrow token.
    event DexT1Deployed(address indexed dex, uint256 dexId, address indexed supplyToken, address indexed borrowToken);

    constructor(address liquidity_, address dexAdminImplementation_, address contractDeployer_) {
        LIQUIDITY = liquidity_;
        ADMIN_IMPLEMENTATION = dexAdminImplementation_;
        CONTRACT_DEPLOYER = contractDeployer_;

        // split storing creation code into two SSTORE2 pointers, because:
        // due to contract code limits 24576 bytes is the maximum amount of data that can be written in a single pointer / key.
        // Attempting to write more will result in failure.
        // So by splitting in two parts we can make sure that the contract bytecode size can use up the full limit of 24576 bytes.
        uint256 creationCodeLength_ = type(FluidDexT1).creationCode.length;
        POOL_T1_CREATIONCODE_ADDRESS_1 = SSTORE2.write(
            _bytesSlice(type(FluidDexT1).creationCode, 0, creationCodeLength_ / 2)
        );
        // slice lengths:
        // when even length, e.g. 250:
        //      part 1 = 0 -> 250 / 2, so 0 until 125 length, so 0 -> 125
        //      part 2 = 250 / 2 -> 250 - 250 / 2, so 125 until 125 length, so 125 -> 250
        // when odd length: e.g. 251:
        //      part 1 = 0 -> 251 / 2, so 0 until 125 length, so 0 -> 125
        //      part 2 = 251 / 2 -> 251 - 251 / 2, so 125 until 126 length, so 125 -> 251
        POOL_T1_CREATIONCODE_ADDRESS_2 = SSTORE2.write(
            _bytesSlice(
                type(FluidDexT1).creationCode,
                creationCodeLength_ / 2,
                creationCodeLength_ - creationCodeLength_ / 2
            )
        );

        ADDRESS_THIS = address(this);
    }

    function dexT1(
        address token0_,
        address token1_,
        uint256 oracleMapping_
    ) external returns (bytes memory dexCreationBytecode_) {
        if (address(this) == ADDRESS_THIS) revert FluidDexError(ErrorTypes.DexFactory__OnlyDelegateCallAllowed);

        if (token0_ == token1_) revert FluidDexError(ErrorTypes.DexFactory__SameTokenNotAllowed);
        if (token0_ > token1_) revert FluidDexError(ErrorTypes.DexFactory__TokenConfigNotProper);

        IFluidDexT1.ConstantViews memory constants_;
        constants_.liquidity = LIQUIDITY;
        constants_.factory = address(this);
        constants_.adminImplementation = ADMIN_IMPLEMENTATION;
        constants_.deployerContract = CONTRACT_DEPLOYER;
        constants_.token0 = token0_;
        constants_.token1 = token1_;
        constants_.dexId = IFluidDexFactory(address(this)).totalDexes();
        constants_.oracleMapping = oracleMapping_;

        address dex_ = IFluidDexFactory(address(this)).getDexAddress(constants_.dexId);

        constants_ = _calculateLiquidityDexSlots(constants_, dex_);

        dexCreationBytecode_ = abi.encodePacked(dexT1CreationBytecode(), abi.encode(constants_));

        emit DexT1Deployed(dex_, constants_.dexId, token0_, token1_);

        return dexCreationBytecode_;
    }

    /// @notice returns the stored DexT1 creation bytecode
    function dexT1CreationBytecode() public view returns (bytes memory) {
        return _bytesConcat(SSTORE2.read(POOL_T1_CREATIONCODE_ADDRESS_1), SSTORE2.read(POOL_T1_CREATIONCODE_ADDRESS_2));
    }

    /// @dev                          Calculates the liquidity dex slots for the given supply token, borrow token, and dex (`dex_`).
    /// @param constants_             Constants struct as used in Dex T1
    /// @param dex_                   The address of the dex.
    /// @return liquidityDexSlots_    Returns the calculated liquidity dex slots set in the `IFluidDexT1.ConstantViews` struct.
    function _calculateLiquidityDexSlots(
        IFluidDexT1.ConstantViews memory constants_,
        address dex_
    ) private pure returns (IFluidDexT1.ConstantViews memory) {
        constants_.supplyToken0Slot = LiquiditySlotsLink.calculateDoubleMappingStorageSlot(
            LiquiditySlotsLink.LIQUIDITY_USER_SUPPLY_DOUBLE_MAPPING_SLOT,
            dex_,
            constants_.token0
        );
        constants_.borrowToken0Slot = LiquiditySlotsLink.calculateDoubleMappingStorageSlot(
            LiquiditySlotsLink.LIQUIDITY_USER_BORROW_DOUBLE_MAPPING_SLOT,
            dex_,
            constants_.token0
        );
        constants_.supplyToken1Slot = LiquiditySlotsLink.calculateDoubleMappingStorageSlot(
            LiquiditySlotsLink.LIQUIDITY_USER_SUPPLY_DOUBLE_MAPPING_SLOT,
            dex_,
            constants_.token1
        );
        constants_.borrowToken1Slot = LiquiditySlotsLink.calculateDoubleMappingStorageSlot(
            LiquiditySlotsLink.LIQUIDITY_USER_BORROW_DOUBLE_MAPPING_SLOT,
            dex_,
            constants_.token1
        );
        constants_.exchangePriceToken0Slot = LiquiditySlotsLink.calculateMappingStorageSlot(
            LiquiditySlotsLink.LIQUIDITY_EXCHANGE_PRICES_MAPPING_SLOT,
            constants_.token0
        );
        constants_.exchangePriceToken1Slot = LiquiditySlotsLink.calculateMappingStorageSlot(
            LiquiditySlotsLink.LIQUIDITY_EXCHANGE_PRICES_MAPPING_SLOT,
            constants_.token1
        );

        return constants_;
    }

    // @dev taken from https://github.com/GNSPS/solidity-bytes-utils/blob/master/contracts/BytesLib.sol
    function _bytesConcat(bytes memory _preBytes, bytes memory _postBytes) private pure returns (bytes memory) {
        bytes memory tempBytes;

        assembly {
            // Get a location of some free memory and store it in tempBytes as
            // Solidity does for memory variables.
            tempBytes := mload(0x40)

            // Store the length of the first bytes array at the beginning of
            // the memory for tempBytes.
            let length := mload(_preBytes)
            mstore(tempBytes, length)

            // Maintain a memory counter for the current write location in the
            // temp bytes array by adding the 32 bytes for the array length to
            // the starting location.
            let mc := add(tempBytes, 0x20)
            // Stop copying when the memory counter reaches the length of the
            // first bytes array.
            let end := add(mc, length)

            for {
                // Initialize a copy counter to the start of the _preBytes data,
                // 32 bytes into its memory.
                let cc := add(_preBytes, 0x20)
            } lt(mc, end) {
                // Increase both counters by 32 bytes each iteration.
                mc := add(mc, 0x20)
                cc := add(cc, 0x20)
            } {
                // Write the _preBytes data into the tempBytes memory 32 bytes
                // at a time.
                mstore(mc, mload(cc))
            }

            // Add the length of _postBytes to the current length of tempBytes
            // and store it as the new length in the first 32 bytes of the
            // tempBytes memory.
            length := mload(_postBytes)
            mstore(tempBytes, add(length, mload(tempBytes)))

            // Move the memory counter back from a multiple of 0x20 to the
            // actual end of the _preBytes data.
            mc := end
            // Stop copying when the memory counter reaches the new combined
            // length of the arrays.
            end := add(mc, length)

            for {
                let cc := add(_postBytes, 0x20)
            } lt(mc, end) {
                mc := add(mc, 0x20)
                cc := add(cc, 0x20)
            } {
                mstore(mc, mload(cc))
            }

            // Update the free-memory pointer by padding our last write location
            // to 32 bytes: add 31 bytes to the end of tempBytes to move to the
            // next 32 byte block, then round down to the nearest multiple of
            // 32. If the sum of the length of the two arrays is zero then add
            // one before rounding down to leave a blank 32 bytes (the length block with 0).
            mstore(
                0x40,
                and(
                    add(add(end, iszero(add(length, mload(_preBytes)))), 31),
                    not(31) // Round down to the nearest 32 bytes.
                )
            )
        }

        return tempBytes;
    }

    // @dev taken from https://github.com/GNSPS/solidity-bytes-utils/blob/master/contracts/BytesLib.sol
    function _bytesSlice(bytes memory _bytes, uint256 _start, uint256 _length) private pure returns (bytes memory) {
        require(_length + 31 >= _length, "slice_overflow");
        require(_bytes.length >= _start + _length, "slice_outOfBounds");

        bytes memory tempBytes;

        assembly {
            switch iszero(_length)
            case 0 {
                // Get a location of some free memory and store it in tempBytes as
                // Solidity does for memory variables.
                tempBytes := mload(0x40)

                // The first word of the slice result is potentially a partial
                // word read from the original array. To read it, we calculate
                // the length of that partial word and start copying that many
                // bytes into the array. The first word we copy will start with
                // data we don't care about, but the last `lengthmod` bytes will
                // land at the beginning of the contents of the new array. When
                // we're done copying, we overwrite the full first word with
                // the actual length of the slice.
                let lengthmod := and(_length, 31)

                // The multiplication in the next line is necessary
                // because when slicing multiples of 32 bytes (lengthmod == 0)
                // the following copy loop was copying the origin's length
                // and then ending prematurely not copying everything it should.
                let mc := add(add(tempBytes, lengthmod), mul(0x20, iszero(lengthmod)))
                let end := add(mc, _length)

                for {
                    // The multiplication in the next line has the same exact purpose
                    // as the one above.
                    let cc := add(add(add(_bytes, lengthmod), mul(0x20, iszero(lengthmod))), _start)
                } lt(mc, end) {
                    mc := add(mc, 0x20)
                    cc := add(cc, 0x20)
                } {
                    mstore(mc, mload(cc))
                }

                mstore(tempBytes, _length)

                //update free-memory pointer
                //allocating the array padded to 32 bytes like the compiler does now
                mstore(0x40, and(add(mc, 31), not(31)))
            }
            //if we want a zero-length slice let's just return a zero-length array
            default {
                tempBytes := mload(0x40)
                //zero out the 32 bytes slice we are about to return
                //we need to do it because Solidity does not garbage collect
                mstore(tempBytes, 0)

                mstore(0x40, add(tempBytes, 0x20))
            }
        }

        return tempBytes;
    }
}
