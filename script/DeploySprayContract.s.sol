// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {SprayContract} from "../src/SprayContract.sol";

/**
 * Deploys SprayContract. The deployer becomes the owner and the fee recipient, at 30 bps.
 *
 * forge script script/DeploySprayContract.s.sol:DeploySprayContractScript -vvv \
 *     --rpc-url base \
 *     --broadcast
 */
contract DeploySprayContractScript is Script {
    uint256 internal constant FEE_BPS = 30;

    function run() public returns (SprayContract spray) {
        uint256 deployerKey = vm.envUint("SPRAY_DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        console2.log("Deployer / fee recipient", deployer);
        console2.log("Fee bps", FEE_BPS);

        vm.startBroadcast(deployerKey);
        spray = new SprayContract(deployer, FEE_BPS);
        vm.stopBroadcast();

        console2.log("SprayContract", address(spray));
    }
}
