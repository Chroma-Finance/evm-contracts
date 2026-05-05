// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title FeeManager
 * @notice Centralized fee collection and distribution for the Chroma Finance protocol.
 *
 *         Vaults forward fees here by calling {collectFees} (pull model: vault must
 *         approve FeeManager before calling). Accumulated fees are split between the
 *         treasury and developer fund via {distributeFees}.
 *
 *         Fee split defaults:
 *         - Treasury: 70% (protocol reserve, governance-controlled)
 *         - Dev fund:  30% (team, audits, infrastructure)
 *
 *         TODO: Update PortfolioVault to use the pull model (approve + collectFees)
 *               instead of the current direct safeTransfer to feeRecipient.
 */
contract FeeManager is Ownable {
    using SafeERC20 for IERC20;

    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ─── State ───────────────────────────────────────────────────────────────

    /// @notice Protocol treasury address (governance multisig or DAO).
    address public treasury;

    /// @notice Developer fund address (team multisig).
    address public devFund;

    /// @notice Treasury share of distributed fees in basis points (default 70%).
    uint256 public treasurySplit = 7_000;

    /// @notice Dev fund share of distributed fees in basis points (default 30%).
    uint256 public devSplit = 3_000;

    /// @notice Fees collected per token but not yet distributed.
    mapping(address => uint256) public collectedFees;

    // ─── Events ──────────────────────────────────────────────────────────────

    event FeesCollected(address indexed token, address indexed vault, uint256 amount);
    event FeesDistributed(
        address indexed token,
        uint256 treasuryAmount,
        uint256 devAmount
    );
    event RecipientsUpdated(address indexed treasury, address indexed devFund);
    event SplitUpdated(uint256 treasurySplit, uint256 devSplit);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error InvalidSplit();
    error NothingToDistribute();

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @param treasury_ Protocol treasury address.
     * @param devFund_  Developer fund address.
     */
    constructor(address treasury_, address devFund_) Ownable(msg.sender) {
        if (treasury_ == address(0) || devFund_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        devFund  = devFund_;
    }

    // ─── External ────────────────────────────────────────────────────────────

    /**
     * @notice Pulls `amount` of `token` from the caller (vault) and records it as collected.
     * @dev The calling vault must call `IERC20(token).approve(address(feeManager), amount)`
     *      before invoking this function.
     * @param token  The fee token (typically the vault's denomination asset).
     * @param amount The fee amount to collect.
     */
    function collectFees(address token, uint256 amount) external {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        collectedFees[token] += amount;

        emit FeesCollected(token, msg.sender, amount);
    }

    /**
     * @notice Distributes all collected fees of `token` to treasury and dev fund per the
     *         configured split.
     * @dev Anyone may call this (permissionless distribution).
     * @param token The token whose accumulated fees to distribute.
     */
    function distributeFees(address token) external {
        uint256 total = collectedFees[token];
        if (total == 0) revert NothingToDistribute();

        collectedFees[token] = 0;

        uint256 treasuryAmount = (total * treasurySplit) / BPS_DENOMINATOR;
        uint256 devAmount      = total - treasuryAmount; // remainder avoids rounding dust

        if (treasuryAmount > 0) IERC20(token).safeTransfer(treasury, treasuryAmount);
        if (devAmount      > 0) IERC20(token).safeTransfer(devFund,  devAmount);

        emit FeesDistributed(token, treasuryAmount, devAmount);
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    /**
     * @notice Updates the treasury and dev fund recipient addresses.
     * @param treasury_ New treasury address.
     * @param devFund_  New dev fund address.
     */
    function setRecipients(address treasury_, address devFund_) external onlyOwner {
        if (treasury_ == address(0) || devFund_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        devFund  = devFund_;
        emit RecipientsUpdated(treasury_, devFund_);
    }

    /**
     * @notice Updates the fee split between treasury and dev fund.
     * @dev The two splits must sum to exactly {BPS_DENOMINATOR} (10 000).
     * @param treasurySplit_ Treasury share in basis points.
     * @param devSplit_      Dev fund share in basis points.
     */
    function setFeeSplit(uint256 treasurySplit_, uint256 devSplit_) external onlyOwner {
        if (treasurySplit_ + devSplit_ != BPS_DENOMINATOR) revert InvalidSplit();
        treasurySplit = treasurySplit_;
        devSplit      = devSplit_;
        emit SplitUpdated(treasurySplit_, devSplit_);
    }
}
