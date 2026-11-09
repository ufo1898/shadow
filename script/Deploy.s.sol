// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ShadowCore} from "../src/ShadowCore.sol";

/// @notice 档 0 部署脚本
/// @dev    用法（环境变量从 .env 或命令行注入）：
///         forge script script/Deploy.s.sol:Deploy \
///           --rpc-url $RPC --private-key $PK --broadcast --legacy
contract Deploy is Script {
    function run() external returns (ShadowCore core) {
        string memory tokenName = vm.envOr("TOKEN_NAME", string("Shadow Test"));
        string memory tokenSymbol = vm.envOr("TOKEN_SYMBOL", string("SHDW"));
        address feeSink = vm.envAddress("FEE_SINK");
        bool doFreeze = vm.envOr("DO_FREEZE", true);

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console2.log("deployer      :", deployer);
        console2.log("deployer bal  :", deployer.balance);
        console2.log("feeSink       :", feeSink);
        console2.log("name / symbol :", tokenName, tokenSymbol);

        vm.startBroadcast(pk);
        core = new ShadowCore(tokenName, tokenSymbol, feeSink);

        // 档 0 默认部署即冻结元数据/费率接收方，防止后续被改
        if (doFreeze) {
            core.freeze();
        }
        vm.stopBroadcast();

        console2.log("");
        console2.log("=== DEPLOYED ===");
        console2.log("ShadowCore    :", address(core));
        console2.log("K             :", core.K());
        console2.log("MAX_ID        :", core.MAX_ID());
        console2.log("poolSize      :", core.poolSize());
        console2.log("tokenReserve  :", core.tokenReserve());
        console2.log("spotPrice     :", core.spotPrice());
        console2.log("costToClear   :", core.costToClear());
        console2.log("totalHype     :", core.totalHype());
        console2.log("frozen        :", core.frozen());
        console2.log("");
        console2.log("Record ShadowCore address, then run script/Verify.s.sol for full self-check");
    }
}
