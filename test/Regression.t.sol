// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ShadowCore} from "../src/ShadowCore.sol";

/// @notice 小美回归测试（本地副本专用）：复刻 2026-11-09 真链自测踩到的资金困死路径
///         买入 → 结算 → 点亮 → 卖出剩余零头。旧代码在此 panic（darkCount 下溢）。
contract RegressionTest is Test {
    ShadowCore core;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address team = address(0x7E4A);

    function setUp() public {
        vm.roll(1000);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        core = new ShadowCore("Shadow Test", "SHDW", team);
    }

    /// 真链复刻：0.35 HYPE 买入 → settle → consecrate → 卖光零头，必须能卖
    function test_ConsecrateThenSellRemainder() public {
        vm.startPrank(alice);
        core.buy{value: 0.35 ether}(0);
        vm.roll(block.number + 60);
        core.settle();
        uint256 id = core.darkIdsOf(alice)[0];
        core.consecrate(id);

        uint256 dust = core.balanceOf(alice);
        assertGt(dust, 0, "should hold fractional remainder");
        uint256 got = core.sell(dust, 0); // 旧代码在这里 panic 0x11
        assertGt(got, 0, "remainder must be sellable after consecrate");
        assertEq(core.balanceOf(alice), 0);
        assertEq(core.darkOf(alice), 0);
        assertEq(core.owedOf(alice), 0);
        assertTrue(core.lit(id), "lit must survive the sell");
        vm.stopPrank();
    }

    /// 点亮一台之后，其余 DARK 仍可正常溶解/卖出，且可再次买入抽取
    function test_ConsecrateOneOfManyThenExitAndReenter() public {
        vm.startPrank(alice);
        core.buy{value: 2 ether}(0);
        vm.roll(block.number + 60);
        core.settle();
        uint256 id = core.darkIdsOf(alice)[0];
        core.consecrate(id);

        uint256 bal = core.balanceOf(alice);
        core.sell(bal, 0); // 全卖：剩余 DARK 应溶解，不得 panic
        assertEq(core.idBalance(alice), 0);
        assertEq(core.darkOf(alice), 0);

        // 重新买入并抽取应正常
        core.buy{value: 0.35 ether}(0);
        vm.roll(block.number + 60);
        uint256 drawn = core.settle();
        assertEq(drawn, 1);
        vm.stopPrank();
    }
}
