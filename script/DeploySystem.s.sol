// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, stdJson} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {RebateHook} from "../src/hook/RebateHook.sol";
import {PoolRegistry} from "../src/registry/PoolRegistry.sol";
import {PayoutLedger} from "../src/rewards/PayoutLedger.sol";
import {SwapRouter} from "../src/periphery/SwapRouter.sol";
import {Create2Factory} from "../src/periphery/Create2Factory.sol";

/// @notice Step 1 — deploy the protocol system:
///         registry → factory → ledger → CREATE2-mined RebateHook (mask 0x1040)
///         → wiring → router; appends addresses to deployments/deployment.json.
contract DeploySystem is Script {
    using stdJson for string;

    /// v4-core v4.0.0 permission bits: AFTER_INITIALIZE (1<<12) | AFTER_SWAP (1<<6)
    uint160 internal constant NEEDED_MASK = (1 << 12) | (1 << 6);
    uint160 internal constant ALL_HOOK_MASK = (1 << 14) - 1;

    function run() external returns (address hookAddr) {
        string memory infra = vm.readFile("deployments/deployment.json");
        address manager = infra.readAddress(".poolManager");
        require(manager != address(0), "run DeployInfrastructure first");

        vm.startBroadcast();

        PoolRegistry registry = new PoolRegistry();
        Create2Factory factory = new Create2Factory();
        PayoutLedger ledger = new PayoutLedger(msg.sender);

        // mine a salt so the CREATE2 hook address carries exactly 0x1040
        bytes memory initCode = abi.encodePacked(
            type(RebateHook).creationCode, abi.encode(IPoolManager(manager), registry, ledger, msg.sender)
        );
        bytes32 salt = _mineSalt(address(factory), keccak256(initCode));
        hookAddr = factory.deploy(initCode, salt);
        require(uint160(hookAddr) & ALL_HOOK_MASK == NEEDED_MASK, "hook mask mismatch");

        // wiring
        ledger.bindHook(hookAddr);
        registry.setHook(hookAddr);

        SwapRouter router = new SwapRouter(IPoolManager(manager));

        vm.stopBroadcast();

        // ---- record: rebuild the full deployment file (infra keys + system keys) ---- //
        string memory json = "all";
        vm.serializeAddress(json, "deployer", infra.readAddress(".deployer"));
        vm.serializeAddress(json, "wrappedNative", infra.readAddress(".wrappedNative"));
        vm.serializeAddress(json, "baseToken", infra.readAddress(".baseToken"));
        vm.serializeAddress(json, "quoteToken", infra.readAddress(".quoteToken"));
        vm.serializeAddress(json, "poolManager", manager);
        vm.serializeAddress(json, "permit2", infra.readAddress(".permit2"));
        vm.serializeAddress(json, "stateView", infra.readAddress(".stateView"));
        vm.serializeAddress(json, "quoter", infra.readAddress(".quoter"));
        vm.serializeAddress(json, "positionDescriptor", infra.readAddress(".positionDescriptor"));
        vm.serializeAddress(json, "positionManager", infra.readAddress(".positionManager"));
        vm.serializeAddress(json, "registry", address(registry));
        vm.serializeAddress(json, "create2Factory", address(factory));
        vm.serializeAddress(json, "payoutLedger", address(ledger));
        vm.serializeAddress(json, "rebateHook", hookAddr);
        vm.serializeBytes32(json, "hookSalt", salt);
        string memory out = vm.serializeAddress(json, "swapRouter", address(router));
        vm.writeJson(out, "deployments/deployment.json");

        console.log("PoolRegistry:", address(registry));
        console.log("Create2Factory:", address(factory));
        console.log("PayoutLedger:", address(ledger));
        console.log("RebateHook:", hookAddr);
        console.log("SwapRouter:", address(router));
    }

    function _mineSalt(address deployer, bytes32 codeHash) internal pure returns (bytes32) {
        for (uint256 i = 0; i < 2_000_000; i++) {
            bytes32 salt = keccak256(abi.encode("rebate-hook", i));
            address predicted = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(hex"ff", deployer, salt, codeHash)
                        )
                    )
                )
            );
            if (uint160(predicted) & ALL_HOOK_MASK == NEEDED_MASK) {
                return salt;
            }
        }
        revert("salt mining failed");
    }
}
