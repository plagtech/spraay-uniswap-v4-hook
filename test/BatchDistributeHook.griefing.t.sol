// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BaseTest} from "./utils/BaseTest.sol";
import {MockSpraay} from "./mocks/MockSpraay.sol";
import {
    BlocklistERC20,
    CappedOperator,
    ForceSender,
    ForcingRecipient,
    NoReceiveCaller,
    RevertingRecipient,
    SwitchableOperator
} from "./mocks/GriefingMocks.sol";

import {BatchDistributeHook} from "../src/BatchDistributeHook.sol";
import {SprayContract} from "../src/SprayContract.sol";

/// @notice The hook routed through the fixed SprayContract, where `msg.sender` of the refund is the hook
contract BatchDistributeHookGriefingTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    uint256 constant FEE_BPS = 30;

    BatchDistributeHook hook;
    SprayContract spray;
    BlocklistERC20 token;
    PoolId id;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address feeRecipient = makeAddr("feeRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address blocked = makeAddr("blocked");
    address reverter;

    function setUp() public {
        deployArtifactsAndLabel();
        spray = new SprayContract(feeRecipient, FEE_BPS);

        address hookAddr = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_DONATE_FLAG) ^ (0x4444 << 144));
        deployCodeTo(
            "BatchDistributeHook.sol:BatchDistributeHook",
            abi.encode(poolManager, address(spray), owner, operator),
            hookAddr
        );
        hook = BatchDistributeHook(payable(hookAddr));

        (Currency c0, Currency c1) = deployCurrencyPair();
        PoolKey memory key = PoolKey(c0, c1, 3000, 60, IHooks(hookAddr));
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        id = key.toId();

        reverter = address(new RevertingRecipient());
        token = new BlocklistERC20();
        token.setBlocked(blocked, true);
        token.mint(operator, 1_000 ether);
        vm.deal(operator, 1_000 ether);
        vm.prank(operator);
        token.approve(hookAddr, type(uint256).max);
    }

    // ============ Refunds reach the operator ============

    function test_Native_RefundForwardedToOperator() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch(reverter);
        uint256 operatorBefore = operator.balance;
        uint256 undelivered = 2 ether + _fee(3 ether) - _fee(1 ether);

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.BatchRefunded(id, operator, address(0), undelivered);
        vm.prank(operator);
        hook.batchDistribute{value: 3 ether + _fee(3 ether)}(id, address(0), recipients, amounts);

        assertEq(alice.balance, 1 ether);
        assertEq(reverter.balance, 0);
        assertEq(feeRecipient.balance, _fee(1 ether));
        assertEq(operatorBefore - operator.balance, 1 ether + _fee(1 ether));
        assertEq(address(hook).balance, 0);
        assertEq(address(spray).balance, 0);
    }

    function test_Native_RefundAndExcessBothReturned() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch(reverter);
        uint256 operatorBefore = operator.balance;
        uint256 undelivered = 2 ether + _fee(3 ether) - _fee(1 ether);

        // the event reports only the undelivered part, not the 5 ether of overpayment
        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.BatchRefunded(id, operator, address(0), undelivered);
        vm.prank(operator);
        hook.batchDistribute{value: 3 ether + _fee(3 ether) + 5 ether}(id, address(0), recipients, amounts);

        assertEq(operatorBefore - operator.balance, 1 ether + _fee(1 ether));
        assertEq(address(hook).balance, 0);
    }

    function test_NativeEqual_RefundForwardedToOperator() public {
        address[] memory recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = reverter;
        recipients[2] = bob;
        uint256 operatorBefore = operator.balance;

        vm.prank(operator);
        hook.batchDistributeEqual{value: 3 ether + _fee(3 ether)}(id, address(0), recipients, 1 ether);

        assertEq(alice.balance, 1 ether);
        assertEq(bob.balance, 1 ether);
        assertEq(operatorBefore - operator.balance, 2 ether + _fee(2 ether));
        assertEq(address(hook).balance, 0);
    }

    function test_ERC20_RefundForwardedToOperator() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch(blocked);
        uint256 undelivered = 2 ether + _fee(3 ether) - _fee(1 ether);

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.BatchRefunded(id, operator, address(token), undelivered);
        vm.prank(operator);
        hook.batchDistribute(id, address(token), recipients, amounts);

        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(blocked), 0);
        assertEq(token.balanceOf(feeRecipient), _fee(1 ether));
        assertEq(1_000 ether - token.balanceOf(operator), 1 ether + _fee(1 ether));
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(spray)), 0);
        assertEq(token.allowance(address(hook), address(spray)), 0);
    }

    function test_ERC20Equal_RefundForwardedToOperator() public {
        address[] memory recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = blocked;
        recipients[2] = bob;

        vm.prank(operator);
        hook.batchDistributeEqual(id, address(token), recipients, 1 ether);

        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(bob), 1 ether);
        assertEq(1_000 ether - token.balanceOf(operator), 2 ether + _fee(2 ether));
        assertEq(token.balanceOf(address(hook)), 0);
    }

    /// @dev Tokens stranded in the hook earlier belong to rescueTokens, not to the next operator
    function test_ERC20_StrayTokensAreNotSweptToOperator() public {
        token.mint(address(hook), 5 ether);
        (address[] memory recipients, uint256[] memory amounts) = _batch(blocked);

        vm.prank(operator);
        hook.batchDistribute(id, address(token), recipients, amounts);

        assertEq(token.balanceOf(address(hook)), 5 ether);
        assertEq(1_000 ether - token.balanceOf(operator), 1 ether + _fee(1 ether));
    }

    // ============ Everyone paid: no refund event, same cost ============

    function test_AllSucceed_NoRefund() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch(bob);
        uint256 operatorBefore = operator.balance;

        vm.recordLogs();
        vm.prank(operator);
        hook.batchDistribute{value: 3 ether + _fee(3 ether)}(id, address(0), recipients, amounts);

        assertEq(operatorBefore - operator.balance, 3 ether + _fee(3 ether));
        assertEq(bob.balance, 2 ether);
        bytes32 refundTopic = BatchDistributeHook.BatchRefunded.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != refundTopic, "no refund expected");
        }
    }

    // ============ Failure modes ============

    function test_AllFail_Reverts() public {
        address[] memory recipients = new address[](1);
        recipients[0] = reverter;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        vm.prank(operator);
        vm.expectRevert(bytes("All transfers failed"));
        hook.batchDistribute{value: 2 ether}(id, address(0), recipients, amounts);
    }

    function test_Receive_RejectsAnyoneButSpraay() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory ret) = address(hook).call{value: 1}("");
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BatchDistributeHook.UnexpectedNativeSender.selector));
    }

    // ============ Operator that can't receive native currency ============

    /// @dev A skipped recipient must not be able to block the batch through the operator's refund
    function test_OperatorCannotReceiveRefund_BatchSucceedsAndRefundIsHeld() public {
        NoReceiveCaller contractOperator = _noReceiveOperator();
        (address[] memory recipients, uint256[] memory amounts) = _batch(reverter);
        uint256 undelivered = 2 ether + _fee(3 ether) - _fee(1 ether);

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.NativeRefundHeld(id, address(contractOperator), undelivered);
        vm.recordLogs();
        (bool ok,) = contractOperator.call{value: 3 ether + _fee(3 ether)}(
            address(hook),
            abi.encodeWithSelector(BatchDistributeHook.batchDistribute.selector, id, address(0), recipients, amounts)
        );

        assertTrue(ok);
        assertEq(alice.balance, 1 ether);
        assertEq(reverter.balance, 0);
        assertEq(feeRecipient.balance, _fee(1 ether));
        assertEq(address(contractOperator).balance, 0);
        assertEq(address(hook).balance, undelivered);
        assertEq(address(spray).balance, 0);
        assertEq(hook.pendingRefunds(address(contractOperator)), undelivered);
        assertEq(hook.totalPendingRefunds(), undelivered);
        _assertNoBatchRefunded();
    }

    function test_OperatorCannotReceiveRefund_Equal_BatchSucceedsAndRefundIsHeld() public {
        NoReceiveCaller contractOperator = _noReceiveOperator();
        address[] memory recipients = new address[](3);
        recipients[0] = alice;
        recipients[1] = reverter;
        recipients[2] = bob;
        uint256 undelivered = 1 ether + _fee(3 ether) - _fee(2 ether);

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.NativeRefundHeld(id, address(contractOperator), undelivered);
        (bool ok,) = contractOperator.call{value: 3 ether + _fee(3 ether)}(
            address(hook),
            abi.encodeWithSelector(
                BatchDistributeHook.batchDistributeEqual.selector, id, address(0), recipients, 1 ether
            )
        );

        assertTrue(ok);
        assertEq(alice.balance, 1 ether);
        assertEq(bob.balance, 1 ether);
        assertEq(address(hook).balance, undelivered);
        assertEq(hook.pendingRefunds(address(contractOperator)), undelivered);
    }

    /// @dev The excess goes out on its own and doesn't depend on recipients. Failing returns it to the caller.
    function test_OperatorCannotReceiveExcess_Reverts() public {
        NoReceiveCaller contractOperator = _noReceiveOperator();
        (address[] memory recipients, uint256[] memory amounts) = _batch(bob);

        (bool ok, bytes memory ret) = contractOperator.call{value: 3 ether + _fee(3 ether) + 5 ether}(
            address(hook),
            abi.encodeWithSelector(BatchDistributeHook.batchDistribute.selector, id, address(0), recipients, amounts)
        );

        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BatchDistributeHook.NativeTransferFailed.selector));
        assertEq(bob.balance, 0);
        assertEq(address(hook).balance, 0);
        assertEq(hook.totalPendingRefunds(), 0);
    }

    /// @dev This operator rejects any send, so its excess fails with or without a skipped recipient
    function test_OperatorCannotReceiveExcess_WithSkippedRecipient_Reverts() public {
        NoReceiveCaller contractOperator = _noReceiveOperator();
        (address[] memory recipients, uint256[] memory amounts) = _batch(reverter);

        (bool ok, bytes memory ret) = contractOperator.call{value: 3 ether + _fee(3 ether) + 1}(
            address(hook),
            abi.encodeWithSelector(BatchDistributeHook.batchDistribute.selector, id, address(0), recipients, amounts)
        );

        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BatchDistributeHook.NativeTransferFailed.selector));
        assertEq(alice.balance, 0);
        assertEq(hook.pendingRefunds(address(contractOperator)), 0);
    }

    /// @dev Regression: excess and undelivered funds used to share one send. A griefing recipient
    /// could push that send over what the operator accepts, and the excess check reverted the batch.
    function test_SkippedRecipientCannotTriggerExcessRevert() public {
        CappedOperator contractOperator = _cappedOperator();
        uint256 value = 3 ether + _fee(3 ether) + 0.01 ether;

        (address[] memory recipients, uint256[] memory amounts) = _batch(bob);
        (bool ok,) = contractOperator.call{value: value}(
            address(hook),
            abi.encodeWithSelector(BatchDistributeHook.batchDistribute.selector, id, address(0), recipients, amounts)
        );
        assertTrue(ok, "control: nobody skipped");
        assertEq(address(contractOperator).balance, 0.01 ether);

        (recipients, amounts) = _batch(reverter);
        uint256 undelivered = 2 ether + _fee(3 ether) - _fee(1 ether);
        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.NativeRefundHeld(id, address(contractOperator), undelivered);
        (ok,) = contractOperator.call{value: value}(
            address(hook),
            abi.encodeWithSelector(BatchDistributeHook.batchDistribute.selector, id, address(0), recipients, amounts)
        );

        assertTrue(ok, "griefing recipient must not revert the batch");
        assertEq(alice.balance, 2 ether);
        assertEq(address(contractOperator).balance, 0.02 ether, "excess still returned");
        assertEq(hook.pendingRefunds(address(contractOperator)), undelivered);
        assertEq(address(hook).balance, undelivered);
    }

    function test_CappedOperator_ExcessAndRefundBothWithinCap_BothSent() public {
        CappedOperator contractOperator = _cappedOperator();
        address[] memory recipients = new address[](2);
        recipients[0] = alice;
        recipients[1] = reverter;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 0.05 ether;
        uint256 undelivered = 0.05 ether + _fee(1.05 ether) - _fee(1 ether);

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.BatchRefunded(id, address(contractOperator), address(0), undelivered);
        (bool ok,) = contractOperator.call{value: 1.05 ether + _fee(1.05 ether) + 0.01 ether}(
            address(hook),
            abi.encodeWithSelector(BatchDistributeHook.batchDistribute.selector, id, address(0), recipients, amounts)
        );

        assertTrue(ok);
        assertEq(address(contractOperator).balance, undelivered + 0.01 ether);
        assertEq(hook.totalPendingRefunds(), 0);
        assertEq(address(hook).balance, 0);
    }

    /// @dev An overpayment the operator can't take fails the same way whether anyone is skipped or not
    function test_CappedOperator_ExcessAboveCap_RevertsEitherWay() public {
        CappedOperator contractOperator = _cappedOperator();
        uint256 value = 3 ether + _fee(3 ether) + 0.2 ether;

        (address[] memory recipients, uint256[] memory amounts) = _batch(bob);
        (bool ok, bytes memory ret) = contractOperator.call{value: value}(
            address(hook),
            abi.encodeWithSelector(BatchDistributeHook.batchDistribute.selector, id, address(0), recipients, amounts)
        );
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BatchDistributeHook.NativeTransferFailed.selector));

        (recipients, amounts) = _batch(reverter);
        (ok, ret) = contractOperator.call{value: value}(
            address(hook),
            abi.encodeWithSelector(BatchDistributeHook.batchDistribute.selector, id, address(0), recipients, amounts)
        );
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BatchDistributeHook.NativeTransferFailed.selector));
        assertEq(hook.totalPendingRefunds(), 0);
    }

    // ============ Balance increases that aren't failed deliveries ============

    function test_HookAsRecipient_Reverts() public {
        (address[] memory recipients, uint256[] memory amounts) = _batch(address(hook));

        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.InvalidRecipient.selector);
        hook.batchDistribute{value: 3 ether + _fee(3 ether)}(id, address(0), recipients, amounts);

        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.InvalidRecipient.selector);
        hook.batchDistribute(id, address(token), recipients, amounts);
    }

    function test_HookAsRecipient_Equal_Reverts() public {
        (address[] memory recipients,) = _batch(address(hook));

        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.InvalidRecipient.selector);
        hook.batchDistributeEqual{value: 2 ether + _fee(2 ether)}(id, address(0), recipients, 1 ether);

        vm.prank(operator);
        vm.expectRevert(BatchDistributeHook.InvalidRecipient.selector);
        hook.batchDistributeEqual(id, address(token), recipients, 1 ether);
    }

    /// @dev Can't be prevented, so it's documented: the event overstates undelivered here, though the
    /// funds are real and go to the operator. `RecipientFailed` shows nobody was skipped.
    function test_ForceSendDuringSpray_ReportedAsUndelivered() public {
        address forcer = address(new ForcingRecipient(payable(address(hook))));
        (address[] memory recipients, uint256[] memory amounts) = _batch(forcer);
        uint256 operatorBefore = operator.balance;

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.BatchRefunded(id, operator, address(0), 2 ether);
        vm.prank(operator);
        hook.batchDistribute{value: 3 ether + _fee(3 ether)}(id, address(0), recipients, amounts);

        assertEq(operatorBefore - operator.balance, 1 ether + _fee(3 ether));
        assertEq(address(hook).balance, 0);
    }

    /// @dev With nothing to return, the operator's inability to receive never comes up
    function test_OperatorCannotReceive_NothingToRefund_NothingHeld() public {
        NoReceiveCaller contractOperator = _noReceiveOperator();
        (address[] memory recipients, uint256[] memory amounts) = _batch(bob);

        vm.recordLogs();
        (bool ok,) = contractOperator.call{value: 3 ether + _fee(3 ether)}(
            address(hook),
            abi.encodeWithSelector(BatchDistributeHook.batchDistribute.selector, id, address(0), recipients, amounts)
        );

        assertTrue(ok);
        assertEq(address(hook).balance, 0);
        bytes32 heldTopic = BatchDistributeHook.NativeRefundHeld.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != heldTopic, "nothing should be held");
        }
    }

    /// @dev The held amount must stay claimable, and must not go to whichever operator calls next
    function test_HeldRefund_NotSweptToNextOperator_ThenClaimed() public {
        NoReceiveCaller contractOperator = _noReceiveOperator();
        (address[] memory recipients, uint256[] memory amounts) = _batch(reverter);
        uint256 undelivered = 2 ether + _fee(3 ether) - _fee(1 ether);
        (bool ok,) = contractOperator.call{value: 3 ether + _fee(3 ether)}(
            address(hook),
            abi.encodeWithSelector(BatchDistributeHook.batchDistribute.selector, id, address(0), recipients, amounts)
        );
        assertTrue(ok);

        uint256 operatorBefore = operator.balance;
        vm.prank(operator);
        hook.batchDistribute{value: 3 ether + _fee(3 ether)}(id, address(0), recipients, amounts);

        assertEq(operatorBefore - operator.balance, 1 ether + _fee(1 ether));
        assertEq(address(hook).balance, undelivered);

        address treasury = makeAddr("treasury");
        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.HeldRefundPaid(address(contractOperator), treasury, undelivered);
        (ok,) = contractOperator.call(
            address(hook), abi.encodeWithSelector(BatchDistributeHook.claimRefund.selector, treasury)
        );

        assertTrue(ok);
        assertEq(treasury.balance, undelivered);
        assertEq(address(hook).balance, 0);
        assertEq(hook.pendingRefunds(address(contractOperator)), 0);
        assertEq(hook.totalPendingRefunds(), 0);
    }

    // ============ Claiming held refunds ============

    function test_ClaimRefund_AccumulatesAcrossBatches_AndPaysOnce() public {
        NoReceiveCaller contractOperator = _noReceiveOperator();
        uint256 first = _holdRefund(payable(address(contractOperator)));
        uint256 second = _holdRefund(payable(address(contractOperator)));
        assertEq(hook.pendingRefunds(address(contractOperator)), first + second);
        assertEq(hook.totalPendingRefunds(), first + second);

        address treasury = makeAddr("treasury");
        bytes memory claim = abi.encodeWithSelector(BatchDistributeHook.claimRefund.selector, treasury);
        (bool ok,) = contractOperator.call(address(hook), claim);
        assertTrue(ok);
        assertEq(treasury.balance, first + second);

        bytes memory ret;
        (ok, ret) = contractOperator.call(address(hook), claim);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BatchDistributeHook.NothingToClaim.selector));
        assertEq(treasury.balance, first + second);
    }

    function test_ClaimRefund_TrackedPerOperator() public {
        NoReceiveCaller firstOperator = _noReceiveOperator();
        NoReceiveCaller secondOperator = _noReceiveOperator();
        uint256 held = _holdRefund(payable(address(firstOperator)));
        _holdRefund(payable(address(secondOperator)));

        address treasury = makeAddr("treasury");
        (bool ok,) = secondOperator.call(
            address(hook), abi.encodeWithSelector(BatchDistributeHook.claimRefund.selector, treasury)
        );

        assertTrue(ok);
        assertEq(treasury.balance, held);
        assertEq(hook.pendingRefunds(address(firstOperator)), held);
        assertEq(hook.pendingRefunds(address(secondOperator)), 0);
        assertEq(hook.totalPendingRefunds(), held);
        assertEq(address(hook).balance, held);
    }

    function test_ClaimRefund_WorksAfterOperatorRemoved() public {
        NoReceiveCaller contractOperator = _noReceiveOperator();
        uint256 held = _holdRefund(payable(address(contractOperator)));
        vm.prank(owner);
        hook.setOperator(address(contractOperator), false);

        address treasury = makeAddr("treasury");
        (bool ok,) = contractOperator.call(
            address(hook), abi.encodeWithSelector(BatchDistributeHook.claimRefund.selector, treasury)
        );

        assertTrue(ok);
        assertEq(treasury.balance, held);
    }

    function test_ClaimRefund_RevertIfNothingHeldForCaller() public {
        _holdRefund(payable(address(_noReceiveOperator())));

        vm.prank(alice);
        vm.expectRevert(BatchDistributeHook.NothingToClaim.selector);
        hook.claimRefund(alice);
    }

    function test_ClaimRefund_RevertIfZeroRecipient() public {
        NoReceiveCaller contractOperator = _noReceiveOperator();
        uint256 held = _holdRefund(payable(address(contractOperator)));

        (bool ok, bytes memory ret) = contractOperator.call(
            address(hook), abi.encodeWithSelector(BatchDistributeHook.claimRefund.selector, address(0))
        );

        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BatchDistributeHook.ZeroAddress.selector));
        assertEq(hook.pendingRefunds(address(contractOperator)), held);
    }

    /// @dev Claiming to itself fails for an operator that can't receive, and must lose nothing
    function test_ClaimRefund_RevertIfRecipientRejects_KeepsRecord() public {
        NoReceiveCaller contractOperator = _noReceiveOperator();
        uint256 held = _holdRefund(payable(address(contractOperator)));

        (bool ok, bytes memory ret) = contractOperator.call(
            address(hook), abi.encodeWithSelector(BatchDistributeHook.claimRefund.selector, contractOperator)
        );

        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BatchDistributeHook.NativeTransferFailed.selector));
        assertEq(hook.pendingRefunds(address(contractOperator)), held);
        assertEq(hook.totalPendingRefunds(), held);
    }

    function test_ClaimRefund_ReentryCannotPayTwice() public {
        SwitchableOperator contractOperator = _switchableOperator();
        uint256 held = _holdRefund(payable(address(contractOperator)));
        bytes memory claim = abi.encodeWithSelector(BatchDistributeHook.claimRefund.selector, contractOperator);
        contractOperator.setAccepting(true);
        contractOperator.setReenterData(claim);

        (bool ok, bytes memory ret) = contractOperator.call(address(hook), claim);

        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(BatchDistributeHook.NativeTransferFailed.selector));
        assertEq(address(contractOperator).balance, 0);
        assertEq(hook.pendingRefunds(address(contractOperator)), held);
        assertEq(address(hook).balance, held);
    }

    /// @dev A temporarily closed receive() holds the funds, and the operator gets them back later
    function test_SwitchableOperator_RefundForwardedOnceAccepting() public {
        SwitchableOperator contractOperator = _switchableOperator();
        uint256 held = _holdRefund(payable(address(contractOperator)));
        contractOperator.setAccepting(true);

        (bool ok,) = contractOperator.call(
            address(hook), abi.encodeWithSelector(BatchDistributeHook.claimRefund.selector, contractOperator)
        );

        assertTrue(ok);
        assertEq(address(contractOperator).balance, held);
        assertEq(hook.totalPendingRefunds(), 0);
    }

    // ============ Owner release of held refunds ============

    function test_ReleaseRefund_PaysOperatorOnly() public {
        SwitchableOperator contractOperator = _switchableOperator();
        uint256 held = _holdRefund(payable(address(contractOperator)));
        contractOperator.setAccepting(true);

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.HeldRefundPaid(address(contractOperator), address(contractOperator), held);
        vm.prank(owner);
        hook.releaseRefund(address(contractOperator));

        assertEq(address(contractOperator).balance, held);
        assertEq(owner.balance, 0);
        assertEq(hook.pendingRefunds(address(contractOperator)), 0);
        assertEq(hook.totalPendingRefunds(), 0);
    }

    function test_ReleaseRefund_RevertIfNotOwner() public {
        address contractOperator = address(_switchableOperator());
        _holdRefund(payable(contractOperator));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        hook.releaseRefund(contractOperator);
    }

    function test_ReleaseRefund_RevertIfNothingHeld() public {
        vm.prank(owner);
        vm.expectRevert(BatchDistributeHook.NothingToClaim.selector);
        hook.releaseRefund(operator);
    }

    function test_ReleaseRefund_RevertIfOperatorStillRejects_KeepsRecord() public {
        address contractOperator = address(_switchableOperator());
        uint256 held = _holdRefund(payable(contractOperator));

        vm.prank(owner);
        vm.expectRevert(BatchDistributeHook.NativeTransferFailed.selector);
        hook.releaseRefund(contractOperator);

        assertEq(hook.pendingRefunds(contractOperator), held);
        assertEq(hook.totalPendingRefunds(), held);
    }

    // ============ Renouncing ownership ============

    function test_RenounceOwnership_Disabled() public {
        vm.prank(owner);
        vm.expectRevert(BatchDistributeHook.RenounceDisabled.selector);
        hook.renounceOwnership();
        assertEq(hook.owner(), owner);
    }

    function test_RenounceOwnership_DisabledForOthersToo() public {
        vm.prank(alice);
        vm.expectRevert(BatchDistributeHook.RenounceDisabled.selector);
        hook.renounceOwnership();
    }

    // ============ Rescuing native currency ============

    function test_RescueNative_EmitsEvent() public {
        _forceSend(1 ether);
        address treasury = makeAddr("treasury");

        vm.expectEmit(true, true, true, true, address(hook));
        emit BatchDistributeHook.NativeRescued(treasury, 1 ether);
        vm.prank(owner);
        hook.rescueTokens(address(0), treasury, 1 ether);
    }

    function test_RescueNative_CannotTouchHeldRefunds() public {
        NoReceiveCaller contractOperator = _noReceiveOperator();
        uint256 held = _holdRefund(payable(address(contractOperator)));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BatchDistributeHook.RescueExceedsAvailable.selector, 1, 0));
        hook.rescueTokens(address(0), owner, 1);

        assertEq(address(hook).balance, held);
        assertEq(owner.balance, 0);
    }

    function test_RescueNative_TakesOnlyWhatIsAboveHeld_ThenClaimStillPays() public {
        NoReceiveCaller contractOperator = _noReceiveOperator();
        uint256 held = _holdRefund(payable(address(contractOperator)));
        _forceSend(1 ether);
        address treasury = makeAddr("treasury");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(BatchDistributeHook.RescueExceedsAvailable.selector, 1 ether + 1, 1 ether)
        );
        hook.rescueTokens(address(0), treasury, 1 ether + 1);

        vm.prank(owner);
        hook.rescueTokens(address(0), treasury, 1 ether);
        assertEq(treasury.balance, 1 ether);
        assertEq(address(hook).balance, held);

        address claimant = makeAddr("claimant");
        (bool ok,) = contractOperator.call(
            address(hook), abi.encodeWithSelector(BatchDistributeHook.claimRefund.selector, claimant)
        );
        assertTrue(ok);
        assertEq(claimant.balance, held);
        assertEq(address(hook).balance, 0);
    }

    function test_RescueNative_RecoversForceSentETH() public {
        _forceSend(5 ether);
        address treasury = makeAddr("treasury");

        vm.prank(owner);
        hook.rescueTokens(address(0), treasury, 2 ether);
        assertEq(treasury.balance, 2 ether);
        assertEq(address(hook).balance, 3 ether);

        vm.prank(owner);
        hook.rescueTokens(address(0), treasury, 3 ether);
        assertEq(treasury.balance, 5 ether);
        assertEq(address(hook).balance, 0);
    }

    function test_RescueNative_ForceSentETHNotSweptToOperator() public {
        _forceSend(5 ether);
        (address[] memory recipients, uint256[] memory amounts) = _batch(reverter);
        uint256 operatorBefore = operator.balance;

        vm.prank(operator);
        hook.batchDistribute{value: 3 ether + _fee(3 ether)}(id, address(0), recipients, amounts);

        assertEq(operatorBefore - operator.balance, 1 ether + _fee(1 ether));
        assertEq(address(hook).balance, 5 ether);
    }

    function test_RescueNative_RevertIfNotOwner() public {
        _forceSend(1 ether);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, operator));
        hook.rescueTokens(address(0), operator, 1 ether);
        assertEq(address(hook).balance, 1 ether);
    }

    function test_RescueNative_RevertIfZeroRecipient() public {
        _forceSend(1 ether);
        vm.prank(owner);
        vm.expectRevert(BatchDistributeHook.ZeroAddress.selector);
        hook.rescueTokens(address(0), address(0), 1 ether);
    }

    function test_RescueNative_RevertIfRecipientRejects() public {
        _forceSend(1 ether);
        vm.prank(owner);
        vm.expectRevert(BatchDistributeHook.NativeTransferFailed.selector);
        hook.rescueTokens(address(0), reverter, 1 ether);
        assertEq(address(hook).balance, 1 ether);
    }

    function test_RescueNative_RevertIfAmountExceedsBalance() public {
        _forceSend(1 ether);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BatchDistributeHook.RescueExceedsAvailable.selector, 2 ether, 1 ether));
        hook.rescueTokens(address(0), owner, 2 ether);
    }

    // ============ Migration ============

    /// @dev Before the fix one bad recipient reverts. Repointing the hook at the fix solves it.
    function test_LegacySpraay_StillGriefed_ThenFixedByRepointing() public {
        MockSpraay legacy = new MockSpraay(feeRecipient, FEE_BPS);
        vm.prank(owner);
        hook.setSpraayContract(address(legacy));
        (address[] memory recipients, uint256[] memory amounts) = _batch(reverter);

        vm.prank(operator);
        vm.expectRevert(bytes("ETH transfer failed"));
        hook.batchDistribute{value: 3 ether + _fee(3 ether)}(id, address(0), recipients, amounts);

        vm.prank(owner);
        hook.setSpraayContract(address(spray));
        vm.prank(operator);
        hook.batchDistribute{value: 3 ether + _fee(3 ether)}(id, address(0), recipients, amounts);
        assertEq(alice.balance, 1 ether);
    }

    // ============ Helpers ============

    function _noReceiveOperator() internal returns (NoReceiveCaller contractOperator) {
        contractOperator = new NoReceiveCaller();
        vm.prank(owner);
        hook.setOperator(address(contractOperator), true);
        vm.deal(address(this), 10 ether);
    }

    function _cappedOperator() internal returns (CappedOperator contractOperator) {
        contractOperator = new CappedOperator();
        vm.prank(owner);
        hook.setOperator(address(contractOperator), true);
        vm.deal(address(this), 10 ether);
    }

    function _switchableOperator() internal returns (SwitchableOperator contractOperator) {
        contractOperator = new SwitchableOperator();
        vm.prank(owner);
        hook.setOperator(address(contractOperator), true);
    }

    /// @dev Runs a batch with one skipped recipient, as an operator that isn't accepting native currency
    function _holdRefund(address payable contractOperator) internal returns (uint256 undelivered) {
        (address[] memory recipients, uint256[] memory amounts) = _batch(reverter);
        uint256 value = 3 ether + _fee(3 ether);
        undelivered = 2 ether + _fee(3 ether) - _fee(1 ether);
        vm.deal(address(this), value);
        (bool ok,) = NoReceiveCaller(contractOperator).call{value: value}(
            address(hook),
            abi.encodeWithSelector(BatchDistributeHook.batchDistribute.selector, id, address(0), recipients, amounts)
        );
        assertTrue(ok, "batch should succeed");
    }

    function _forceSend(uint256 amount) internal {
        uint256 hookBefore = address(hook).balance;
        vm.deal(address(this), amount);
        new ForceSender{value: amount}(payable(address(hook)));
        assertEq(address(hook).balance, hookBefore + amount);
    }

    function _assertNoBatchRefunded() internal view {
        bytes32 refundTopic = BatchDistributeHook.BatchRefunded.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(logs.length, 0, "logs not recorded");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != refundTopic, "no refund expected");
        }
    }

    function _fee(uint256 amount) internal pure returns (uint256) {
        return amount * FEE_BPS / 10_000;
    }

    /// @dev `alice` gets 1 ether and `second` gets 2 ether
    function _batch(address second) internal view returns (address[] memory recipients, uint256[] memory amounts) {
        recipients = new address[](2);
        amounts = new uint256[](2);
        recipients[0] = alice;
        recipients[1] = second;
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
    }
}
