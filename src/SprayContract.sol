// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SprayContract
 * @notice Enables batch token transfers to multiple recipients in a single transaction
 * @dev Supports both native ETH and ERC20 tokens with a 0.3% protocol fee
 *
 * Partial delivery: a recipient whose transfer fails is skipped rather than reverting the batch.
 * A successful transaction therefore does NOT mean every recipient was paid. Callers must check the
 * returned `failedCount` or the `RecipientFailed` events. The fee is charged only on the delivered
 * amount, and everything undelivered is refunded to `msg.sender` in the same transaction. A batch in
 * which no recipient can be paid reverts.
 *
 * Griefing limits:
 *  - ETH recipients get at most RECIPIENT_GAS_LIMIT gas. Contracts whose receive logic costs more
 *    are skipped and refunded.
 *  - Failure data is copied up to MAX_REASON_BYTES, so a recipient cannot make the caller pay for
 *    an arbitrarily large revert payload.
 *  - A transfer is only attempted with at least MIN_GAS_PER_TRANSFER available. Otherwise the batch
 *    reverts, so a low gas limit cannot make a healthy recipient look like it failed.
 *
 * Unsupported tokens: fee-on-transfer and rebasing tokens, and tokens that call into the recipient
 * during `transfer` (e.g. ERC-777). ERC-20 transfers are not gas-capped, so a recipient of a callback
 * token can still burn the batch's gas.
 *
 * @custom:website https://spraay.app
 * @custom:author @lostpoet
 */
