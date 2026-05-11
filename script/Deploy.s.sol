// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/UMAEvaluator.sol";

contract Deploy is Script {
    // Base Sepolia addresses
    address constant OO_V3         = 0xFd9e2642a170aDD10F53Ee14a93FcF2F31924944;
    address constant USDC          = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant FEE_COLLECTOR = 0x02293c95347e7D61f267C3df62C05570cfe5A3fc;
    uint64  constant LIVENESS      = 7_200;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        UMAEvaluator evaluator = new UMAEvaluator(
            OO_V3,
            USDC,
            FEE_COLLECTOR,
            LIVENESS
        );

        vm.stopBroadcast();

        console.log("UMAEvaluator deployed at:", address(evaluator));
    }
}
