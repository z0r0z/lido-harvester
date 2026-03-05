// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Script.sol";
import {LidoHarvester, IERC20} from "../src/LidoHarvester.sol";

interface ICurvePool {
    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256);
}

contract Harvest is Script {
    address constant HARVESTER = 0x0000000000BB8A44A568Ff0a9ef0E7fc20768E22;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    function run() public {
        LidoHarvester h = LidoHarvester(payable(HARVESTER));

        uint256 staked = h.staked();
        uint256 stethBal = IERC20(STETH).balanceOf(HARVESTER);
        uint256 ethBal = HARVESTER.balance;
        address target = h.target();
        uint16 slipBps = h.slipBps();

        console.log("=== Harvester State ===");
        console.log("stETH balance:", stethBal);
        console.log("staked:       ", staked);
        console.log("ETH balance:  ", ethBal);
        console.log("target:       ", target);
        console.log("slipBps:      ", slipBps);

        if (stethBal <= staked) {
            console.log("");
            console.log("No yield available to harvest.");
            _writeJson(HarvestResult(0, 0, 0, 0, false, ""));
            return;
        }

        uint256 yield_ = stethBal - staked;
        uint256 minEthRequired = yield_ * (10000 - slipBps) / 10000;

        console.log("");
        console.log("=== Yield ===");
        console.log("yield (wei):  ", yield_);
        console.log("min ETH req:  ", minEthRequired);

        // Query Curve for expected output
        uint256 expectedOut = ICurvePool(target).get_dy(1, 0, yield_);
        console.log("curve get_dy: ", expectedOut);
        console.log("passes check: ", expectedOut >= minEthRequired);

        if (expectedOut < minEthRequired) {
            console.log("");
            console.log("WARN: Curve output below contract slippage floor. Harvest would revert.");
            _writeJson(HarvestResult(yield_, expectedOut, 0, 0, false, ""));
            return;
        }

        // min_dy: tighten from Curve quote with 0.5% buffer, but never below contract's slippage floor
        uint256 minDy = expectedOut * 9950 / 10000;
        if (minDy < minEthRequired) minDy = minEthRequired;
        bytes memory curveData = abi.encodeCall(ICurvePool.exchange, (int128(1), int128(0), yield_, minDy));
        bytes memory harvestCalldata = abi.encodeCall(h.harvest, (curveData));

        console.log("min_dy:       ", minDy);

        // Estimate gas via RPC
        string memory estimateParams = string.concat(
            '[{"to":"',
            vm.toString(HARVESTER),
            '","data":"',
            vm.toString(harvestCalldata),
            '"},"latest"]'
        );
        bytes memory gasEstimateBytes = vm.rpc("eth_estimateGas", estimateParams);
        uint256 gasEstimate = vm.parseUint(vm.toString(gasEstimateBytes));

        // Live gas price from RPC (includes base fee + priority fee)
        bytes memory gasPriceBytes = vm.rpc("eth_gasPrice", "[]");
        uint256 gasPrice = vm.parseUint(vm.toString(gasPriceBytes));
        uint256 gasCost = gasEstimate * gasPrice;

        console.log("");
        console.log("=== Profitability ===");
        console.log("gas estimate: ", gasEstimate, "(from eth_estimateGas)");
        console.log("gas price:    ", gasPrice, "wei (from eth_gasPrice)");
        console.log("gas cost:     ", gasCost, "wei");

        bool profitable = expectedOut > gasCost;
        if (profitable) {
            console.log("net profit:   ", expectedOut - gasCost, "wei");
            console.log("PROFITABLE");
        } else {
            console.log("net loss:     ", gasCost - expectedOut, "wei");
            console.log("NOT PROFITABLE - wait for more yield to accrue");
        }

        console.log("");
        console.log("=== Harvest Call ===");
        console.log("to:   ", HARVESTER);
        console.log("sig:   harvest(bytes)");
        console.log("");
        console.log("cast send", HARVESTER);
        console.log('  "harvest(bytes)" \\');
        console.log("  ", vm.toString(curveData));

        _writeJson(HarvestResult(yield_, expectedOut, gasEstimate, gasPrice, profitable, vm.toString(curveData)));
    }

    struct HarvestResult {
        uint256 yield_;
        uint256 expectedOut;
        uint256 gasEstimate;
        uint256 gasPrice;
        bool profitable;
        string curveData;
    }

    function _writeJson(HarvestResult memory r) internal {
        string memory obj = "harvest";
        vm.serializeAddress(obj, "harvester", HARVESTER);
        vm.serializeUint(obj, "yield", r.yield_);
        vm.serializeUint(obj, "expectedOut", r.expectedOut);
        vm.serializeUint(obj, "gasEstimate", r.gasEstimate);
        vm.serializeUint(obj, "gasPrice", r.gasPrice);
        vm.serializeUint(obj, "gasCost", r.gasEstimate * r.gasPrice);
        vm.serializeBool(obj, "profitable", r.profitable);
        string memory json = vm.serializeString(obj, "curveData", r.curveData);
        vm.writeJson(json, "harvest-output.json");
    }
}
