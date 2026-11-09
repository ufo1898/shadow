// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ShadowCore} from "../src/ShadowCore.sol";

/// @notice Post-deploy read-only self check. No transactions are sent.
/// @dev    Usage: SHADOW=0x... PRIVATE_KEY=0x... forge script script/Verify.s.sol:Verify --rpc-url $RPC
contract Verify is Script {
    function run() external view {
        address addr = vm.envAddress("SHADOW");
        ShadowCore c = ShadowCore(payable(addr));
        address me = vm.addr(vm.envUint("PRIVATE_KEY"));

        bool ok = true;

        console2.log("========== Shadow stage-0 self check ==========");
        console2.log("contract :", addr);
        console2.log("caller   :", me);
        console2.log("");

        console2.log("--- constants (must match spec) ---");
        console2.log("MAX_ID           :", c.MAX_ID());
        console2.log("UNIT             :", c.UNIT());
        console2.log("FEE_BPS          :", c.FEE_BPS());
        console2.log("VIRTUAL_HYPE     :", c.VIRTUAL_HYPE());
        console2.log("VIRTUAL_TOKEN    :", c.VIRTUAL_TOKEN());
        console2.log("REVEAL_DELAY_MIN :", c.REVEAL_DELAY_MIN());
        console2.log("REVEAL_DELAY_MAX :", c.REVEAL_DELAY_MAX());
        console2.log("MAX_SETTLE_BATCH :", c.MAX_SETTLE_BATCH());
        console2.log("");

        console2.log("--- invariant K ---");
        uint256 kExpected = c.VIRTUAL_HYPE() * (c.VIRTUAL_TOKEN() + c.MAX_ID() * c.UNIT());
        console2.log("K on chain :", c.K());
        console2.log("K expected :", kExpected);
        console2.log("match      :", c.K() == kExpected);
        console2.log("");

        console2.log("--- initial state (fresh deploy must match) ---");
        console2.log("totalHype    :", c.totalHype());
        console2.log("hypeReserve  :", c.hypeReserve());
        console2.log("tokenReserve :", c.tokenReserve());
        console2.log("poolSize     :", c.poolSize());
        console2.log("totalSupply  :", c.totalSupply());
        console2.log("litCount     :", c.litCount());
        console2.log("darkCount    :", c.darkCount());
        console2.log("totalWeight  :", c.totalWeight());
        console2.log("burnedTotal  :", c.burnedTotal());
        console2.log("");

        console2.log("--- price ---");
        console2.log("spotPrice wei   :", c.spotPrice());
        console2.log("costToClear wei :", c.costToClear());
        console2.log("");

        console2.log("--- admin ---");
        console2.log("owner   :", c.owner());
        console2.log("feeSink :", c.feeSink());
        console2.log("frozen  :", c.frozen());
        console2.log("");

        console2.log("--- generation distribution (sampled every 200 ids) ---");
        for (uint256 start = 1; start <= 3201; start += 200) {
            uint256[6] memory cnt;
            uint256 end = start + 199 > c.MAX_ID() ? c.MAX_ID() : start + 199;
            for (uint256 i = start; i <= end; i++) {
                cnt[c.generationOf(i)] += 1;
            }
            console2.log("--- block start (ids 1-based) ---");
            console2.log(start);
            console2.log("g1:", cnt[1]);
            console2.log("g2:", cnt[2]);
            console2.log("g3:", cnt[3]);
            console2.log("g4:", cnt[4]);
            console2.log("g5:", cnt[5]);
        }
        console2.log("");

        console2.log("--- verdict ---");
        if (c.totalHype() != 0) {
            console2.log("!! FAIL: totalHype must be 0 right after deploy (zero-seed)");
            ok = false;
        }
        if (c.poolSize() != 3333) {
            console2.log("!! FAIL: poolSize must be 3333");
            ok = false;
        }
        if (c.tokenReserve() != 3333 ether) {
            console2.log("!! FAIL: tokenReserve must be 3333e18");
            ok = false;
        }
        if (c.K() != kExpected) {
            console2.log("!! FAIL: K mismatch");
            ok = false;
        }
        if (c.MAX_ID() != 3333) {
            console2.log("!! FAIL: MAX_ID must be 3333");
            ok = false;
        }
        if (c.MAX_SETTLE_BATCH() != 30) {
            console2.log("!! FAIL: MAX_SETTLE_BATCH must be 30");
            ok = false;
        }
        if (c.REVEAL_DELAY_MAX() >= 256) {
            console2.log("!! FAIL: REVEAL_DELAY_MAX must stay below 256 (blockhash window)");
            ok = false;
        }
        if (c.owner() != me) {
            console2.log("!! NOTE: caller is not owner (fine for read-only check)");
        }
        if (ok) {
            console2.log("ALL CHECKS PASSED");
        } else {
            console2.log("SOME CHECKS FAILED");
        }
    }
}
