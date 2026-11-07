// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev Rejects ETH with a normal revert string
contract RevertingRecipient {
    receive() external payable {
        revert("no thanks");
    }
}

/// @dev Burns all the gas it is given
contract GasBurnerRecipient {
    uint256 public counter;

    receive() external payable {
        while (true) {
            counter++;
        }
    }
}

/// @dev Reverts with as much return data as the given gas can pay for
contract ReturnBombRecipient {
    receive() external payable {
        assembly {
            revert(0, 100000)
        }
    }
}

/// @dev Accepts ETH and does a little work, like a smart wallet logging a deposit
contract LightRecipient {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

/// @dev Legitimate, but its receive logic costs more than the recipient gas cap
contract HeavyRecipient {
    uint256 public a;
    uint256 public b;
    uint256 public c;

    receive() external payable {
        a = msg.value;
        b = msg.value;
        c = msg.value;
    }
}

/// @dev Tries to re-enter the spray contract while being paid
contract ReentrantRecipient {
    receive() external payable {
        (bool success,) = msg.sender.call{value: msg.value}(
            abi.encodeWithSignature("sprayETH((address,uint256)[])", new bytes(0))
        );
        require(success, "reentry blocked");
    }
}

/// @dev A contract caller that cannot accept an ETH refund
contract NoReceiveCaller {
    function call(address target, bytes calldata data) external payable returns (bool, bytes memory) {
        return target.call{value: msg.value}(data);
    }
}

/// @dev A contract caller whose receive() can be switched on, and can call back into whoever pays it
contract SwitchableOperator {
    bool public accepting;
    bytes public reenterData;

    function setAccepting(bool value) external {
        accepting = value;
    }

    function setReenterData(bytes calldata data) external {
        reenterData = data;
    }

    function call(address target, bytes calldata data) external payable returns (bool, bytes memory) {
        return target.call{value: msg.value}(data);
    }

    receive() external payable {
        require(accepting, "not accepting");
        if (reenterData.length > 0) {
            (bool ok,) = msg.sender.call(reenterData);
            require(ok, "reentry blocked");
        }
    }
}

/// @dev A contract caller whose receive() rejects anything above a cap
contract CappedOperator {
    uint256 public constant CAP = 0.1 ether;

    function call(address target, bytes calldata data) external payable returns (bool, bytes memory) {
        return target.call{value: msg.value}(data);
    }

    receive() external payable {
        require(msg.value <= CAP, "above cap");
    }
}

/// @dev Passes on what it's paid by force-sending it to a target
contract ForcingRecipient {
    address payable public immutable target;

    constructor(address payable _target) {
        target = _target;
    }

    receive() external payable {
        selfdestruct(target);
    }
}

/// @dev Forces ETH into a contract past its receive(), the way selfdestruct can
contract ForceSender {
    constructor(address payable target) payable {
        selfdestruct(target);
    }
}

/// @dev USDC-style: transfers to a blocklisted address revert
contract BlocklistERC20 is MockERC20 {
    mapping(address => bool) public blocked;

    constructor() MockERC20("Blocklist", "BLK", 18) {}

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blocked[to], "blocklisted");
        return super.transfer(to, amount);
    }
}

/// @dev Reports failure by returning false instead of reverting
contract FalseReturnERC20 is MockERC20 {
    mapping(address => bool) public blocked;

    constructor() MockERC20("False", "FLS", 18) {}

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (blocked[to]) return false;
        return super.transfer(to, amount);
    }
}

/// @dev USDT-style: `transfer` and `transferFrom` return nothing, and blocklisted transfers revert
contract NoReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        require(!blocked[to], "blocklisted");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