contract SprayContract is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // ============ Events ============

    /// @dev `totalAmount` and `recipientCount` cover delivered transfers only
    event SprayETHExecuted(
        address indexed sender, uint256 totalAmount, uint256 recipientCount, uint256 feeAmount, uint256 timestamp
    );

    /// @dev `totalAmount` and `recipientCount` cover delivered transfers only
    event SprayTokenExecuted(
        address indexed sender,
        address indexed token,
        uint256 totalAmount,
        uint256 recipientCount,
        uint256 feeAmount,
        uint256 timestamp
    );

    /// @notice A recipient was skipped and its amount refunded to the caller
    /// @param reason The failure's return data, truncated to MAX_REASON_BYTES
    event RecipientFailed(address indexed recipient, uint256 amount, bytes reason);

    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);
    event EmergencyWithdraw(address indexed token, uint256 amount);

    // ============ State Variables ============

    uint256 public feeBps; // Fee in basis points (30 = 0.3%)
    address public feeRecipient; // Address that receives protocol fees

    uint256 public constant MAX_FEE_BPS = 500; // 5% max fee cap
    uint256 public constant MAX_RECIPIENTS = 200; // Safety limit per transaction

    uint256 public constant RECIPIENT_GAS_LIMIT = 50_000; // Gas forwarded to each ETH recipient
    uint256 public constant MAX_REASON_BYTES = 256; // Failure data kept per skipped recipient
    uint256 public constant MIN_GAS_PER_TRANSFER = 150_000; // Gas required before each transfer attempt

    // ============ Structs ============

    struct Recipient {
        address payable recipient;
        uint256 amount;
    }

    // ============ Constructor ============

    constructor(address _feeRecipient, uint256 _feeBps) Ownable(msg.sender) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_feeBps <= MAX_FEE_BPS, "Fee too high");

        feeRecipient = _feeRecipient;
        feeBps = _feeBps;
    }

    // ============ Core Functions ============

    /**
     * @notice Spray native ETH to multiple recipients with variable amounts
     * @param recipients Array of Recipient structs (address + amount)
     * @return failedCount Number of recipients skipped; see `RecipientFailed` for which ones
     * @dev msg.value must cover totalAmount + fee. Excess and undelivered amounts are refunded.
     */
    function sprayETH(Recipient[] calldata recipients)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 failedCount)
    {
        uint256 totalAmount = _validateAndSum(recipients);
        require(msg.value >= totalAmount + _feeOn(totalAmount), "Insufficient ETH");

        uint256 delivered = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            if (_trySendETH(recipients[i].recipient, recipients[i].amount)) {
                delivered += recipients[i].amount;
            } else {
                failedCount++;
            }
        }

        _settleETH(delivered, recipients.length - failedCount);
    }

    /**
     * @notice Spray ERC-20 tokens to multiple recipients with variable amounts
     * @param token Address of the ERC-20 token
     * @param recipients Array of Recipient structs (address + amount)
     * @return failedCount Number of recipients skipped; see `RecipientFailed` for which ones
     * @dev Caller must approve this contract for totalAmount + fee beforehand. Undelivered amounts
     * are refunded.
     */
    function sprayToken(address token, Recipient[] calldata recipients)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 failedCount)
    {
        require(token != address(0), "Invalid token");

        uint256 totalAmount = _validateAndSum(recipients);
        uint256 requiredAmount = totalAmount + _feeOn(totalAmount);

        // Pull total from sender
        IERC20(token).safeTransferFrom(msg.sender, address(this), requiredAmount);

        uint256 delivered = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            if (_tryTransferToken(token, recipients[i].recipient, recipients[i].amount)) {
                delivered += recipients[i].amount;
            } else {
                failedCount++;
            }
        }

        _settleToken(token, requiredAmount, delivered, recipients.length - failedCount);
    }

    /**
     * @notice Gas-efficient spray when all recipients get the same amount
     * @param token Address of token (address(0) for ETH)
     * @param recipients Array of recipient addresses
     * @param amountPerRecipient Amount to send to each recipient
     * @return failedCount Number of recipients skipped; see `RecipientFailed` for which ones
     */
    function sprayEqual(address token, address payable[] calldata recipients, uint256 amountPerRecipient)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 failedCount)
    {
        require(recipients.length > 0, "No recipients");
        require(recipients.length <= MAX_RECIPIENTS, "Too many recipients");
        require(amountPerRecipient > 0, "Invalid amount");

        uint256 totalAmount = amountPerRecipient * recipients.length;
        uint256 requiredAmount = totalAmount + _feeOn(totalAmount);

        if (token == address(0)) {
            // ETH equal spray
            require(msg.value >= requiredAmount, "Insufficient ETH");

            for (uint256 i = 0; i < recipients.length; i++) {
                require(recipients[i] != address(0) && recipients[i] != address(this), "Invalid recipient");
                if (!_trySendETH(recipients[i], amountPerRecipient)) failedCount++;
            }

            uint256 count = recipients.length - failedCount;
            _settleETH(amountPerRecipient * count, count);
        } else {
            // ERC20 equal spray
            require(msg.value == 0, "Unexpected ETH");
            IERC20(token).safeTransferFrom(msg.sender, address(this), requiredAmount);

            for (uint256 i = 0; i < recipients.length; i++) {
                require(recipients[i] != address(0) && recipients[i] != address(this), "Invalid recipient");
                if (!_tryTransferToken(token, recipients[i], amountPerRecipient)) failedCount++;
            }

            uint256 count = recipients.length - failedCount;
            _settleToken(token, requiredAmount, amountPerRecipient * count, count);
        }
    }

    // ============ Admin Functions ============

    function updateFee(uint256 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "Fee too high");
        uint256 oldFee = feeBps;
        feeBps = newFeeBps;
        emit FeeUpdated(oldFee, newFeeBps);
    }

    function updateFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != address(0), "Invalid address");
        address oldRecipient = feeRecipient;
        feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(oldRecipient, newFeeRecipient);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            (bool success,) = payable(owner()).call{value: amount}("");
            require(success, "ETH withdrawal failed");
        } else {
            IERC20(token).safeTransfer(owner(), amount);
        }
        emit EmergencyWithdraw(token, amount);
    }

    // ============ View Functions ============

    function calculateTotalCost(uint256 totalAmount) external view returns (uint256) {
        return totalAmount + _feeOn(totalAmount);
    }

    function calculateFee(uint256 amount) external view returns (uint256) {
        return _feeOn(amount);
    }

    // Accept ETH
    receive() external payable {}

    // ============ Internal ============

    function _feeOn(uint256 amount) private view returns (uint256) {
        return (amount * feeBps) / 10000;
    }

    function _validateAndSum(Recipient[] calldata recipients) private view returns (uint256 totalAmount) {
        require(recipients.length > 0, "No recipients");
        require(recipients.length <= MAX_RECIPIENTS, "Too many recipients");

        for (uint256 i = 0; i < recipients.length; i++) {
            address to = recipients[i].recipient;
            require(to != address(0) && to != address(this), "Invalid recipient");
            require(recipients[i].amount > 0, "Invalid amount");
            totalAmount += recipients[i].amount;
        }
    }

    /// @dev Return data is deliberately not copied by the call; see `_logFailure`
    function _trySendETH(address to, uint256 amount) private returns (bool success) {
        require(gasleft() >= MIN_GAS_PER_TRANSFER, "Insufficient gas");
        assembly ("memory-safe") {
            success := call(RECIPIENT_GAS_LIMIT, to, amount, 0, 0, 0, 0)
        }
        if (!success) _logFailure(to, amount);
    }

    /// @dev Accepts what SafeERC20 accepts: no return data (USDT-style) or a first word equal to 1.
    /// The token's code was already proven by the safeTransferFrom that funded this batch.
    function _tryTransferToken(address token, address to, uint256 amount) private returns (bool success) {
        require(gasleft() >= MIN_GAS_PER_TRANSFER, "Insufficient gas");
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        assembly ("memory-safe") {
            mstore(0, 0)
            success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            if success {
                success := or(iszero(returndatasize()), and(gt(returndatasize(), 0x1f), eq(mload(0), 1)))
            }
        }
        if (!success) _logFailure(to, amount);
    }

    /// @dev Must run directly after the failed call, while its return data is still available
    function _logFailure(address recipient, uint256 amount) private {
        uint256 size;
        assembly ("memory-safe") {
            size := returndatasize()
        }
        if (size > MAX_REASON_BYTES) size = MAX_REASON_BYTES;
        bytes memory reason = new bytes(size);
        assembly ("memory-safe") {
            returndatacopy(add(reason, 0x20), 0, size)
        }
        emit RecipientFailed(recipient, amount, reason);
    }

    /// @dev Pays the fee on what was delivered and refunds the rest of msg.value, excess included
    function _settleETH(uint256 delivered, uint256 deliveredCount) private {
        require(delivered > 0, "All transfers failed");

        uint256 feeAmount = _feeOn(delivered);
        if (feeAmount > 0) {
            (bool feeSuccess,) = payable(feeRecipient).call{value: feeAmount}("");
            require(feeSuccess, "Fee transfer failed");
        }

        uint256 refund = msg.value - delivered - feeAmount;
        if (refund > 0) {
            (bool refundSuccess,) = payable(msg.sender).call{value: refund}("");
            require(refundSuccess, "Refund failed");
        }

        emit SprayETHExecuted(msg.sender, delivered, deliveredCount, feeAmount, block.timestamp);
    }

    /// @dev Pays the fee on what was delivered and refunds the rest of the pulled amount
    function _settleToken(address token, uint256 requiredAmount, uint256 delivered, uint256 deliveredCount) private {
        require(delivered > 0, "All transfers failed");

        uint256 feeAmount = _feeOn(delivered);
        if (feeAmount > 0) {
            IERC20(token).safeTransfer(feeRecipient, feeAmount);
        }

        uint256 refund = requiredAmount - delivered - feeAmount;
        if (refund > 0) {
            IERC20(token).safeTransfer(msg.sender, refund);
        }

        emit SprayTokenExecuted(msg.sender, token, delivered, deliveredCount, feeAmount, block.timestamp);
    }
}
