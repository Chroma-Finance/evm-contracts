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

/**
 * @title PortfolioVault
 * @notice ERC-4626-compatible tokenized portfolio vault deployed as a minimal proxy.
 *
 *         Because Clones cannot call constructors, this contract implements ERC-20 and
 *         ERC-4626 manually via an {initialize} function instead of inheriting from
 *         OpenZeppelin's ERC4626 abstract contract.
 *
 *         Fees:
 *         - Management fee (1% annual): dilutes existing holders by minting shares to feeRecipient.
 *         - Performance fee (20%): charged on withdrawal profit above the high-water mark.
 *
 *         Swap integration (TODO): deposits swap the denomination asset into the portfolio
 *         allocation; withdrawals swap back. Both are no-ops in this v0.1 draft.
 *
 *         totalAssets() returns portfolio USD value via Chainlink feeds so share prices
 *         reflect true portfolio value rather than denomination-asset balance.
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

    // ─── ERC-4626 storage ────────────────────────────────────────────────────

    /// @notice Denomination token used for deposit/withdraw accounting (e.g., USDC).
    address private _asset;

    // ─── Portfolio state ─────────────────────────────────────────────────────

    struct Asset {
        address token;
        uint256 targetWeight; // basis points; sum must equal 10 000
    }

    uint8 public riskTier;
    address public vaultOwner;
    address public guardianModule;
    address public recoveryModule;
    address public eventNotifier;

    /// @notice Chainlink price feed per portfolio token (and optionally the denomination asset).
    mapping(address => address) public priceFeeds;

    /// @notice Target allocation of the portfolio. Actual holdings diverge until swaps are wired in.
    Asset[] public portfolio;

    // ─── Fee state ───────────────────────────────────────────────────────────

    uint256 public constant MANAGEMENT_FEE_BPS = 100;   // 1% per year
    uint256 public constant PERFORMANCE_FEE_BPS = 2_000; // 20% of profit above HWM
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Decimal precision used for all USD oracle values (matches Chainlink standard).
    uint8 public constant PRICE_DECIMALS = 8;
    /// @notice Maximum age of an accepted Chainlink price round.
    uint256 public constant PRICE_STALENESS_THRESHOLD = 1 hours;

    address public feeRecipient;

    /// @notice Share price (assets * 1e18 / totalSupply) at the last performance-fee collection.
    ///         Initialised to 1e18 (1:1 ratio). Only meaningful once oracle is wired.
    uint256 public highWaterMark;

    /// @notice Timestamp of the last management-fee accrual.
    uint256 public lastFeeAccrual;

    // ─── Init guard ──────────────────────────────────────────────────────────

    bool private _initialized;

    // ─── Events ──────────────────────────────────────────────────────────────

    // ERC-20
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ERC-4626
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    // Vault-specific (security events remain here; financial events route through EventNotifier)
    event GuardianModuleSet(address indexed guardian);
    event RecoveryModuleSet(address indexed recovery);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

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

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != vaultOwner) revert Unauthorized();
        _;
    }

    // ─── Initializer ─────────────────────────────────────────────────────────

    /**
     * @notice Initialises the vault. Called once by VaultFactory immediately after cloning.
     * @param owner_          Vault owner.
     * @param tier_           Risk tier (0 = Low, 1 = Medium, 2 = High).
     * @param asset_          Denomination asset for ERC-4626 accounting.
     * @param feeRecipient_   Address that receives management fee shares and performance fees.
     * @param eventNotifier_  EventNotifier contract for centralized financial event emission.
     * @param tokens_         Portfolio token addresses (must match weights_ and priceFeeds_).
     * @param weights_        Allocation weights in basis points; must sum to 10 000.
     * @param priceFeeds_     Chainlink price feed per portfolio token (address(0) = no feed).
     */
    function initialize(
        address owner_,
        uint8 tier_,
        address asset_,
        address feeRecipient_,
        address eventNotifier_,
        address[] calldata tokens_,
        uint256[] calldata weights_,
        address[] calldata priceFeeds_
    ) external {
        if (_initialized) revert AlreadyInitialized();
        if (owner_ == address(0) || asset_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (tokens_.length == 0 || tokens_.length != weights_.length) revert InvalidWeights();
        if (tokens_.length != priceFeeds_.length) revert InvalidWeights();
        _assertWeightsSum(weights_);

        _initialized = true;
        vaultOwner = owner_;
        riskTier = tier_;
        _asset = asset_;
        feeRecipient = feeRecipient_;
        eventNotifier = eventNotifier_;
        lastFeeAccrual = block.timestamp;
        highWaterMark = 0; // set on first withdrawal once USD share price is known

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

    // ─── ERC-4626 ────────────────────────────────────────────────────────────

    /// @notice Denomination token used for all deposit/withdraw operations.
    function asset() public view returns (address) {
        return _asset;
    }

    /// @notice Returns total portfolio value in USD with {PRICE_DECIMALS} (8) decimals.
    /// @dev Used for ERC-4626 share math so shares are priced in USD, not denomination-asset units.
    function totalAssets() public view returns (uint256) {
        return _calculatePortfolioValue();
    }

    /**
     * @notice Fetches and validates the latest USD price from a Chainlink feed.
     * @param token Portfolio token whose registered feed is queried.
     * @return price USD price with {PRICE_DECIMALS} (8) decimals.
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

        if (answer <= 0)                                      revert InvalidPrice(token);
        if (updatedAt == 0 || answeredInRound < roundId)     revert StalePriceFeed(token);
        if (block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) revert StalePriceFeed(token);

        price = uint256(answer);
    }

    function convertToShares(uint256 assets_) public view returns (uint256) {
        return _convertToShares(assets_, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares_) public view returns (uint256) {
        return _convertToAssets(shares_, Math.Rounding.Floor);
    }

    function maxDeposit(address) public pure returns (uint256) { return type(uint256).max; }
    function maxMint(address)   public pure returns (uint256) { return type(uint256).max; }

    function maxWithdraw(address owner_) public view returns (uint256) {
        return convertToAssets(_balances[owner_]);
    }

    function maxRedeem(address owner_) public view returns (uint256) {
        return _balances[owner_];
    }

    function previewDeposit(uint256 assets_) public view returns (uint256) {
        return _convertToShares(assets_, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares_) public view returns (uint256) {
        return _convertToAssets(shares_, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets_) public view returns (uint256) {
        return _convertToShares(assets_, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares_) public view returns (uint256) {
        return _convertToAssets(shares_, Math.Rounding.Floor);
    }

    /**
     * @notice Deposit `assets_` of the denomination token and receive vault shares.
     * @dev ERC-4626 compliant. Enforces receiver == msg.sender for self-custody safety.
     *      TODO: After receiving denomination asset, swap into target portfolio allocation.
     */
    function deposit(uint256 assets_, address receiver) public nonReentrant returns (uint256 shares) {
        if (assets_ == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver != msg.sender) revert Unauthorized();
        if (assets_ > maxDeposit(receiver)) revert ExceedsMax();

        _accrueManagementFee();

        shares = previewDeposit(assets_);
        _executeDeposit(msg.sender, receiver, assets_, shares);

        // TODO: Call SwapRouter to convert `assets_` into portfolio allocation.
    }

    /**
     * @notice Mint exactly `shares_` vault tokens, pulling the required asset amount from caller.
     * @dev TODO: After receiving denomination asset, swap into target portfolio allocation.
     */
    function mint(uint256 shares_, address receiver) public nonReentrant returns (uint256 assets_) {
        if (shares_ == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        _accrueManagementFee();

        assets_ = previewMint(shares_);
        _executeDeposit(msg.sender, receiver, assets_, shares_);

        // TODO: Call SwapRouter to convert `assets_` into portfolio allocation.
    }

    /**
     * @notice Withdraw `assets_` of the denomination token by burning the required shares.
     * @dev ERC-4626 compliant. Enforces receiver == owner == msg.sender for self-custody safety.
     *      Guardian approval required when {guardianModule} is set.
     *      Performance fee is charged on profit above the high-water mark.
     *      TODO: Before transfer, swap portfolio tokens back to denomination asset.
     */
    function withdraw(
        uint256 assets_,
        address receiver,
        address owner_
    ) public nonReentrant returns (uint256 shares) {
        if (assets_ == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver != msg.sender) revert Unauthorized();
        if (owner_ != msg.sender) revert Unauthorized();
        if (assets_ > maxWithdraw(owner_)) revert ExceedsMax();

        _accrueManagementFee();

        // Guardian gate — vault calls the module which verifies and consumes the approval.
        if (guardianModule != address(0)) {
            (bool approved,) = IGuardian(guardianModule).executeWithdrawal(address(this));
            if (!approved) revert GuardianApprovalRequired();
        }

        // TODO: Call SwapRouter to liquidate portfolio tokens into denomination asset.

        uint256 fee = _chargePerformanceFee(assets_);
        shares = previewWithdraw(assets_);
        _executeWithdraw(msg.sender, receiver, owner_, assets_ - fee, shares);
    }

    /**
     * @notice Redeem `shares_` vault tokens for denomination asset.
     * @dev Performance fee is charged on profit above the high-water mark.
     *      TODO: Before transfer, swap portfolio tokens back to denomination asset.
     */
    function redeem(
        uint256 shares_,
        address receiver,
        address owner_
    ) public nonReentrant returns (uint256 assets_) {
        if (shares_ == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (shares_ > maxRedeem(owner_)) revert ExceedsMax();

        _accrueManagementFee();

        if (guardianModule != address(0)) {
            (bool approved,) = IGuardian(guardianModule).executeWithdrawal(address(this));
            if (!approved) revert GuardianApprovalRequired();
        }

        // TODO: Call SwapRouter to liquidate portfolio tokens into denomination asset.

        assets_ = previewRedeem(shares_);
        uint256 fee = _chargePerformanceFee(assets_);
        _executeWithdraw(msg.sender, receiver, owner_, assets_ - fee, shares_);
    }

    /**
     * @notice Convenience function to exit the vault entirely, burning all caller shares.
     * @dev Applies the same guardian gate and performance fee as a normal withdrawal.
     *      TODO: Before transfer, swap portfolio tokens back to denomination asset.
     */
    function withdrawAll() external nonReentrant returns (uint256 assets_) {
        uint256 shares = _balances[msg.sender];
        if (shares == 0) revert ZeroAmount();

        _accrueManagementFee();

        if (guardianModule != address(0)) {
            (bool approved,) = IGuardian(guardianModule).executeWithdrawal(address(this));
            if (!approved) revert GuardianApprovalRequired();
        }

        // TODO: Call SwapRouter to liquidate portfolio tokens into denomination asset.

        assets_ = previewRedeem(shares);
        uint256 fee = _chargePerformanceFee(assets_);
        _executeWithdraw(msg.sender, msg.sender, msg.sender, assets_ - fee, shares);
    }

    // ─── Fee logic ───────────────────────────────────────────────────────────

    /**
     * @notice Accrues the annual management fee by minting dilutive shares to {feeRecipient}.
     * @dev Public so keepers can trigger it; also called internally before every deposit/withdraw.
     *      Fee shares ≈ totalSupply * feeBps * elapsed / (BPS_DENOMINATOR * SECONDS_PER_YEAR).
     *      This is a first-order approximation; exact continuous compounding differs slightly.
     */
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
                IEventNotifier(eventNotifier).emitManagementFee(address(this), riskTier, feeShares, totalAssets());
            }
        }
    }

    /**
     * @notice Charges the performance fee on profit above the high-water mark.
     * @param withdrawAssets Gross withdrawal amount before fee deduction.
     * @return fee           Performance fee amount in denomination asset.
     */
    function _chargePerformanceFee(uint256 withdrawAssets) internal returns (uint256 fee) {
        if (_totalSupply == 0) return 0;

        uint256 currentSharePrice = (totalAssets() * 1e18) / _totalSupply;
        if (highWaterMark == 0) {
            highWaterMark = currentSharePrice;
            return 0;
        }
        if (currentSharePrice <= highWaterMark) return 0;

        uint256 profitPerShare = currentSharePrice - highWaterMark;
        uint256 grossProfit = (withdrawAssets * profitPerShare) / currentSharePrice;
        fee = (grossProfit * PERFORMANCE_FEE_BPS) / BPS_DENOMINATOR;

        if (fee > 0) {
            IERC20(_asset).safeTransfer(feeRecipient, fee);
            highWaterMark = currentSharePrice;
            if (eventNotifier != address(0)) {
                IEventNotifier(eventNotifier).emitPerformanceFee(address(this), riskTier, msg.sender, fee, totalAssets());
            }
        }
    }

    // ─── Module setters ──────────────────────────────────────────────────────

    /**
     * @notice Attaches or detaches a guardian module.
     * @dev Setting address(0) begins a guardian removal; the GuardianModule itself
     *      enforces the 7-day removal delay before actually clearing approval rights.
     */
    function setGuardian(address guardian_) external onlyOwner {
        guardianModule = guardian_;
        emit GuardianModuleSet(guardian_);
    }

    /// @notice Attaches or detaches a social recovery module.
    function setRecovery(address recovery_) external onlyOwner {
        recoveryModule = recovery_;
        emit RecoveryModuleSet(recovery_);
    }

    /**
     * @notice Transfers vault ownership to a new address.
     * @dev Callable by the current owner or by the registered {recoveryModule}.
     */
    function transferOwnership(address newOwner) external {
        if (msg.sender != vaultOwner && msg.sender != recoveryModule) revert Unauthorized();
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(vaultOwner, newOwner);
        vaultOwner = newOwner;
    }

    /// @notice Returns the current vault owner (IVault-compatible alias for {vaultOwner}).
    function owner() external view returns (address) {
        return vaultOwner;
    }

    // ─── ERC-20 implementation ───────────────────────────────────────────────

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

    // ─── Internal helpers ────────────────────────────────────────────────────

    // Virtual offsets (+1) prevent inflation attacks and division-by-zero at initialisation.
    function _convertToShares(uint256 assets_, Math.Rounding rounding) internal view returns (uint256) {
        return assets_.mulDiv(_totalSupply + 1, totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares_, Math.Rounding rounding) internal view returns (uint256) {
        return shares_.mulDiv(totalAssets() + 1, _totalSupply + 1, rounding);
    }

    function _executeDeposit(address caller, address receiver, uint256 assets_, uint256 shares) internal {
        IERC20(_asset).safeTransferFrom(caller, address(this), assets_);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets_, shares);
        if (eventNotifier != address(0)) {
            IEventNotifier(eventNotifier).emitDeposit(caller, address(this), riskTier, assets_, shares, totalAssets());
        }
    }

    function _executeWithdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets_,
        uint256 shares
    ) internal {
        if (caller != owner_) {
            _spendAllowance(owner_, caller, shares);
        }
        _burn(owner_, shares);
        IERC20(_asset).safeTransfer(receiver, assets_);
        emit Withdraw(caller, receiver, owner_, assets_, shares);
        if (eventNotifier != address(0)) {
            IEventNotifier(eventNotifier).emitWithdrawal(caller, address(this), riskTier, assets_, shares, totalAssets());
        }
    }

    function _mint(address to, uint256 amount) internal {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) internal {
        _balances[from] -= amount;
        _totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        _balances[from] -= amount;
        _balances[to] += amount;
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

    function _calculatePortfolioValue() internal view returns (uint256 totalValue) {
        for (uint256 i = 0; i < portfolio.length; i++) {
            address token = portfolio[i].token;
            if (token.code.length == 0) continue;
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance == 0) continue;

            address feed = priceFeeds[token];
            if (feed == address(0)) continue;

            uint256 price = getTokenPrice(token);
            uint8 tokenDec = IERC20Metadata(token).decimals();
            totalValue += (balance * price) / (10 ** tokenDec);
        }

        uint256 denomBalance = IERC20(_asset).balanceOf(address(this));
        if (denomBalance > 0) {
            uint8 denomDec = IERC20Metadata(_asset).decimals();
            address denomFeed = priceFeeds[_asset];
            if (denomFeed != address(0)) {
                totalValue += (denomBalance * getTokenPrice(_asset)) / (10 ** denomDec);
            } else {
                totalValue += _scaleDecimals(denomBalance, denomDec, PRICE_DECIMALS);
            }
        }
    }

    function _scaleDecimals(uint256 amount, uint8 fromDec, uint8 toDec) internal pure returns (uint256) {
        if (toDec >= fromDec) return amount * (10 ** (toDec - fromDec));
        return amount / (10 ** (fromDec - toDec));
    }

    function _assertWeightsSum(uint256[] calldata weights_) internal pure {
        uint256 sum;
        for (uint256 i = 0; i < weights_.length; i++) sum += weights_[i];
        if (sum != BPS_DENOMINATOR) revert InvalidWeights();
    }
}
