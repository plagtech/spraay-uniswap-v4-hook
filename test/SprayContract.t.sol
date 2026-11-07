// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {SprayContract} from "../src/SprayContract.sol";
import {MockSpraay} from "./mocks/MockSpraay.sol";
import {
    BlocklistERC20,
    FalseReturnERC20,
    GasBurnerRecipient,
    HeavyRecipient,
    LightRecipient,
    NoReceiveCaller,
    NoReturnERC20,
    ReentrantRecipient,
    ReturnBombRecipient,
    RevertingRecipient
} from "./mocks/GriefingMocks.sol";

contract SprayContractTest is Test {
    uint256 constant FEE_BPS = 30;

    SprayContract spray;
    MockERC20 token;
    BlocklistERC20 blocklist;

    address sender = makeAddr("sender");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address blocked = makeAddr("blocked");
    address payable reverter;

    function setUp() public {
        spray = new SprayContract(feeRecipient, FEE_BPS);
        reverter = payable(address(new RevertingRecipient()));

        token = new MockERC20("Token", "TKN", 18);
        blocklist = new BlocklistERC20();
        blocklist.setBlocked(blocked, true);

        vm.deal(sender, 1_000 ether);
        vm.startPrank(sender);
        token.approve(address(spray), type(uint256).max);
        blocklist.approve(address(spray), type(uint256).max);
        vm.stopPrank();
        token.mint(sender, 1_000 ether);
        blocklist.mint(sender, 1_000 ether);
    }

    // ============ One bad recipient: batch survives, refund is exact ============

    function test_SprayETH_RevertingRecipientIsSkipped() public {
        SprayContract.Recipient[] memory batch = _three(alice, reverter, bob);
        uint256 senderBefore = sender.balance;

        // only `alice` and `bob` count: 1 + 3 ether delivered, 2 ether skipped
        uint256 fee = _fee(4 ether);

        vm.expectEmit(true, false, false, true, address(spray));
        emit SprayContract.RecipientFailed(reverter, 2 ether, abi.encodeWithSignature("Error(string)", "no thanks"));
        vm.expectEmit(true, false, false, false, address(spray));
        emit SprayContract.SprayETHExecuted(sender, 4 ether, 2, fee, block.timestamp);

        vm.prank(sender);
        uint256 failed = spray.sprayETH{value: 6 ether + _fee(6 ether)}(batch);

        assertEq(failed, 1);
        assertEq(alice.balance, 1 ether);
        assertEq(bob.balance, 3 ether);
        assertEq(reverter.balance, 0);
        assertEq(feeRecipient.balance, fee);
        assertEq(senderBefore - sender.balance, 4 ether + fee, "sender pays only delivered + its fee");
        assertEq(address(spray).balance, 0, "nothing stuck");
    }

    function test_SprayEqual_ETH_RevertingRecipientIsSkipped() public {
        address payable[] memory batch = _equal(alice, reverter, bob);
        uint256 senderBefore = sender.balance;
        uint256 fee = _fee(2 ether);

        vm.expectEmit(true, false, false, false, address(spray));
        emit SprayContract.RecipientFailed(reverter, 1 ether, "");
        vm.prank(sender);
        uint256 failed = spray.sprayEqual{value: 3 ether + _fee(3 ether)}(address(0), batch, 1 ether);

        assertEq(failed, 1);
        assertEq(alice.balance, 1 ether);
        assertEq(bob.balance, 1 ether);
        assertEq(feeRecipient.balance, fee);
        assertEq(senderBefore - sender.balance, 2 ether + fee);
        assertEq(address(spray).balance, 0);
    }

    function test_SprayToken_BlocklistedRecipientIsSkipped() public {
        SprayContract.Recipient[] memory batch = _three(alice, payable(blocked), bob);
        uint256 senderBefore = blocklist.balanceOf(sender);
        uint256 fee = _fee(4 ether);

        vm.expectEmit(true, false, false, true, address(spray));
        emit SprayContract.RecipientFailed(blocked, 2 ether, abi.encodeWithSignature("Error(string)", "blocklisted"));
        vm.expectEmit(true, true, false, false, address(spray));
        emit SprayContract.SprayTokenExecuted(sender, address(blocklist), 4 ether, 2, fee, block.timestamp);

        vm.prank(sender);
        uint256 failed = spray.sprayToken(address(blocklist), batch);

        assertEq(failed, 1);
        assertEq(blocklist.balanceOf(alice), 1 ether);
        assertEq(blocklist.balanceOf(bob), 3 ether);
        assertEq(blocklist.balanceOf(blocked), 0);
        assertEq(blocklist.balanceOf(feeRecipient), fee);
        assertEq(senderBefore - blocklist.balanceOf(sender), 4 ether + fee);
        assertEq(blocklist.balanceOf(address(spray)), 0);
    }

    function test_SprayEqual_Token_BlocklistedRecipientIsSkipped() public {
        address payable[] memory batch = _equal(alice, payable(blocked), bob);
        uint256 senderBefore = blocklist.balanceOf(sender);
        uint256 fee = _fee(2 ether);

        vm.prank(sender);
        uint256 failed = spray.sprayEqual(address(blocklist), batch, 1 ether);

        assertEq(failed, 1);
        assertEq(blocklist.balanceOf(alice), 1 ether);
        assertEq(blocklist.balanceOf(bob), 1 ether);
        assertEq(blocklist.balanceOf(feeRecipient), fee);
        assertEq(senderBefore - blocklist.balanceOf(sender), 2 ether + fee);
        assertEq(blocklist.balanceOf(address(spray)), 0);
    }

    // ============ Non-standard tokens ============

    function test_SprayToken_NoReturnValueToken() public {
        NoReturnERC20 usdtLike = new NoReturnERC20();
        usdtLike.setBlocked(blocked, true);
        usdtLike.mint(sender, 100 ether);
        vm.prank(sender);
        usdtLike.approve(address(spray), type(uint256).max);

        // healthy recipients must count as delivered even though `transfer` returns nothing
        vm.prank(sender);
        uint256 failed = spray.sprayToken(address(usdtLike), _three(alice, payable(blocked), bob));

        assertEq(failed, 1);
        assertEq(usdtLike.balanceOf(alice), 1 ether);
        assertEq(usdtLike.balanceOf(bob), 3 ether);
        assertEq(usdtLike.balanceOf(address(spray)), 0);
        assertEq(100 ether - usdtLike.balanceOf(sender), 4 ether + _fee(4 ether));
    }

    function test_SprayToken_FalseReturnIsTreatedAsFailure() public {
        FalseReturnERC20 falseToken = new FalseReturnERC20();
        falseToken.setBlocked(blocked, true);
        falseToken.mint(sender, 100 ether);
        vm.prank(sender);
        falseToken.approve(address(spray), type(uint256).max);

        vm.prank(sender);
        uint256 failed = spray.sprayToken(address(falseToken), _three(alice, payable(blocked), bob));

        assertEq(failed, 1);
        assertEq(falseToken.balanceOf(blocked), 0);
        assertEq(falseToken.balanceOf(address(spray)), 0);
        assertEq(100 ether - falseToken.balanceOf(sender), 4 ether + _fee(4 ether));
    }

    // ============ Gas griefing ============

    function test_GasBurner_IsCappedAndSkipped() public {
        address payable burner = payable(address(new GasBurnerRecipient()));

        // baseline: the same batch with an ordinary recipient, then rewind
        uint256 snapshot = vm.snapshotState();
        SprayContract.Recipient[] memory baselineBatch = _two(alice, payable(bob));
        vm.prank(sender);
        uint256 gasStart = gasleft();
        spray.sprayETH{value: 4 ether}(baselineBatch);
        uint256 baselineGas = gasStart - gasleft();
        vm.revertToState(snapshot);

        SprayContract.Recipient[] memory batch = _two(alice, burner);
        vm.prank(sender);
        gasStart = gasleft();
        uint256 failed = spray.sprayETH{value: 4 ether}(batch);
        uint256 gasUsed = gasStart - gasleft();

        assertEq(failed, 1);
        assertEq(alice.balance, 1 ether);
        // the burner may cost about the 50k cap plus the stipend and a log, not 63/64 of all gas
        assertLt(gasUsed, baselineGas + 60_000, "burner must be capped");
    }

    /// @dev The griefing that raw `bytes reason` logging would reintroduce
    function test_ReturnBomb_ReasonIsTruncated() public {
        address payable bomb = payable(address(new ReturnBombRecipient()));

        vm.recordLogs();
        vm.prank(sender);
        spray.sprayETH{value: 4 ether}(_two(alice, bomb));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs[0].topics[0], SprayContract.RecipientFailed.selector);
        (, bytes memory reason) = abi.decode(logs[0].data, (uint256, bytes));
        assertEq(reason.length, spray.MAX_REASON_BYTES());
    }

    /// @dev Worst case: every entry but one griefs at once. The batch still completes affordably.
    function test_ReturnBomb_FullBatchStaysBounded() public {
        address payable bomb = payable(address(new ReturnBombRecipient()));
        SprayContract.Recipient[] memory batch = new SprayContract.Recipient[](200);
        for (uint256 i; i < 199; ++i) {
            batch[i] = SprayContract.Recipient(bomb, 1 gwei);
        }
        batch[199] = SprayContract.Recipient(payable(alice), 1 gwei);

        vm.prank(sender);
        uint256 gasStart = gasleft();
        uint256 failed = spray.sprayETH{value: 1 ether}(batch);
        uint256 gasUsed = gasStart - gasleft();

        assertEq(failed, 199);
        assertEq(alice.balance, 1 gwei);
        assertLt(gasUsed, 15_000_000, "griefing cost must stay bounded");
    }

    function test_LowGas_RevertsInsteadOfMarkingHealthyRecipientFailed() public {
        LightRecipient light = new LightRecipient();
        SprayContract.Recipient[] memory batch = _two(alice, payable(address(light)));

        vm.prank(sender);
        vm.expectRevert(bytes("Insufficient gas"));
        spray.sprayETH{value: 4 ether, gas: 100_000}(batch);

        assertEq(alice.balance, 0);
        assertEq(light.received(), 0);
    }

    // ============ Contract recipients ============

    function test_LightContractRecipient_IsPaid() public {
        LightRecipient light = new LightRecipient();

        vm.prank(sender);
        uint256 failed = spray.sprayETH{value: 4 ether}(_two(alice, payable(address(light))));

        assertEq(failed, 0);
        assertEq(light.received(), 2 ether);
    }

    /// @dev Documents the cap's trade-off: these recipients were paid before the fix
    function test_HeavyContractRecipient_IsSkippedAndRefunded() public {
        HeavyRecipient heavy = new HeavyRecipient();
        uint256 senderBefore = sender.balance;

        vm.prank(sender);
        uint256 failed = spray.sprayETH{value: 4 ether}(_two(alice, payable(address(heavy))));

        assertEq(failed, 1);
        assertEq(address(heavy).balance, 0);
        assertEq(senderBefore - sender.balance, 1 ether + _fee(1 ether));
    }

    function test_ReentrantRecipient_IsSkipped() public {
        address payable reentrant = payable(address(new ReentrantRecipient()));

        vm.prank(sender);
        uint256 failed = spray.sprayETH{value: 4 ether}(_two(alice, reentrant));

        assertEq(failed, 1);
        assertEq(alice.balance, 1 ether);
        assertEq(reentrant.balance, 0);
        assertEq(address(spray).balance, 0);
    }

    // ============ Fee ============

    function test_Fee_OnDeliveredAmountOnly() public {
        // 1 ether delivered of 10 ether requested
        SprayContract.Recipient[] memory batch = new SprayContract.Recipient[](2);
        batch[0] = SprayContract.Recipient(payable(alice), 1 ether);
        batch[1] = SprayContract.Recipient(reverter, 9 ether);

        vm.prank(sender);
        spray.sprayETH{value: 10 ether + _fee(10 ether)}(batch);

        assertEq(feeRecipient.balance, 0.003 ether);
    }

    /// @dev Any mix of failures: sender pays delivered + fee(delivered), and nothing stays behind
    function testFuzz_Accounting_ETH(uint8 count, uint256 failMask, uint96 baseAmount, uint96 extra) public {
        count = uint8(bound(count, 1, 40));
        baseAmount = uint96(bound(baseAmount, 1, 1 ether));
        extra = uint96(bound(extra, 0, 1 ether));

        SprayContract.Recipient[] memory batch = new SprayContract.Recipient[](count);
        uint256 total;
        uint256 delivered;
        uint256 expectedFailed;
        for (uint256 i; i < count; ++i) {
            uint256 amount = uint256(baseAmount) * (i + 1);
            bool fails = (failMask >> i) & 1 == 1;
            address payable to =
                fails ? reverter : payable(address(uint160(uint256(keccak256(abi.encode("fuzz", i))))));
            batch[i] = SprayContract.Recipient(to, amount);
            total += amount;
            if (fails) expectedFailed++;
            else delivered += amount;
        }
        vm.deal(sender, 100_000 ether);
        uint256 senderBefore = sender.balance;
        uint256 value = total + _fee(total) + extra;

        vm.prank(sender);
        if (delivered == 0) {
            vm.expectRevert(bytes("All transfers failed"));
            spray.sprayETH{value: value}(batch);
            return;
        }
        uint256 failed = spray.sprayETH{value: value}(batch);

        assertEq(failed, expectedFailed);
        assertEq(feeRecipient.balance, _fee(delivered));
        assertEq(senderBefore - sender.balance, delivered + _fee(delivered));
        assertEq(address(spray).balance, 0);
    }

    function testFuzz_Accounting_Token(uint8 count, uint256 failMask, uint96 baseAmount) public {
        count = uint8(bound(count, 1, 40));
        baseAmount = uint96(bound(baseAmount, 1, 1 ether));

        SprayContract.Recipient[] memory batch = new SprayContract.Recipient[](count);
        uint256 total;
        uint256 delivered;
        for (uint256 i; i < count; ++i) {
            uint256 amount = uint256(baseAmount) * (i + 1);
            bool fails = (failMask >> i) & 1 == 1;
            address to = fails ? blocked : address(uint160(uint256(keccak256(abi.encode("fuzz", i)))));
            batch[i] = SprayContract.Recipient(payable(to), amount);
            total += amount;
            if (!fails) delivered += amount;
        }
        blocklist.mint(sender, total * 2);
        uint256 senderBefore = blocklist.balanceOf(sender);

        vm.prank(sender);
        if (delivered == 0) {
            vm.expectRevert(bytes("All transfers failed"));
            spray.sprayToken(address(blocklist), batch);
            return;
        }
        spray.sprayToken(address(blocklist), batch);

        assertEq(blocklist.balanceOf(feeRecipient), _fee(delivered));
        assertEq(senderBefore - blocklist.balanceOf(sender), delivered + _fee(delivered));
        assertEq(blocklist.balanceOf(address(spray)), 0);
    }

    // ============ All fail / refund fail ============

    function test_AllFail_Reverts_ETH() public {
        vm.prank(sender);
        vm.expectRevert(bytes("All transfers failed"));
        spray.sprayETH{value: 4 ether}(_two(reverter, reverter));

        address payable[] memory batch = new address payable[](1);
        batch[0] = reverter;
        vm.prank(sender);
        vm.expectRevert(bytes("All transfers failed"));
        spray.sprayEqual{value: 2 ether}(address(0), batch, 1 ether);
    }

    function test_AllFail_Reverts_Token() public {
        vm.prank(sender);
        vm.expectRevert(bytes("All transfers failed"));
        spray.sprayToken(address(blocklist), _two(payable(blocked), payable(blocked)));

        address payable[] memory batch = new address payable[](1);
        batch[0] = payable(blocked);
        vm.prank(sender);
        vm.expectRevert(bytes("All transfers failed"));
        spray.sprayEqual(address(blocklist), batch, 1 ether);
    }

    function test_RefundFailure_RevertsWholeBatch() public {
        NoReceiveCaller caller = new NoReceiveCaller();
        vm.deal(address(caller), 0);
        vm.deal(address(this), 10 ether);

        (bool ok, bytes memory ret) = caller.call{value: 4 ether}(
            address(spray), abi.encodeCall(SprayContract.sprayETH, (_two(alice, reverter)))
        );

        assertFalse(ok);
        assertEq(ret, abi.encodeWithSignature("Error(string)", "Refund failed"));
        assertEq(alice.balance, 0);
    }

    // ============ No regression: all recipients succeed ============

    /// @dev Same batch through the deployed logic and the fixed logic must give the same result
    function test_AllSucceed_MatchesLegacy_ETH() public {
        MockSpraay legacy = new MockSpraay(feeRecipient, FEE_BPS);
        MockSpraay.Recipient[] memory legacyBatch = new MockSpraay.Recipient[](3);
        SprayContract.Recipient[] memory batch = _three(alice, payable(carol), bob);
        for (uint256 i; i < 3; ++i) {
            legacyBatch[i] = MockSpraay.Recipient(batch[i].recipient, batch[i].amount);
        }
        uint256 value = 6 ether + _fee(6 ether) + 1 ether; // includes excess

        uint256 senderStart = sender.balance;
        vm.prank(sender);
        legacy.sprayETH{value: value}(legacyBatch);
        uint256 legacyCost = senderStart - sender.balance;
        uint256 legacyFee = feeRecipient.balance;
        uint256 legacyAlice = alice.balance;

        senderStart = sender.balance;
        vm.expectEmit(true, false, false, true, address(spray));
        emit SprayContract.SprayETHExecuted(sender, 6 ether, 3, _fee(6 ether), block.timestamp);
        vm.prank(sender);
        uint256 failed = spray.sprayETH{value: value}(batch);

        assertEq(failed, 0);
        assertEq(senderStart - sender.balance, legacyCost);
        assertEq(feeRecipient.balance - legacyFee, legacyFee);
        assertEq(alice.balance - legacyAlice, legacyAlice);
    }

    function test_AllSucceed_MatchesLegacy_Token() public {
        MockSpraay legacy = new MockSpraay(feeRecipient, FEE_BPS);
        MockSpraay.Recipient[] memory legacyBatch = new MockSpraay.Recipient[](3);
        SprayContract.Recipient[] memory batch = _three(alice, payable(carol), bob);
        for (uint256 i; i < 3; ++i) {
            legacyBatch[i] = MockSpraay.Recipient(batch[i].recipient, batch[i].amount);
        }
        vm.prank(sender);
        token.approve(address(legacy), type(uint256).max);

        uint256 senderStart = token.balanceOf(sender);
        vm.prank(sender);
        legacy.sprayToken(address(token), legacyBatch);
        uint256 legacyCost = senderStart - token.balanceOf(sender);
        uint256 legacyFee = token.balanceOf(feeRecipient);

        senderStart = token.balanceOf(sender);
        vm.expectEmit(true, true, false, true, address(spray));
        emit SprayContract.SprayTokenExecuted(sender, address(token), 6 ether, 3, _fee(6 ether), block.timestamp);
        vm.prank(sender);
        uint256 failed = spray.sprayToken(address(token), batch);

        assertEq(failed, 0);
        assertEq(senderStart - token.balanceOf(sender), legacyCost);
        assertEq(token.balanceOf(feeRecipient) - legacyFee, legacyFee);
    }

    function test_AllSucceed_Equal_RefundsExcess() public {
        uint256 senderBefore = sender.balance;
        vm.prank(sender);
        uint256 failed = spray.sprayEqual{value: 9 ether}(address(0), _equal(alice, bob, carol), 1 ether);

        assertEq(failed, 0);
        assertEq(senderBefore - sender.balance, 3 ether + _fee(3 ether));
        assertEq(address(spray).balance, 0);
    }

    // ============ Funds can't get stuck in the contract ============

    function test_SprayEqual_Token_RevertsIfETHSent() public {
        vm.prank(sender);
        vm.expectRevert(bytes("Unexpected ETH"));
        spray.sprayEqual{value: 1 ether}(address(token), _equal(alice, bob, carol), 1 ether);
        assertEq(address(spray).balance, 0);
    }

    function test_SelfAsRecipient_Reverts_AllPaths() public {
        address payable self = payable(address(spray));

        vm.startPrank(sender);
        vm.expectRevert(bytes("Invalid recipient"));
        spray.sprayETH{value: 4 ether}(_two(alice, self));

        vm.expectRevert(bytes("Invalid recipient"));
        spray.sprayToken(address(token), _two(alice, self));

        vm.expectRevert(bytes("Invalid recipient"));
        spray.sprayEqual{value: 4 ether}(address(0), _equal(alice, self, bob), 1 ether);

        vm.expectRevert(bytes("Invalid recipient"));
        spray.sprayEqual(address(token), _equal(alice, self, bob), 1 ether);
        vm.stopPrank();

        assertEq(address(spray).balance, 0);
        assertEq(token.balanceOf(address(spray)), 0);
    }

    // ============ Unchanged validation and admin ============

    function test_Validation_Unchanged() public {
        vm.startPrank(sender);
        SprayContract.Recipient[] memory empty = new SprayContract.Recipient[](0);
        vm.expectRevert(bytes("No recipients"));
        spray.sprayETH(empty);

        vm.expectRevert(bytes("Invalid recipient"));
        spray.sprayETH{value: 4 ether}(_two(alice, payable(address(0))));

        SprayContract.Recipient[] memory zero = new SprayContract.Recipient[](1);
        zero[0] = SprayContract.Recipient(payable(alice), 0);
        vm.expectRevert(bytes("Invalid amount"));
        spray.sprayETH(zero);

        vm.expectRevert(bytes("Insufficient ETH"));
        spray.sprayETH{value: 1}(_two(alice, payable(bob)));

        vm.expectRevert(bytes("Invalid token"));
        spray.sprayToken(address(0), _two(alice, payable(bob)));

        SprayContract.Recipient[] memory tooMany = new SprayContract.Recipient[](201);
        vm.expectRevert(bytes("Too many recipients"));
        spray.sprayETH(tooMany);
        vm.stopPrank();
    }

    function test_Admin_Unchanged() public {
        assertEq(spray.calculateTotalCost(10_000), 10_030);
        assertEq(spray.calculateFee(10_000), 30);
        assertEq(spray.owner(), address(this));

        vm.expectRevert(bytes("Fee too high"));
        spray.updateFee(501);
        spray.updateFee(500);
        assertEq(spray.feeBps(), 500);

        spray.pause();
        vm.prank(sender);
        vm.expectRevert();
        spray.sprayETH{value: 4 ether}(_two(alice, payable(bob)));
        spray.unpause();

        vm.prank(sender);
        vm.expectRevert();
        spray.updateFee(1);
    }

    // ============ Helpers ============

    receive() external payable {}

    function _fee(uint256 amount) internal pure returns (uint256) {
        return amount * FEE_BPS / 10_000;
    }

    /// @dev 1 ether and 2 ether
    function _two(address a, address payable b) internal pure returns (SprayContract.Recipient[] memory batch) {
        batch = new SprayContract.Recipient[](2);
        batch[0] = SprayContract.Recipient(payable(a), 1 ether);
        batch[1] = SprayContract.Recipient(b, 2 ether);
    }

    /// @dev 1, 2 and 3 ether
    function _three(address a, address payable b, address c)
        internal
        pure
        returns (SprayContract.Recipient[] memory batch)
    {
        batch = new SprayContract.Recipient[](3);
        batch[0] = SprayContract.Recipient(payable(a), 1 ether);
        batch[1] = SprayContract.Recipient(b, 2 ether);
        batch[2] = SprayContract.Recipient(payable(c), 3 ether);
    }

    function _equal(address a, address b, address c) internal pure returns (address payable[] memory batch) {
        batch = new address payable[](3);
        batch[0] = payable(a);
        batch[1] = payable(b);
        batch[2] = payable(c);
    }
}
