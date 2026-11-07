// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SprayContract} from "../src/SprayContract.sol";

interface IUSDC {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
}

/// @notice Runs the fixed contract against real USDC on Base, using its real blocklist.
/// Skipped unless BASE_RPC_URL is set.
contract SprayContractForkTest is Test {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function test_Fork_Base_BlocklistedUSDCRecipientIsSkipped() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 8453);

        address sender = makeAddr("sender");
        address feeRecipient = makeAddr("feeRecipient");
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address blocked = makeAddr("blocked");

        vm.prank(IUSDC(USDC).blacklister());
        IUSDC(USDC).blacklist(blocked);

        SprayContract spray = new SprayContract(feeRecipient, 30);
        deal(USDC, sender, 1_000e6, true);
        vm.prank(sender);
        IERC20(USDC).approve(address(spray), type(uint256).max);

        SprayContract.Recipient[] memory batch = new SprayContract.Recipient[](3);
        batch[0] = SprayContract.Recipient(payable(alice), 100e6);
        batch[1] = SprayContract.Recipient(payable(blocked), 200e6);
        batch[2] = SprayContract.Recipient(payable(bob), 300e6);

        vm.prank(sender);
        uint256 failed = spray.sprayToken(USDC, batch);

        uint256 fee = 400e6 * 30 / 10_000;
        assertEq(failed, 1);
        assertEq(IERC20(USDC).balanceOf(alice), 100e6);
        assertEq(IERC20(USDC).balanceOf(bob), 300e6);
        assertEq(IERC20(USDC).balanceOf(blocked), 0);
        assertEq(IERC20(USDC).balanceOf(feeRecipient), fee);
        assertEq(1_000e6 - IERC20(USDC).balanceOf(sender), 400e6 + fee);
        assertEq(IERC20(USDC).balanceOf(address(spray)), 0);
    }
}
