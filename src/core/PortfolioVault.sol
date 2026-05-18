// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IGuardian} from "../interfaces/IGuardian.sol";
import {IEventNotifier} from "../interfaces/IEventNotifier.sol";
import {IChromaSwapRouter} from "../interfaces/ISwapRouter.sol";

/**
 * @title PortfolioVault
 * @notice Single-user personal vault deployed as an EIP-1167 minimal proxy.
 *
 *         Design principles:
 *         - One vault per user per risk tier.
 *         - Only the vault owner can deposit or withdraw.
 *         - All configuration is set immutably at initialization — no setters.
 *         - Ownership can only change via the registered social recovery module.
 *         - Shares are priced in USD (8 dec, via Chainlink) with no denomination asset.
 *         - Token validation (deposit whitelist) lives in the SwapRouter.
 */
contract PortfolioVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // ─── ERC-20 storage ──────────────────────────────────────────────────────

    string private _name;
    string private _symbol;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    // ─── Portfolio state ─────────────────────────────────────────────────────

    struct Asset {
        address token;
        uint256 targetWeight; // basis points; sum must equal 10 000
    }

    uint8   public riskTier;
    address public vaultOwner;
    address public guardianModule;
    address public recoveryModule;
    address public eventNotifier;
    address public swapRouter;

    /// @notice Chainlink price feed per portfolio token.
    mapping(address => address) public priceFeeds;

    /// @notice Target allocation of the portfolio.
    Asset[] public portfolio;

    // ─── Constants ───────────────────────────────────────────────────────────

    uint256 public constant MANAGEMENT_FEE_BPS        = 0;
    uint256 public constant BPS_DENOMINATOR            = 10_000;
    uint256 public constant SECONDS_PER_YEAR           = 365 days;
    uint8   public constant PRICE_DECIMALS             = 8;
    uint256 public constant PRICE_STALENESS_THRESHOLD  = 1 hours;
    uint256 public constant BOOST_FEE_BPS              = 1_500;

    address public feeRecipient;
    uint256 public lastFeeAccrual;

    // ─── Init guard ──────────────────────────────────────────────────────────

    bool private _initialized;

    // ─── Events ──────────────────────────────────────────────────────────────

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    event Deposit(address indexed owner, address indexed inputToken, uint256 amount, uint256 shares);
    event Withdraw(address indexed owner, address indexed outputToken, uint256 shares, uint256 usdValue);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GuardianAddressUpdated(address indexed newGuardian);

    // ─── Errors ──────────────────────────────────────────────────────────────

    error AlreadyInitialized();
    error Unauthorized();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidWeights();
    error ExceedsMax();
    error GuardianApprovalRequired();
    error InsufficientAllowance();
    error NoPriceFeed(address token);
    error InvalidPrice(address token);
    error StalePriceFeed(address token);
    error SwapRouterRequired();
    error OwnershipTransferBlocked();

    // ─── Modifier ────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != vaultOwner) revert Unauthorized();
        _;
    }

    // ─── Initializer ─────────────────────────────────────────────────────────

    /**
     * @notice Initialises the vault. Called once by VaultFactory immediately after cloning.
     * @dev All parameters are immutable after initialization — no setters exist.
     * @param owner_          Vault owner (the user who called createVault).
     * @param tier_           Risk tier index.
     * @param feeRecipient_   Address that receives management fee shares.
     * @param eventNotifier_  Centralized event emitter.
     * @param guardianModule_ Shared guardian module (address(0) to disable).
     * @param recoveryModule_ Social recovery module (address(0) to disable).
     * @param swapRouter_     Swap router for deposit/withdraw token conversions.
     * @param tokens_         Portfolio token addresses.
     * @param weights_        Allocation weights in basis points (must sum to 10 000).
     * @param priceFeeds_     Chainlink feed per portfolio token (address(0) = no feed).
     */
    function initialize(
        address owner_,
        uint8   tier_,
        address feeRecipient_,
        address eventNotifier_,
        address guardianModule_,
        address recoveryModule_,
        address swapRouter_,
        address[] calldata tokens_,
        uint256[] calldata weights_,
        address[] calldata priceFeeds_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (owner_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (tokens_.length == 0 || tokens_.length != weights_.length) revert InvalidWeights();
        if (tokens_.length != priceFeeds_.length) revert InvalidWeights();
        _assertWeightsSum(weights_);

        _initialized    = true;
        vaultOwner      = owner_;
        riskTier        = tier_;
        feeRecipient    = feeRecipient_;
        eventNotifier   = eventNotifier_;
        guardianModule  = guardianModule_;
        recoveryModule  = recoveryModule_;
        swapRouter      = swapRouter_;
        lastFeeAccrual  = block.timestamp;

        string memory tierLabel = tier_ == 0 ? "Low" : tier_ == 1 ? "Medium" : "High";
        _name   = string.concat("Chroma ", tierLabel, " Risk Vault");
        _symbol = string.concat("CV-", tier_ == 0 ? "LOW" : tier_ == 1 ? "MED" : "HIGH");

        for (uint256 i = 0; i < tokens_.length; i++) {
            portfolio.push(Asset({token: tokens_[i], targetWeight: weights_[i]}));
            if (priceFeeds_[i] != address(0)) {
                priceFeeds[tokens_[i]] = priceFeeds_[i];
            }
        }
    }

    // ─── Core: deposit ────────────────────────────────────────────────────────

    /**
     * @notice Deposit any whitelisted token and receive vault shares.
     * @dev Only the vault owner may deposit. Requires a configured swap router.
     *      The SwapRouter validates token eligibility; the vault measures the USD
     *      increase in portfolio value after the swap to determine share issuance.
     * @param inputToken Token to deposit. Must be whitelisted in the SwapRouter.
     * @param amount     Amount of inputToken to transfer.
     * @return shares    Number of vault shares minted to the owner.
     */
    function deposit(address inputToken, uint256 amount)
        external
        nonReentrant
        onlyOwner
        returns (uint256 shares)
    {
        if (amount == 0) revert ZeroAmount();
        if (inputToken == address(0)) revert ZeroAddress();
        if (swapRouter == address(0)) revert SwapRouterRequired();

        _accrueManagementFee();

        uint256 preUsd = totalAssets();

        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), amount);
        _swapToPortfolio(inputToken, amount);

        uint256 postUsd = totalAssets();
        uint256 usdIn   = postUsd > preUsd ? postUsd - preUsd : 0;

        shares = usdIn.mulDiv(_totalSupply + 1, preUsd + 1, Math.Rounding.Floor);

        _mint(msg.sender, shares);
        emit Deposit(msg.sender, inputToken, amount, shares);
        if (eventNotifier != address(0)) {
            IEventNotifier(eventNotifier).emitDeposit(msg.sender, address(this), riskTier, usdIn, shares, postUsd);
        }
    }

    // ─── Core: withdraw ───────────────────────────────────────────────────────

    /**
     * @notice Withdraw by burning shares.
     * @dev Only the vault owner may withdraw. Guardian approval is required when a guardian is set.
     *      - outputToken == address(0): transfer proportional portfolio tokens to owner.
     *      - outputToken != address(0): swap portfolio → outputToken via SwapRouter, transfer to owner.
     * @param outputToken Token to receive, or address(0) for direct portfolio token withdrawal.
     * @param shares      Number of shares to burn.
     * @param deadline    Guardian signature expiry timestamp.
     * @param signature   EIP-712 guardian approval signature (empty bytes if no guardian set).
     * @return usdValue   USD value (8 dec) of the redeemed shares.
     */
    function withdraw(
        address outputToken,
        uint256 shares,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant onlyOwner returns (uint256 usdValue) {
        if (shares == 0) revert ZeroAmount();
        if (shares > _balances[msg.sender]) revert ExceedsMax();

        _accrueManagementFee();

        usdValue = _convertToAssets(shares, Math.Rounding.Floor);

        if (guardianModule != address(0)) {
            bool approved = IGuardian(guardianModule).validateWithdrawal(
                address(this), msg.sender, usdValue, msg.sender, deadline, signature
            );
            if (!approved) revert GuardianApprovalRequired();
        }

        // Transfer before burn so proportion math uses the full supply.
        if (outputToken == address(0)) {
            _withdrawPortfolioTokens(shares, msg.sender);
        } else {
            uint256 received = _swapFromPortfolio(shares, outputToken);
            IERC20(outputToken).safeTransfer(msg.sender, received);
        }

        _burn(msg.sender, shares);
        emit Withdraw(msg.sender, outputToken, shares, usdValue);
        if (eventNotifier != address(0)) {
            IEventNotifier(eventNotifier).emitWithdrawal(
                msg.sender, address(this), riskTier, usdValue, shares, totalAssets()
            );
        }
    }

    // ─── Ownership ────────────────────────────────────────────────────────────

    /**
     * @notice Blocked. Ownership can only change via the social recovery module.
     */
    function transferOwnership(address) external pure {
        revert OwnershipTransferBlocked();
    }

    /**
     * @notice Transfer ownership. Callable only by the registered recovery module.
     */
    function transferOwnershipFromRecovery(address newOwner) external {
        if (msg.sender != recoveryModule) revert Unauthorized();
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(vaultOwner, newOwner);
        vaultOwner = newOwner;
    }

    /**
     * @notice Set or rotate the guardian address registered in the guardian module.
     * @dev Two distinct authorization paths prevent a compromised owner from silently
     *      bypassing the guardian by rotating it away:
     *
     *      - No guardian set yet: only the vault owner may perform initial setup.
     *      - Guardian already set: only the recovery module may change it, meaning
     *        guardian rotation requires a full social recovery vote.
     *
     *      Without this split, the vault owner could call setGuardianAddress() and the
     *      vault contract would be msg.sender in GuardianModule, triggering the
     *      unconditionally-trusted Path 2 and overwriting a live guardian without approval.
     */
    function setGuardianAddress(address newGuardian) external {
        address currentGuardian = IGuardian(guardianModule).guardians(address(this));
        if (currentGuardian == address(0)) {
            if (msg.sender != vaultOwner) revert Unauthorized();
        } else {
            if (msg.sender != recoveryModule) revert Unauthorized();
        }
        IGuardian(guardianModule).setGuardian(address(this), newGuardian, "");
        emit GuardianAddressUpdated(newGuardian);
    }

    /// @notice Returns the current vault owner.
    function owner() external view returns (address) {
        return vaultOwner;
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @notice Total portfolio value in USD with 8 decimals, via Chainlink price feeds.
    function totalAssets() public view returns (uint256) {
        return _calculatePortfolioValue();
    }

    /**
     * @notice Fetches and validates the latest USD price from a Chainlink feed.
     * @param token Portfolio token whose registered feed is queried.
     * @return price USD price with 8 decimals.
     */
    function getTokenPrice(address token) public view returns (uint256 price) {
        address feed = priceFeeds[token];
        if (feed == address(0)) revert NoPriceFeed(token);

        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = AggregatorV3Interface(feed).latestRoundData();

        if (answer <= 0)                                            revert InvalidPrice(token);
        if (updatedAt == 0 || answeredInRound < roundId)           revert StalePriceFeed(token);
        if (block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) revert StalePriceFeed(token);

        price = uint256(answer);
    }

    /**
     * @notice Preview the portfolio tokens the owner would receive on a direct withdrawal.
     * @param owner_ Address to preview for.
     * @return tokens  Addresses of portfolio tokens that would be transferred.
     * @return amounts Corresponding proportional amounts.
     */
    function previewDirectWithdrawal(address owner_)
        external view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        uint256 shares = _balances[owner_];
        if (shares == 0) return (new address[](0), new uint256[](0));

        uint256 supply = _totalSupply;
        uint256 n      = portfolio.length;
        tokens  = new address[](n);
        amounts = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            tokens[i] = portfolio[i].token;
            uint256 bal = IERC20(portfolio[i].token).balanceOf(address(this));
            amounts[i] = bal * shares / supply;
        }
    }

    // ─── Fee logic ────────────────────────────────────────────────────────────

    function accrueManagementFee() external {
        _accrueManagementFee();
    }

    function _accrueManagementFee() internal {
        uint256 elapsed = block.timestamp - lastFeeAccrual;
        if (elapsed == 0 || _totalSupply == 0) return;

        uint256 feeShares = (_totalSupply * MANAGEMENT_FEE_BPS * elapsed)
            / (BPS_DENOMINATOR * SECONDS_PER_YEAR);

        lastFeeAccrual = block.timestamp;

        if (feeShares > 0) {
            _mint(feeRecipient, feeShares);
            if (eventNotifier != address(0)) {
                IEventNotifier(eventNotifier).emitManagementFee(
                    address(this), riskTier, feeShares, totalAssets()
                );
            }
        }
    }

    // ─── ERC-20 ───────────────────────────────────────────────────────────────

    function name()        public view returns (string memory) { return _name; }
    function symbol()      public view returns (string memory) { return _symbol; }
    function decimals()    public pure returns (uint8)         { return 18; }
    function totalSupply() public view returns (uint256)       { return _totalSupply; }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner_, address spender) public view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    // Virtual +1 offsets on both sides prevent inflation attacks and division-by-zero at init.
    function _convertToAssets(uint256 shares_, Math.Rounding rounding) internal view returns (uint256) {
        return shares_.mulDiv(totalAssets() + 1, _totalSupply + 1, rounding);
    }

    function _calculatePortfolioValue() internal view returns (uint256 totalValue) {
        for (uint256 i = 0; i < portfolio.length; i++) {
            address token = portfolio[i].token;
            if (token.code.length == 0) continue;
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance == 0) continue;

            address feed = priceFeeds[token];
            if (feed == address(0)) continue;

            uint256 price    = getTokenPrice(token);
            uint8   tokenDec = IERC20Metadata(token).decimals();
            totalValue += (balance * price) / (10 ** tokenDec);
        }
    }

    function _assertWeightsSum(uint256[] calldata weights_) internal pure {
        uint256 sum;
        for (uint256 i = 0; i < weights_.length; i++) sum += weights_[i];
        if (sum != BPS_DENOMINATOR) revert InvalidWeights();
    }

    /// @dev Splits `amount` of `inputToken` across portfolio weights and calls SwapRouter.
    function _swapToPortfolio(address inputToken, uint256 amount) internal {
        uint256 n = portfolio.length;
        address[] memory tokensOut = new address[](n);
        uint256[] memory amountsIn = new uint256[](n);

        uint256 remaining = amount;
        for (uint256 i = 0; i < n; i++) {
            tokensOut[i] = portfolio[i].token;
            if (i == n - 1) {
                amountsIn[i] = remaining;
            } else {
                uint256 slice = (amount * portfolio[i].targetWeight) / BPS_DENOMINATOR;
                amountsIn[i] = slice;
                remaining   -= slice;
            }
        }

        IERC20(inputToken).forceApprove(swapRouter, amount);
        IChromaSwapRouter(swapRouter).swapToPortfolio(inputToken, tokensOut, amountsIn);
    }

    /// @dev Swaps the proportional share of each portfolio token to `outputToken` via SwapRouter.
    function _swapFromPortfolio(uint256 sharesToRedeem, address outputToken) internal returns (uint256 proceeds) {
        uint256 supply = _totalSupply;
        uint256 n      = portfolio.length;
        address[] memory tokensIn  = new address[](n);
        uint256[] memory amountsIn = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            address token   = portfolio[i].token;
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 amount  = balance * sharesToRedeem / supply;
            tokensIn[i]  = token;
            amountsIn[i] = amount;
            if (amount > 0) {
                IERC20(token).forceApprove(swapRouter, amount);
            }
        }

        proceeds = IChromaSwapRouter(swapRouter).swapToInputToken(tokensIn, amountsIn, outputToken);
    }

    /// @dev Transfers proportional portfolio tokens to `receiver`. Must be called before _burn.
    function _withdrawPortfolioTokens(uint256 shares, address receiver) internal {
        uint256 supply = _totalSupply;
        for (uint256 i = 0; i < portfolio.length; i++) {
            address token   = portfolio[i].token;
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 amount  = balance * shares / supply;
            if (amount > 0) {
                IERC20(token).safeTransfer(receiver, amount);
            }
        }
    }

    function _mint(address to, uint256 amount) internal {
        _totalSupply    += amount;
        _balances[to]   += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        _balances[from] -= amount;
        _totalSupply    -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        _balances[from] -= amount;
        _balances[to]   += amount;
        emit Transfer(from, to, amount);
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _spendAllowance(address owner_, address spender, uint256 amount) internal {
        uint256 current = _allowances[owner_][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance();
        _allowances[owner_][spender] = current - amount;
    }
}
