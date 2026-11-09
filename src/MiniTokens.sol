// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title  最简 ERC20（自包含，无外部依赖）
/// @notice 故意不提供 mint 权限函数 —— 供应量完全由曲线合约控制
abstract contract MiniERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function _initToken(string memory n, string memory s) internal {
        name = n;
        symbol = s;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ERC20: allowance");
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "ERC20: zero to");
        uint256 b = balanceOf[from];
        require(b >= amount, "ERC20: balance");
        unchecked {
            balanceOf[from] = b - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
        _afterTokenMove(from, to, amount);
    }

    function _mintTo(address to, uint256 amount) internal {
        totalSupply += amount;
        unchecked { balanceOf[to] += amount; }
        emit Transfer(address(0), to, amount);
        _afterTokenMove(address(0), to, amount);
    }

    function _burnFrom(address from, uint256 amount) internal {
        uint256 b = balanceOf[from];
        require(b >= amount, "ERC20: burn balance");
        unchecked {
            balanceOf[from] = b - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
        _afterTokenMove(from, address(0), amount);
    }

    /// @dev 派生合约挂钩余额变化（状态机在这里触发）
    function _afterTokenMove(address from, address to, uint256 amount) internal virtual;
}
