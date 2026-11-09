// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ShadowCore} from "../src/ShadowCore.sol";

/// @notice 小美源码审计探针（本地副本专用，不属于原项目）：验证三个文档看不出的问题
contract ProbeTest is Test {
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

    /// 探针 1：首次抽取结果在调用 settle() 之前即可完整算出
    /// （secret 明文存储 + 上一块 blockhash 已公开 + 初始池为恒等排列）
    function test_Probe_DrawIsPredictable() public {
        vm.prank(alice);
        core.buy{value: 2 ether}(0);
        vm.roll(block.number + 60);

        (, , uint256 secret) = core.pending(alice);
        uint256 h = uint256(blockhash(block.number - 1));
        uint256 seed = uint256(keccak256(abi.encodePacked(h, secret, alice, uint256(0), block.number)));
        uint256 expectId = (seed % core.poolSize()) + 1;

        vm.prank(alice);
        core.settle();
        uint256[] memory ids = core.darkIdsOf(alice);
        console2.log("predicted first id:", expectId, "actual first id:", ids[0]);
        assertEq(ids[0], expectId, "first draw is fully predictable pre-settle");
    }

    /// 探针 2：transferId 把 id 与其代币背书分离后，原钱包补一笔灰尘买入即可重新获得抽取资格
    function test_Probe_TransferIdReEntitles() public {
        vm.startPrank(alice);
        core.buy{value: 2 ether}(0);
        vm.roll(block.number + 60);
        core.settle();
        uint256 idsBefore = core.idBalance(alice);
        uint256 id = core.darkIdsOf(alice)[0];
        core.transferId(bob, id);
        core.buy{value: 0.01 ether}(0); // 灰尘补仓触发 _syncUp 重新授权
        vm.roll(block.number + 60);
        core.settle();
        vm.stopPrank();

        uint256 totalOut = core.idBalance(alice) + core.idBalance(bob);
        console2.log("ids before transfer:", idsBefore, "total ids after re-draw:", totalOut);
        assertGt(totalOut, idsBefore, "ids outstanding exceed original entitlement");
        assertEq(core.ownerOfId(id), bob, "bob keeps the transferred id");
    }

    /// 探针 3：首个 LIT 出现之前收到的手续费池份额停在 reserveForLit，之后永不分发
    function test_Probe_ReserveForLitLocked() public {
        vm.prank(bob);
        core.buy{value: 10 ether}(0); // totalWeight == 0，池份额进 reserveForLit

        vm.startPrank(alice);
        core.buy{value: 30 ether}(0);
        vm.roll(block.number + 60);
        core.settle();
        uint256 id = core.darkIdsOf(alice)[0];
        core.consecrate(id);
        vm.stopPrank();

        uint256 parked = core.reserveForLit();
        assertGt(parked, 0, "pre-LIT fees parked");

        vm.prank(bob);
        core.buy{value: 30 ether}(0); // 这次走 accPerWeight
        uint256[] memory one = new uint256[](1);
        one[0] = id;
        vm.prank(alice);
        core.settleLit(one);
        vm.prank(alice);
        uint256 got = core.claim();

        console2.log("parked pre-LIT fees (wei):", parked, "claimed (wei):", got);
        assertGt(got, 0);
        assertEq(core.reserveForLit(), parked, "reserveForLit never moves afterwards");
    }
}
