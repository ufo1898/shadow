// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MiniERC20} from "./MiniTokens.sol";

/// @title  ShadowCore —— 档 0 验证合约（不发币、不注流动性、不宣传）
/// @notice 验证三件事：
///         1) 零种子恒定乘积曲线（虚拟储备启动，无任何初始 HYPE 注入）
///         2) 三态状态机 POOL / DARK / LIT + 溶解 + 点亮燃烧
///         3) 按【块数】延迟抽取，随机源用 blockhash（本链 prevrandao 熵极低，实测 10 块只变 1 次）
///
/// @dev    核心不变式：darkOf[who] 由余额决定，darkStack[who].length 是已实际分配的 id 数
///         两者差值 = 待抽取数量，因此"没结算就卖出"天然不会凭空造 id
contract ShadowCore is MiniERC20 {
    // ───────────────────────── 常量 ─────────────────────────
    uint256 public constant MAX_ID = 3333;              // 共 3333 台
    uint256 public constant UNIT = 1e18;                // 1.0 = 1 台
    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 300;              // 买卖各 3%（2026-11-09 老刘拍板：团队实得成交额 1%）
    uint256 public constant VIRTUAL_HYPE = 2000 ether;
    uint256 public constant VIRTUAL_TOKEN = 3333 ether;

    uint64 public constant REVEAL_DELAY_MIN = 50;       // ≥50 块（≈5.2 秒 @9.6 块/秒）
    uint64 public constant REVEAL_DELAY_MAX = 240;      // ≤240 块（必须 < 256，blockhash 窗口）
    uint256 public constant MAX_SETTLE_BATCH = 30;      // 单次 settle 最多抽 30 个（gas 上限保护）

    /// @dev K = VH × (VT + 全部真实 token)
    uint256 public immutable K;

    // ───────────────────────── 曲线 ─────────────────────────
    uint256 public hypeReserve;    // 池中真实 HYPE
    uint256 public tokenReserve;   // 池中真实 token
    uint256 public burnedTotal;    // 累计烧掉
    uint256 public reserveForLit;  // 无人点亮时暂存的奖励

    // ───────────────────────── 三态 ─────────────────────────
    mapping(uint256 => address) public ownerOfId;   // 0x0 = 在抽取池
    mapping(uint256 => bool) public lit;
    mapping(uint256 => uint8) public attuneLevel;
    uint256 public litCount;
    uint256 public darkCount;

    mapping(address => uint256) public darkOf;       // 应得 DARK 数（由余额决定）
    mapping(address => uint256[]) private darkStack; // 已分配的 DARK id（LIFO 溶解）
    mapping(address => uint256) public idBalance;    // NFT 数量

    // ───────────────────────── 抽取池（lazy Fisher-Yates）─────────────────────────
    mapping(uint256 => uint256) private poolSlot;    // pos → id（0 表示 pos+1）
    uint256 public poolSize;

    // ───────────────────────── 延迟抽取 ─────────────────────────
    struct Pending {
        uint64 readyAt;
        uint64 expireAt;
        uint256 secret;
    }
    mapping(address => Pending) public pending;

    // ───────────────────────── 分红（累积式）─────────────────────────
    uint256 public accPerWeight;
    uint256 public totalWeight;
    mapping(uint256 => uint256) public rewardDebt;
    mapping(address => uint256) public claimable;

    // ───────────────────────── 管理 ─────────────────────────
    address public owner;
    address public feeSink;
    bool public frozen;
    uint256 private nonce;

    /// @dev 内部烧币时抑制状态机（点亮/共鸣不该触发溶解）
    bool private _suppressSync;

    event Bought(address indexed who, uint256 hypeIn, uint256 tokenOut, uint256 fee);
    event Sold(address indexed who, uint256 tokenIn, uint256 hypeOut, uint256 fee);
    event DrawScheduled(address indexed who, uint64 readyAt);
    event Settled(address indexed who, uint256 count);
    event Dissolved(address indexed who, uint256 id);
    event Consecrated(address indexed who, uint256 id, uint8 generation);
    event Attuned(address indexed who, uint256 id, uint8 level);
    event RewardsNotified(uint256 amount);
    event Minted(address indexed to, uint256 id);

    error NotOwner();
    error IsFrozen();
    error BadAmount();
    error Slippage();
    error SoldOut();
    error NoLiquidity();
    error TooEarly(uint64 readyAt);
    error Expired();
    error Nothing();
    error NotLit();
    error NotYours();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(string memory tokenName, string memory tokenSymbol, address _feeSink) {
        require(_feeSink != address(0), "feeSink");
        _initToken(tokenName, tokenSymbol);
        owner = msg.sender;
        feeSink = _feeSink;

        K = VIRTUAL_HYPE * (VIRTUAL_TOKEN + MAX_ID * UNIT);
        tokenReserve = MAX_ID * UNIT;
        poolSize = MAX_ID;
        nonce = 1;
    }

    // ═══════════════════════════ 曲线 ═══════════════════════════

    /// @notice 用 HYPE 买 token。零种子 —— 合约初始一分 HYPE 都没有
    function buy(uint256 minOut) external payable returns (uint256 out) {
        if (msg.value == 0) revert BadAmount();
        if (tokenReserve == 0) revert SoldOut();

        uint256 fee = (msg.value * FEE_BPS) / BPS;
        uint256 net = msg.value - fee;

        uint256 x = VIRTUAL_HYPE + hypeReserve + net;
        uint256 y = VIRTUAL_TOKEN + tokenReserve;
        uint256 newY = K / x;
        if (newY < VIRTUAL_TOKEN) revert NoLiquidity();

        out = y - newY;
        if (out > tokenReserve) out = tokenReserve;
        if (out < minOut) revert Slippage();

        hypeReserve += net;
        tokenReserve -= out;

        _distributeFee(fee);
        _mintTo(msg.sender, out);
        emit Bought(msg.sender, msg.value, out, fee);
    }

    /// @notice 卖 token 换回 HYPE
    function sell(uint256 amount, uint256 minOut) external returns (uint256 out) {
        if (amount == 0 || amount > balanceOf[msg.sender]) revert BadAmount();

        uint256 y = VIRTUAL_TOKEN + tokenReserve;
        uint256 x = K / y;
        uint256 newY = y + amount;
        uint256 newX = K / newY;
        uint256 gross = x - newX;
        if (gross > hypeReserve) revert NoLiquidity();

        uint256 fee = (gross * FEE_BPS) / BPS;
        out = gross - fee;
        if (out < minOut) revert Slippage();

        hypeReserve -= gross;
        tokenReserve += amount;

        _distributeFee(fee);
        _burnFrom(msg.sender, amount);

        (bool ok, ) = payable(msg.sender).call{value: out}("");
        require(ok, "hype xfer");
        emit Sold(msg.sender, amount, out, fee);
    }

    /// @dev 手续费拆账：2/3 进奖励池，1/3 给团队（总费 3% → 团队实得成交额 1%，2026-11-09 定版）
    function _distributeFee(uint256 fee) private {
        uint256 toTeam = fee / 3;
        uint256 toPool = fee - toTeam;

        if (toPool > 0) {
            if (totalWeight > 0) {
                accPerWeight += (toPool * 1e18) / totalWeight;
            } else {
                reserveForLit += toPool;
            }
            emit RewardsNotified(toPool);
        }
        if (toTeam > 0) {
            (bool ok, ) = payable(feeSink).call{value: toTeam}("");
            require(ok, "team xfer");
        }
    }

    // ═══════════════════════════ 世代与权重 ═══════════════════════════

    /// @notice 世代是 id 的纯函数属性。稀有度 40/27/19/10/4
    /// @dev    修掉 EM 的缺陷：EM 的 gen1 与 gen4 权重相同导致逻辑倒挂
    function generationOf(uint256 id) public pure returns (uint8) {
        if (id == 0 || id > MAX_ID) return 0;
        uint256 h = uint256(keccak256(abi.encodePacked("shadow.v1.gen", id))) % 1000;
        if (h < 400) return 1;
        if (h < 670) return 2;
        if (h < 860) return 3;
        if (h < 960) return 4;
        return 5;
    }

    /// @notice 基础权重 1.00 / 1.40 / 2.00 / 2.80 / 4.00 —— 与稀有度同向，严格单调
    function baseWeight(uint8 g) public pure returns (uint256) {
        if (g == 1) return 10_000;
        if (g == 2) return 14_000;
        if (g == 3) return 20_000;
        if (g == 4) return 28_000;
        if (g == 5) return 40_000;
        return 0;
    }

    /// @notice 当前权重 = 基础 × (1 + 0.5×共鸣)，未点亮为 0
    function weightOf(uint256 id) public view returns (uint256) {
        if (!lit[id]) return 0;
        uint256 bw = baseWeight(generationOf(id));
        return (bw * (100 + 50 * uint256(attuneLevel[id]))) / 100;
    }

    // ═══════════════════════════ 状态机同步 ═══════════════════════════

    function _afterTokenMove(address from, address to, uint256) internal override {
        if (_suppressSync) return;
        if (from != address(0) && from != address(this)) _syncDown(from);
        if (to != address(0) && to != address(this)) _syncUp(to);
    }

    function _syncUp(address who) private {
        uint256 units = balanceOf[who] / UNIT;
        uint256 d = darkOf[who];
        if (units <= d) return;

        darkOf[who] = units;
        darkCount += units - d;

        Pending storage p = pending[who];
        p.readyAt = uint64(block.number) + REVEAL_DELAY_MIN;
        p.expireAt = uint64(block.number) + REVEAL_DELAY_MAX;
        p.secret = uint256(keccak256(abi.encode(who, block.number, blockhash(block.number - 1), ++nonce)));
        emit DrawScheduled(who, p.readyAt);
    }

    function _syncDown(address who) private {
        uint256 units = balanceOf[who] / UNIT;
        uint256 d = darkOf[who];
        if (units >= d) return;

        uint256 n = d - units;
        darkOf[who] = units;
        darkCount -= n;
        _dissolve(who, n);
    }

    /// @dev LIFO 溶解：销毁最新分配的 DARK，id 归还池子（池子只增不减的部分）
    function _dissolve(address who, uint256 n) private {
        uint256[] storage st = darkStack[who];
        while (n > 0 && st.length > 0) {
            uint256 id = st[st.length - 1];
            st.pop();
            ownerOfId[id] = address(0);
            if (idBalance[who] > 0) idBalance[who] -= 1;
            _returnToPool(id);
            emit Dissolved(who, id);
            n -= 1;
        }
    }

    function _returnToPool(uint256 id) private {
        poolSlot[poolSize] = id;
        poolSize += 1;
    }

    // ═══════════════════════════ 延迟抽取 ═══════════════════════════

    /// @notice 结算待抽取的 DARK。随机源是 reveal 前一块的 blockhash（逐块变化）
    /// @dev    blockhash 只能取最近 256 块，所以 expireAt 必须 < 256
    function settle() external returns (uint256 drawn) {
        uint256 stackLen = darkStack[msg.sender].length;
        uint256 owed = darkOf[msg.sender] > stackLen ? darkOf[msg.sender] - stackLen : 0;
        if (owed == 0) revert Nothing();

        Pending storage p = pending[msg.sender];
        if (block.number < p.readyAt) revert TooEarly(p.readyAt);
        if (block.number > p.expireAt) revert Expired();

        uint256 secret = p.secret;
        uint256 h = uint256(blockhash(block.number - 1));
        require(h != 0, "blockhash zero");

        uint256 batch = owed > MAX_SETTLE_BATCH ? MAX_SETTLE_BATCH : owed;

        for (uint256 i = 0; i < batch; i++) {
            if (poolSize == 0) break;
            uint256 seed = uint256(keccak256(abi.encodePacked(h, secret, msg.sender, i, block.number)));
            uint256 id = _drawAt(seed % poolSize);

            ownerOfId[id] = msg.sender;
            idBalance[msg.sender] += 1;
            darkStack[msg.sender].push(id);
            drawn += 1;
            emit Minted(msg.sender, id);
        }

        if (owed > drawn) {
            // 还有剩余：保留延迟（换新 secret），下一块即可继续，不必再等 50 块
            p.secret = uint256(keccak256(abi.encode(secret, drawn, block.number)));
            p.readyAt = uint64(block.number) + 1;
            p.expireAt = uint64(block.number) + 1 + REVEAL_DELAY_MAX;
        } else {
            delete pending[msg.sender];
        }

        emit Settled(msg.sender, drawn);
    }

    function _slotValue(uint256 pos) private view returns (uint256) {
        uint256 v = poolSlot[pos];
        return v == 0 ? pos + 1 : v;
    }

    function _drawAt(uint256 pos) private returns (uint256 id) {
        id = _slotValue(pos);
        uint256 last = poolSize - 1;
        if (pos != last) {
            poolSlot[pos] = _slotValue(last);
        }
        delete poolSlot[last];
        poolSize = last;
    }

    // ═══════════════════════════ 点亮 / 共鸣 ═══════════════════════════

    /// @notice 点亮：烧 1.0 token，id 永久移出抽取池
    function consecrate(uint256 id) external {
        if (ownerOfId[id] != msg.sender) revert NotYours();
        if (lit[id]) revert BadAmount();
        if (balanceOf[msg.sender] < UNIT) revert BadAmount();

        _settleId(id);

        // 抑制状态机：这次烧币是"点亮"，不是"余额下降导致溶解"
        _suppressSync = true;
        _burnFrom(msg.sender, UNIT);
        _suppressSync = false;

        burnedTotal += UNIT;
        _removeFromStack(msg.sender, id);
        if (idBalance[msg.sender] > 0) idBalance[msg.sender] -= 1;

        lit[id] = true;
        litCount += 1;
        darkCount -= 1;
        darkOf[msg.sender] -= 1; // 修复（2026-11-09 真链自测实锤）：点亮必须同步扣减应得数，否则之后卖出会在 _syncDown 里让 darkCount 下溢 panic、零头代币被永久困死

        uint256 w = weightOf(id);
        totalWeight += w;
        rewardDebt[id] = (w * accPerWeight) / 1e18;

        emit Consecrated(msg.sender, id, generationOf(id));
    }

    /// @notice 共鸣：再烧 1.0 token 提升权重，最多 4 级（最高 3.0×）
    function attune(uint256 id) external {
        if (!lit[id]) revert NotLit();
        if (ownerOfId[id] != msg.sender) revert NotYours();
        if (attuneLevel[id] >= 4) revert BadAmount();
        if (balanceOf[msg.sender] < UNIT) revert BadAmount();

        _settleId(id);

        uint256 oldW = weightOf(id);
        totalWeight -= oldW;

        _suppressSync = true;
        _burnFrom(msg.sender, UNIT);
        _suppressSync = false;

        burnedTotal += UNIT;
        attuneLevel[id] += 1;

        uint256 newW = weightOf(id);
        totalWeight += newW;
        rewardDebt[id] = (newW * accPerWeight) / 1e18;

        emit Attuned(msg.sender, id, attuneLevel[id]);
    }

    function _removeFromStack(address who, uint256 id) private {
        uint256[] storage st = darkStack[who];
        uint256 len = st.length;
        for (uint256 i = 0; i < len; i++) {
            if (st[i] == id) {
                st[i] = st[len - 1];
                st.pop();
                return;
            }
        }
    }

    // ═══════════════════════════ 分红 ═══════════════════════════

    function _settleId(uint256 id) private {
        if (!lit[id]) return;
        uint256 w = weightOf(id);
        uint256 acc = (w * accPerWeight) / 1e18;
        uint256 pend = acc - rewardDebt[id];
        if (pend > 0) {
            claimable[ownerOfId[id]] += pend;
        }
        rewardDebt[id] = acc;
    }

    /// @notice 结算自己名下若干 LIT（转移前尤其需要）
    function settleLit(uint256[] calldata ids) external {
        for (uint256 i = 0; i < ids.length; i++) {
            if (lit[ids[i]] && ownerOfId[ids[i]] == msg.sender) _settleId(ids[i]);
        }
    }

    /// @notice 领取已结算奖励
    function claim() external returns (uint256 amount) {
        amount = claimable[msg.sender];
        if (amount == 0) revert Nothing();
        claimable[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "claim xfer");
    }

    // ═══════════════════════════ NFT 转移 ═══════════════════════════
    /// @dev 硬约束：普通转移只换持有人，绝不改变状态

    function transferId(address to, uint256 id) external {
        if (ownerOfId[id] != msg.sender) revert NotYours();
        require(to != address(0), "zero to");
        require(to != address(this), "to this");

        if (lit[id]) {
            _settleId(id);
            rewardDebt[id] = (weightOf(id) * accPerWeight) / 1e18;
        } else {
            _removeFromStack(msg.sender, id);
            darkStack[to].push(id);
            if (darkOf[msg.sender] > 0) darkOf[msg.sender] -= 1;
            darkOf[to] += 1;
        }

        if (idBalance[msg.sender] > 0) idBalance[msg.sender] -= 1;
        idBalance[to] += 1;
        ownerOfId[id] = to;
    }

    // ═══════════════════════════ 只读 ═══════════════════════════

    /// @notice 边际价格（HYPE per token）
    function spotPrice() external view returns (uint256) {
        uint256 y = VIRTUAL_TOKEN + tokenReserve;
        uint256 x = K / y;
        return (x * 1e18) / y;
    }

    /// @notice 买光剩余 token 需要多少 HYPE
    function costToClear() external view returns (uint256) {
        uint256 xNow = K / (VIRTUAL_TOKEN + tokenReserve);
        uint256 xEnd = K / VIRTUAL_TOKEN;
        if (xEnd <= xNow) return 0;
        return xEnd - xNow;
    }

    function totalHype() external view returns (uint256) {
        return hypeReserve + reserveForLit;
    }

    function darkIdsOf(address who) external view returns (uint256[] memory) {
        return darkStack[who];
    }

    /// @notice 待抽取数量
    function owedOf(address who) external view returns (uint256) {
        uint256 sl = darkStack[who].length;
        return darkOf[who] > sl ? darkOf[who] - sl : 0;
    }

    // ═══════════════════════════ 管理（档 0 最小化）═══════════════════════════

    function freeze() external onlyOwner {
        frozen = true;
    }

    function setFeeSink(address s) external onlyOwner {
        if (frozen) revert IsFrozen();
        require(s != address(0), "zero");
        feeSink = s;
    }

    function transferOwnership(address n) external onlyOwner {
        require(n != address(0), "zero");
        owner = n;
    }

    receive() external payable {
        reserveForLit += msg.value;
    }
}
