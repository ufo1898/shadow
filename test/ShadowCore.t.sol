// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ShadowCore} from "../src/ShadowCore.sol";

contract ShadowCoreTest is Test {
    ShadowCore core;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address team = address(0x7E4A);

    function setUp() public {
        vm.roll(1000);
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        core = new ShadowCore("Shadow Test", "SHDW", team);
        // 合约初始必须一分 HYPE 都没有（零种子验证）
        assertEq(address(core).balance, 0, "must start with zero seed");
    }

    // ═══════════════ 1. 零种子与曲线 ═══════════════

    function test_ZeroSeed() public view {
        assertEq(core.totalHype(), 0);
        assertEq(core.tokenReserve(), 3333 ether);
        assertEq(core.poolSize(), 3333);
        // 初始边际价格 = VH / (VT + 3333) = 2000 / 6666
        uint256 p = core.spotPrice();
        console2.log("initial spot price (wei per token):", p);
        assertGt(p, 0);
    }

    function test_BuyFollowsCurve() public {
        uint256 before = core.balanceOf(alice);
        vm.prank(alice);
        uint256 out = core.buy{value: 1 ether}(0);
        assertGt(out, 0);
        assertEq(core.balanceOf(alice) - before, out);

        // 手工核对：x = 2000 + 0.97 = 2000.97, y = 6666, newY = K/x（费率 3% 定版）
        uint256 k = core.K();
        uint256 x = 2000 ether + 0.97 ether;
        uint256 newY = k / x;
        uint256 expect = 6666 ether - newY;
        assertApproxEqAbs(out, expect, 1e6, "curve mismatch");

        console2.log("bought tokens for 1 HYPE:", out);
        console2.log("spot price after:", core.spotPrice());
    }

    function test_BuySellRoundTrip() public {
        vm.startPrank(alice);
        uint256 out = core.buy{value: 1 ether}(0);
        uint256 balBefore = alice.balance;
        core.sell(out, 0);
        uint256 got = alice.balance - balBefore;
        vm.stopPrank();

        // 往返只损失两边手续费（各 3%）
        assertLt(got, 1 ether);
        assertGt(got, 0.90 ether, "round trip loss should be ~6%");
        console2.log("round trip: 1 HYPE -> tokens -> HYPE =", got);
    }

    function test_CannotDrainReserve() public {
        vm.prank(alice);
        uint256 out = core.buy{value: 1 ether}(0);
        vm.prank(alice);
        vm.expectRevert();
        core.sell(out * 2, 0);
    }

    function test_CostToClear() public view {
        uint256 cost = core.costToClear();
        console2.log("HYPE needed to buy all 3333 tokens:", cost);
        // 走完整条曲线应等于 VIRTUAL_HYPE
        assertApproxEqAbs(cost, 2000 ether, 1e12);
    }

    // ═══════════════ 2. 抽取：延迟 + blockhash ═══════════════

    function test_SettleRespectsDelay() public {
        vm.prank(alice);
        core.buy{value: 1 ether}(0);

        // 立刻结算必须失败
        vm.prank(alice);
        vm.expectRevert();
        core.settle();

        // 推进 50 块后可结算
        vm.roll(block.number + 50);
        vm.prank(alice);
        uint256 drawn = core.settle();
        assertGt(drawn, 0, "should draw at least one");
        console2.log("drawn count:", drawn);
        assertEq(core.idBalance(alice), drawn);
    }

    function test_SettleExpires() public {
        vm.prank(alice);
        core.buy{value: 1 ether}(0);

        vm.roll(block.number + 300); // 超过 240
        vm.prank(alice);
        vm.expectRevert();
        core.settle();
    }

    function test_SettleIsOneShot() public {
        vm.prank(alice);
        core.buy{value: 1 ether}(0);
        vm.roll(block.number + 60);

        vm.prank(alice);
        core.settle();
        // 已结清，再调无效
        vm.prank(alice);
        vm.expectRevert();
        core.settle();
    }

    function test_BatchLimitKeepsGasBounded() public {
        // 大额买入：850 HYPE 大约能买 ~750 个 token，远超单批上限
        vm.prank(alice);
        uint256 out = core.buy{value: 850 ether}(0);
        console2.log("tokens bought:", out / 1e18);
        assertGt(out / 1e18, 30, "need more than batch limit for this test");

        vm.roll(block.number + 60);
        uint256 g0 = gasleft();
        vm.prank(alice);
        uint256 first = core.settle();
        uint256 gasUsed = g0 - gasleft();

        assertEq(first, 30, "first batch should be capped at 30");
        console2.log("first settle drew:", first, "gas:", gasUsed);
        assertLt(gasUsed, 3_000_000, "single settle must stay under 3M gas");
        assertGt(core.owedOf(alice), 0, "should still owe more");
    }

    function test_SellBeforeSettleDoesNotMintFreeIds() public {
        // 最关键的安全测试：买 → 不结算 → 全卖 → 再结算，不能凭空给 id
        vm.startPrank(alice);
        core.buy{value: 1 ether}(0);
        uint256 bal = core.balanceOf(alice);
        core.sell(bal, 0);

        assertEq(core.darkOf(alice), 0, "darkOf must be 0 after full sell");
        assertEq(core.owedOf(alice), 0, "owed must be 0");

        vm.roll(block.number + 60);
        vm.expectRevert();
        core.settle();
        assertEq(core.idBalance(alice), 0, "must not own any id");
        vm.stopPrank();
    }

    // ═══════════════ 3. 溶解 ═══════════════

    function test_DissolveReturnsIdsToPool() public {
        vm.startPrank(alice);
        core.buy{value: 1 ether}(0);
        vm.roll(block.number + 60);
        core.settle();

        uint256 poolAfterDraw = core.poolSize();
        uint256 idsBefore = core.idBalance(alice);
        require(idsBefore > 0, "need ids");

        // 卖掉部分让余额归零 → 全部 DARK 溶解
        uint256 need = core.balanceOf(alice) - 0.1 ether;
        core.sell(need, 0);
        vm.stopPrank();

        assertEq(core.idBalance(alice), 0, "all dark should dissolve");
        assertEq(core.poolSize(), poolAfterDraw + idsBefore, "ids must return to pool");
    }

    // ═══════════════ 4. 点亮与权重 ═══════════════

    function test_ConsecrateBurnsAndSetsWeight() public {
        vm.startPrank(alice);
        core.buy{value: 2 ether}(0);
        vm.roll(block.number + 60);
        core.settle();

        uint256[] memory ids = core.darkIdsOf(alice);
        require(ids.length > 0, "need at least one id");
        uint256 id = ids[0];

        uint256 supplyBefore = core.totalSupply();
        core.consecrate(id);

        assertEq(core.totalSupply(), supplyBefore - 1 ether, "must burn 1.0");
        assertTrue(core.lit(id));
        assertEq(core.weightOf(id), core.baseWeight(core.generationOf(id)));
        console2.log("generation:", core.generationOf(id));
        console2.log("weight:", core.weightOf(id));
        vm.stopPrank();
    }

    function test_AttuneIncreasesWeight() public {
        vm.startPrank(alice);
        core.buy{value: 3 ether}(0);
        vm.roll(block.number + 60);
        core.settle();
        uint256 id = core.darkIdsOf(alice)[0];

        core.consecrate(id);
        uint256 w0 = core.weightOf(id);

        core.attune(id);
        uint256 w1 = core.weightOf(id);
        assertGt(w1, w0, "attune must increase weight");
        assertApproxEqRel(w1, (w0 * 150) / 100, 1e15, "should be 1.5x");

        core.attune(id);
        assertApproxEqRel(core.weightOf(id), (w0 * 200) / 100, 1e15);
        vm.stopPrank();
    }

    // ═══════════════ 5. 稀有度单调性（修 EM 的缺陷）═══════════════

    function test_WeightIsStrictlyMonotonic() public view {
        uint256 prevW = 0;
        for (uint8 g = 1; g <= 5; g++) {
            uint256 w = core.baseWeight(g);
            assertGt(w, prevW, "weight must be strictly increasing with rarity");
            prevW = w;
        }
        // 具体值核对
        assertEq(core.baseWeight(1), 10_000);
        assertEq(core.baseWeight(2), 14_000);
        assertEq(core.baseWeight(3), 20_000);
        assertEq(core.baseWeight(4), 28_000);
        assertEq(core.baseWeight(5), 40_000);
    }

    function test_GenerationDistribution() public view {
        uint256[6] memory cnt;
        for (uint256 i = 1; i <= 3333; i++) {
            uint8 g = core.generationOf(i);
            assertGe(g, 1);
            assertLe(g, 5);
            cnt[g] += 1;
        }
        console2.log("gen1:", cnt[1]);
        console2.log("gen2:", cnt[2]);
        console2.log("gen3:", cnt[3]);
        console2.log("gen4:", cnt[4]);
        console2.log("gen5:", cnt[5]);
        assertEq(cnt[1] + cnt[2] + cnt[3] + cnt[4] + cnt[5], 3333);

        // 计数器必须严格递减 —— 稀有度与权重反向，绝不能出现 EM 那种"更稀有但同权重"
        assertGt(cnt[1], cnt[2]);
        assertGt(cnt[2], cnt[3]);
        assertGt(cnt[3], cnt[4]);
        assertGt(cnt[4], cnt[5]);
    }

    // ═══════════════ 6. 分红 ═══════════════

    function test_RewardsFlow() public {
        vm.prank(alice);
        core.buy{value: 30 ether}(0);
        vm.roll(block.number + 60);
        vm.prank(alice);
        core.settle();

        uint256 id = core.darkIdsOf(alice)[0];
        vm.prank(alice);
        core.consecrate(id);

        uint256 accBefore = core.accPerWeight();

        // bob 买入产生手续费 → 80% 进奖励池
        vm.prank(bob);
        core.buy{value: 30 ether}(0);

        assertGt(core.accPerWeight(), accBefore, "accPerWeight must grow");

        vm.prank(alice);
        core.settleLit(_one(id));
        vm.prank(alice);
        uint256 got = core.claim();
        assertGt(got, 0, "should claim something");
        console2.log("claimed wei:", got);
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    // ═══════════════ 7. NFT 转移不改状态 ═══════════════

    function test_TransferDoesNotChangeState() public {
        vm.startPrank(alice);
        core.buy{value: 3 ether}(0);
        vm.roll(block.number + 60);
        core.settle();
        uint256 id = core.darkIdsOf(alice)[0];
        core.transferId(bob, id);
        vm.stopPrank();

        assertEq(core.ownerOfId(id), bob);
        assertFalse(core.lit(id), "transfer must not light it");
        assertEq(core.idBalance(alice) + core.idBalance(bob), core.litCount() + core.darkCount());
    }

    // ═══════════════ 8. 权限 ═══════════════

    function test_FreezeBlocksFeeSink() public {
        core.freeze();
        assertTrue(core.frozen());
        vm.expectRevert();
        core.setFeeSink(address(0x1234));
    }

    function test_OnlyOwnerCanFreeze() public {
        vm.prank(alice);
        vm.expectRevert();
        core.freeze();
    }

    // ═══════════════ 9. gas 实测 ═══════════════

    function test_GasReport() public {
        vm.prank(alice);
        uint256 g0 = gasleft();
        core.buy{value: 1 ether}(0);
        uint256 buyGas = g0 - gasleft();

        vm.roll(block.number + 60);
        vm.prank(alice);
        uint256 g1 = gasleft();
        core.settle();
        uint256 settleGas = g1 - gasleft();

        console2.log("buy gas:", buyGas);
        console2.log("settle gas:", settleGas);
        console2.log("buy cost in wei at 0.1 gwei:", buyGas * 0.1 gwei);
        console2.log("settle cost in wei at 0.1 gwei:", settleGas * 0.1 gwei);
    }
}
