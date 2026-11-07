// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISpraay} from "./interfaces/ISpraay.sol";

/// @notice BatchDistributeHook lets the operators of pools that use this hook push-distribute
/// tokens (rewards, incentives, airdrops, revenue shares) to up to 200 recipients in a single
/// transaction, by routing the transfer through Spraay's on-chain batch contract.
///
/// Uniswap V4's native incentive flows are pull-based (LPs accrue fees, `donate` credits in-range
/// liquidity). This hook complements them with a push model: the operator decides the recipient
/// list off-chain and delivers everything in one call, with no claim step for the recipients.
///
/// Funding model: the hook holds no funds between calls, apart from the held refunds described
/// below. Each distribution pulls exactly `amount + Spraay fee` from the calling operator (ERC-20
/// via transferFrom, native via msg.value), approves Spraay for exactly that amount and calls it in
/// the same transaction. Excess native currency is refunded to the operator, and the call reverts if
/// the operator can't receive it. Distributions never touch PoolManager accounting.
///
/// Partial delivery: Spraay skips a recipient whose transfer fails and refunds its amount and fee to
/// this hook, which forwards the refund to the operator, in the same transaction unless the operator
/// can't receive it. A successful call does not mean every recipient was paid: `BatchRefunded` and
/// `NativeRefundHeld` report the undelivered amount, and Spraay's `RecipientFailed` events name the
/// recipients. The refund is measured from balances, so this hook
/// works with both refunding and older all-or-nothing Spraay deployments. It also means funds a
/// recipient force-sends here during the spray are reported as undelivered, so `RecipientFailed` is
/// the authority on who was skipped. Listing this hook as a recipient is rejected for the same reason.
///
/// Operators that can't receive native currency: a failed send of undelivered funds never reverts
/// the batch, because any skipped recipient could otherwise use it to block the whole distribution.
/// The funds are recorded in `pendingRefunds` until the operator calls `claimRefund`, or the owner
/// calls `releaseRefund`, which can only pay the operator itself. `rescueTokens` can't touch them.
/// Any failed send counts, including a temporary one such as a paused `receive()`. The distribution
/// functions return nothing, so a contract operator that needs to know on-chain must compare
/// `pendingRefunds` before and after the call; off-chain, watch for `NativeRefundHeld`. A
/// contract that can neither receive native currency nor call `claimRefund` loses access to held
/// funds for good, so contract operators need at least one of the two.
///
/// Hook callbacks: `afterInitialize` registers pools that use this hook, so every distribution is
/// attributable to a real V4 pool; `afterDonate` emits an event so indexers can see pull-side
/// (donate) and push-side (batch distribute) incentives for the same pool. Neither callback
/// returns a delta, so swaps and liquidity operations on the pool are unaffected.
///
/// @dev Fee-on-transfer and rebasing tokens are not supported: Spraay pulls the exact gross amount.
contract BatchDistributeHook is BaseHook, Ownable2Step, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    /// @notice Spraay enforces the same limit on-chain; checked here to fail early with a clear error
    uint256 public constant MAX_RECIPIENTS = 200;

    /// @notice Address of Spraay's batch distribution contract on this chain
    ISpraay public spraay;

    /// @notice Accounts allowed to trigger distributions
    mapping(address => bool) public isOperator;

    /// @notice Pools initialized with this hook
    mapping(PoolId => bool) public isRegisteredPool;

    /// @notice Undelivered native currency each operator couldn't receive and has yet to claim
    mapping(address => uint256) public pendingRefunds;

    /// @notice Sum of `pendingRefunds`, which `rescueTokens` can't touch
    uint256 public totalPendingRefunds;

    event SpraayContractUpdated(address indexed oldSpraay, address indexed newSpraay);
    event OperatorUpdated(address indexed operator, bool allowed);
    event PoolRegistered(PoolId indexed poolId);
    event PoolDonation(PoolId indexed poolId, address indexed sender, uint256 amount0, uint256 amount1);
    /// @notice A distribution was requested. Amounts are as quoted, before any skipped recipients.
    /// The operator's actual cost is `totalAmount + feeAmount` minus any `BatchRefunded.amount` or
    /// `NativeRefundHeld.undelivered`, the latter being paid out later through `HeldRefundPaid`.
    event BatchDistributed(
        PoolId indexed poolId,
        address indexed operator,
        address indexed token,
        uint256 recipientCount,
        uint256 totalAmount,
        uint256 feeAmount
    );
    /// @notice Part of a distribution went undelivered, and `amount` was returned to the operator
    event BatchRefunded(PoolId indexed poolId, address indexed operator, address indexed token, uint256 amount);
    /// @notice The operator couldn't receive `undelivered`, so it was added to `pendingRefunds`.
    /// Emitted instead of `BatchRefunded`.
    event NativeRefundHeld(PoolId indexed poolId, address indexed operator, uint256 undelivered);
    /// @notice A held refund left the hook, through `claimRefund` or `releaseRefund`
    event HeldRefundPaid(address indexed operator, address indexed to, uint256 amount);
    /// @notice The owner recovered native currency that isn't owed to any operator
    event NativeRescued(address indexed to, uint256 amount);

    error NotOperator();
    error ZeroAddress();
    error PoolNotRegistered();
    error NoRecipients();
    error TooManyRecipients(uint256 count, uint256 max);
    error LengthMismatch();
    error InsufficientNativeAmount(uint256 required, uint256 provided);
    error UnexpectedNativeAmount();
    error NativeTransferFailed();
    error UnexpectedNativeSender();
    error NothingToClaim();
    error RescueExceedsAvailable(uint256 requested, uint256 available);
    error RenounceDisabled();
    error InvalidRecipient();

    modifier onlyOperator() {
        if (!isOperator[msg.sender]) revert NotOperator();
        _;
    }

    /// @param _poolManager The Uniswap V4 PoolManager on this chain
    /// @param _spraay Spraay's batch contract on this chain
    /// @param _owner Admin account; passed explicitly because deployment goes through a CREATE2 factory
    /// @param _operator Initial distribution operator (may be address(0) to set later)
    constructor(IPoolManager _poolManager, address _spraay, address _owner, address _operator)
        BaseHook(_poolManager)
        Ownable(_owner)
    {
        if (_spraay == address(0)) revert ZeroAddress();
        spraay = ISpraay(_spraay);
        emit SpraayContractUpdated(address(0), _spraay);

        if (_operator != address(0)) {
            isOperator[_operator] = true;
            emit OperatorUpdated(_operator, true);
        }
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: true,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ Hook callbacks ============

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        PoolId id = key.toId();
        isRegisteredPool[id] = true;
        emit PoolRegistered(id);
        return this.afterInitialize.selector;
    }

    function _afterDonate(address sender, PoolKey calldata key, uint256 amount0, uint256 amount1, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        emit PoolDonation(key.toId(), sender, amount0, amount1);
        return this.afterDonate.selector;
    }

    // ============ Distribution ============

    /// @notice Push-distribute variable amounts to many recipients in one transaction
    /// @param poolId Pool the distribution is attributed to (must use this hook)
    /// @param token ERC-20 to distribute, or address(0) for the chain's native currency
    /// @param recipients Recipient addresses (max 200)
    /// @param amounts Amount for each recipient, excluding the Spraay fee
    /// @dev ERC-20: operator must approve this hook for `quoteTotalCost(sum(amounts))`.
    /// Native: msg.value must be at least `quoteTotalCost(sum(amounts))`. Any excess is refunded, and
    /// the call reverts if the operator can't receive it. An undelivered amount the operator can't
    /// receive is held for `claimRefund` instead of reverting.
    function batchDistribute(PoolId poolId, address token, address[] calldata recipients, uint256[] calldata amounts)
        external
        payable
        nonReentrant
        onlyOperator
    {
        _checkPoolAndRecipients(poolId, recipients.length);
        if (recipients.length != amounts.length) revert LengthMismatch();

        ISpraay.Recipient[] memory batch = new ISpraay.Recipient[](recipients.length);
        uint256 totalAmount = 0;
        for (uint256 i; i < recipients.length; ++i) {
            if (recipients[i] == address(this)) revert InvalidRecipient();
            batch[i] = ISpraay.Recipient({recipient: payable(recipients[i]), amount: amounts[i]});
            totalAmount += amounts[i];
        }

        ISpraay _spraay = spraay;
        uint256 requiredAmount = _prepare(_spraay, token, totalAmount);
        emit BatchDistributed(poolId, msg.sender, token, recipients.length, totalAmount, requiredAmount - totalAmount);

        uint256 balanceBefore = _balanceBeforeCall(token);
        if (token == address(0)) {
            _spraay.sprayETH{value: requiredAmount}(batch);
        } else {
            _pullAndApprove(token, address(_spraay), requiredAmount);
            _spraay.sprayToken(token, batch);
        }
        _returnToOperator(poolId, token, requiredAmount, balanceBefore);
    }

    /// @notice Push-distribute the same amount to every recipient in one transaction
    /// @param poolId Pool the distribution is attributed to (must use this hook)
    /// @param token ERC-20 to distribute, or address(0) for the chain's native currency
    /// @param recipients Recipient addresses (max 200)
    /// @param amountEach Amount each recipient receives, excluding the Spraay fee
    function batchDistributeEqual(PoolId poolId, address token, address[] calldata recipients, uint256 amountEach)
        external
        payable
        nonReentrant
        onlyOperator
    {
        _checkPoolAndRecipients(poolId, recipients.length);

        address payable[] memory batch = new address payable[](recipients.length);
        for (uint256 i; i < recipients.length; ++i) {
            if (recipients[i] == address(this)) revert InvalidRecipient();
            batch[i] = payable(recipients[i]);
        }

        ISpraay _spraay = spraay;
        uint256 totalAmount = amountEach * recipients.length;
        uint256 requiredAmount = _prepare(_spraay, token, totalAmount);
        emit BatchDistributed(poolId, msg.sender, token, recipients.length, totalAmount, requiredAmount - totalAmount);

        uint256 balanceBefore = _balanceBeforeCall(token);
        if (token == address(0)) {
            _spraay.sprayEqual{value: requiredAmount}(address(0), batch, amountEach);
        } else {
            _pullAndApprove(token, address(_spraay), requiredAmount);
            _spraay.sprayEqual(token, batch, amountEach);
        }
        _returnToOperator(poolId, token, requiredAmount, balanceBefore);
    }

    /// @notice Accepts refunds from Spraay only, so native currency can't be sent here by mistake.
    /// Anything forced in another way, such as by `selfdestruct`, is recovered with `rescueTokens`.
    receive() external payable {
        if (msg.sender != address(spraay)) revert UnexpectedNativeSender();
    }

    /// @notice Withdraw the caller's held refund. Works after the caller stops being an operator.
    /// @param to Receives the funds, so an operator that can't receive native currency can still claim
    function claimRefund(address to) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        _payHeldRefund(msg.sender, to);
    }

    /// @notice Amount (distribution + Spraay fee) an operator must provide to distribute `totalAmount`
    function quoteTotalCost(uint256 totalAmount) external view returns (uint256) {
        return spraay.calculateTotalCost(totalAmount);
    }

    // ============ Admin ============

    /// @notice Point the hook at a different Spraay deployment (e.g. after a Spraay upgrade)
    function setSpraayContract(address newSpraay) external onlyOwner {
        if (newSpraay == address(0)) revert ZeroAddress();
        emit SpraayContractUpdated(address(spraay), newSpraay);
        spraay = ISpraay(newSpraay);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        isOperator[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    /// @notice Recover stray ERC-20s or force-sent native currency. Held refunds are excluded.
    /// @param token ERC-20 to recover, or address(0) for the chain's native currency
    function rescueTokens(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(0)) {
            uint256 available = address(this).balance - totalPendingRefunds;
            if (amount > available) revert RescueExceedsAvailable(amount, available);
            (bool success,) = to.call{value: amount}("");
            if (!success) revert NativeTransferFailed();
            emit NativeRescued(to, amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /// @notice Pay an operator's held refund to the operator itself, for a contract that can receive
    /// native currency now but has no way to call `claimRefund`.
    function releaseRefund(address operator) external onlyOwner nonReentrant {
        _payHeldRefund(operator, operator);
    }

    /// @notice Disabled: without an owner, stray funds could never be rescued
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ============ Internal ============

    function _checkPoolAndRecipients(PoolId poolId, uint256 count) internal view {
        if (!isRegisteredPool[poolId]) revert PoolNotRegistered();
        if (count == 0) revert NoRecipients();
        if (count > MAX_RECIPIENTS) revert TooManyRecipients(count, MAX_RECIPIENTS);
    }

    /// @dev Quotes the gross amount (distribution + Spraay fee) and validates msg.value against it
    function _prepare(ISpraay _spraay, address token, uint256 totalAmount)
        internal
        view
        returns (uint256 requiredAmount)
    {
        requiredAmount = _spraay.calculateTotalCost(totalAmount);
        if (token == address(0)) {
            if (msg.value < requiredAmount) revert InsufficientNativeAmount(requiredAmount, msg.value);
        } else if (msg.value != 0) {
            revert UnexpectedNativeAmount();
        }
    }

    /// @dev The hook's own balance, excluding this call's msg.value. Anything above it after the
    /// spray belongs to the operator; tokens stranded here earlier stay put for `rescueTokens`.
    function _balanceBeforeCall(address token) internal view returns (uint256) {
        if (token == address(0)) return address(this).balance - msg.value;
        return IERC20(token).balanceOf(address(this));
    }

    /// @dev Sends the operator everything Spraay refunded, plus any msg.value above the quote.
    /// `BatchRefunded` reports only the undelivered part, so excess msg.value is not counted.
    /// The two go out as separate sends, so that skipped recipients can't change whether the excess
    /// is accepted. A failed excess send reverts, handing the overpayment straight back to the caller.
    /// A failed send of undelivered funds must not revert, or a skipped recipient could block the batch.
    function _returnToOperator(PoolId poolId, address token, uint256 requiredAmount, uint256 balanceBefore) internal {
        uint256 undelivered;
        if (token == address(0)) {
            uint256 excess = msg.value - requiredAmount;
            undelivered = address(this).balance - balanceBefore - excess;
            if (excess > 0) {
                (bool excessSent,) = msg.sender.call{value: excess}("");
                if (!excessSent) revert NativeTransferFailed();
            }
            if (undelivered > 0) {
                (bool undeliveredSent,) = msg.sender.call{value: undelivered}("");
                if (!undeliveredSent) {
                    pendingRefunds[msg.sender] += undelivered;
                    totalPendingRefunds += undelivered;
                    emit NativeRefundHeld(poolId, msg.sender, undelivered);
                    return;
                }
            }
        } else {
            undelivered = IERC20(token).balanceOf(address(this)) - balanceBefore;
            if (undelivered > 0) IERC20(token).safeTransfer(msg.sender, undelivered);
        }
        if (undelivered > 0) emit BatchRefunded(poolId, msg.sender, token, undelivered);
    }

    /// @dev Clears the record before the external call. The callers are `nonReentrant`.
    function _payHeldRefund(address operator, address to) internal {
        uint256 amount = pendingRefunds[operator];
        if (amount == 0) revert NothingToClaim();

        pendingRefunds[operator] = 0;
        totalPendingRefunds -= amount;

        (bool success,) = to.call{value: amount}("");
        if (!success) revert NativeTransferFailed();
        emit HeldRefundPaid(operator, to, amount);
    }

    function _pullAndApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(token).forceApprove(spender, amount);
    }
}
