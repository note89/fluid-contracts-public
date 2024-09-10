//SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "forge-std/Test.sol";

import { FluidDexT1Admin } from "../../../../../contracts/protocols/dex/poolT1/adminModule/main.sol";
import { FluidDexT1 } from "../../../../../contracts/protocols/dex/poolT1/coreModule/main.sol";
import { FluidDexT1DeploymentLogic } from "../../../../../contracts/protocols/dex/factory/deploymentLogics/poolT1Logic.sol";
import { FluidContractFactory } from "../../../../../contracts/deployer/main.sol";

contract PoolT1DeploymentLogicTest is Test {
    function test_splitsCreationCodeCorrectly() public {
        address dexAdminImplementation_ = address(new FluidDexT1Admin());
        address liquidity = 0x52Aa899454998Be5b000Ad077a46Bbe360F4e497;

        FluidDexT1DeploymentLogic poolT1DeploymentLogic = new FluidDexT1DeploymentLogic(
            address(liquidity),
            dexAdminImplementation_,
            address(new FluidContractFactory(address(0)))
        );

        assertEq(poolT1DeploymentLogic.dexT1CreationBytecode(), type(FluidDexT1).creationCode);
    }
}
