// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.19;

import {
    Id,
    IMorphoStaticTyping,
    IMorphoBase,
    MarketParams,
    Position,
    Market,
    Authorization,
    Signature
} from "./interfaces/IMorpho.sol";
import {
    IMorphoSupplyCallback,
    IMorphoFlashLoanCallback
} from "./interfaces/IMorphoCallbacks.sol";
import {ISwapRateModel} from "./interfaces/ISwapRateModel.sol";
import {IERC20} from "./interfaces/IERC20.sol";

import {ORACLE_PRICE_SCALE, MAX_FEE, DOMAIN_TYPEHASH, AUTHORIZATION_TYPEHASH} from "./libraries/ConstantsLib.sol";
import {UtilsLib} from "./libraries/UtilsLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {ErrorsLib} from "./libraries/ErrorsLib.sol";
import {MathLib, WAD} from "./libraries/MathLib.sol";
import {SharesMathLib} from "./libraries/SharesMathLib.sol";
import {MarketParamsLib} from "./libraries/MarketParamsLib.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";

/// @title Morpho
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice The Morpho contract.
contract Morpho is IMorphoStaticTyping {
    using MathLib for uint128;
    using MathLib for uint256;
    using UtilsLib for uint256;
    using SharesMathLib for uint256;
    using SafeTransferLib for IERC20;
    using MarketParamsLib for MarketParams;

    /* IMMUTABLES */

    /// @inheritdoc IMorphoBase
    bytes32 public immutable DOMAIN_SEPARATOR;

    /* STORAGE */

    /// @inheritdoc IMorphoBase
    address public owner;
    /// @inheritdoc IMorphoBase
    address public feeRecipient;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => mapping(address => Position)) public position;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => Market) public market;
    /// @inheritdoc IMorphoBase
    mapping(address => bool) public isSwapRateModelEnabled;
    /// @inheritdoc IMorphoBase
    mapping(address => mapping(address => bool)) public isAuthorized;
    /// @inheritdoc IMorphoBase
    mapping(address => uint256) public nonce;
    /// @inheritdoc IMorphoStaticTyping
    mapping(Id => MarketParams) public idToMarketParams;

    /* CONSTRUCTOR */

    /// @param newOwner The new owner of the contract.
    constructor(address newOwner) {
        require(newOwner != address(0), ErrorsLib.ZERO_ADDRESS);

        DOMAIN_SEPARATOR = keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
        owner = newOwner;

        emit EventsLib.SetOwner(newOwner);
    }

    /* MODIFIERS */

    /// @dev Reverts if the caller is not the owner.
    modifier onlyOwner() {
        require(msg.sender == owner, ErrorsLib.NOT_OWNER);
        _;
    }

    /* ONLY OWNER FUNCTIONS */

    /// @inheritdoc IMorphoBase
    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != owner, ErrorsLib.ALREADY_SET);

        owner = newOwner;

        emit EventsLib.SetOwner(newOwner);
    }

    /// @inheritdoc IMorphoBase
    function enableSwapRateModel(address swapRateModel) external onlyOwner {
        require(!isSwapRateModelEnabled[swapRateModel], ErrorsLib.ALREADY_SET);

        isSwapRateModelEnabled[swapRateModel] = true;

        emit EventsLib.EnableSwapRateModel(swapRateModel);
    }

    /// @inheritdoc IMorphoBase
    function setFee(MarketParams memory marketParams, uint256 newFee) external onlyOwner {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(newFee != market[id].fee, ErrorsLib.ALREADY_SET);
        require(newFee <= MAX_FEE, ErrorsLib.MAX_FEE_EXCEEDED);

        // Safe "unchecked" cast.
        market[id].fee = uint128(newFee);

        emit EventsLib.SetFee(id, newFee);
    }

    /// @inheritdoc IMorphoBase
    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != feeRecipient, ErrorsLib.ALREADY_SET);

        feeRecipient = newFeeRecipient;

        emit EventsLib.SetFeeRecipient(newFeeRecipient);
    }

    /* MARKET CREATION */

    /// @inheritdoc IMorphoBase
    function createMarket(MarketParams memory marketParams) external {
        Id id = marketParams.id();
        require(marketParams.swapRateModel == address(0) || isSwapRateModelEnabled[marketParams.swapRateModel], ErrorsLib.SRM_NOT_ENABLED);
        require(market[id].lastUpdate == 0, ErrorsLib.MARKET_ALREADY_CREATED);

        // Safe "unchecked" cast.
        market[id].lastUpdate = uint128(block.timestamp);
        idToMarketParams[id] = marketParams;

        emit EventsLib.CreateMarket(id, marketParams);

        // Call to initialize the SRM in case it is stateful.
        if (marketParams.swapRateModel != address(0)) {
            ISwapRateModel(marketParams.swapRateModel).swapRateIn(marketParams, market[id], 0);
        }
    }

    /* SUPPLY MANAGEMENT */

    /// @inheritdoc IMorphoBase
    function supply(
        MarketParams memory marketParams,
        uint256 assetsA,
        uint256 assetsB,
        uint256 shares,
        address onBehalf,
        bytes calldata data
    ) external returns (uint256, uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(onBehalf != address(0), ErrorsLib.ZERO_ADDRESS);

        // Enforce proportional deposit based on current market ratio
        if (market[id].totalSupplyAssetsA > 0 && market[id].totalSupplyAssetsB > 0) {
            // Calculate how much of each asset should be supplied based on the ratio
            uint256 requiredAssetsB = (assetsA * market[id].totalSupplyAssetsB) / market[id].totalSupplyAssetsA;
            uint256 requiredAssetsA = (assetsB * market[id].totalSupplyAssetsA) / market[id].totalSupplyAssetsB;
            
            // Take the minimum to ensure we don't exceed what user provided
            if (assetsB > requiredAssetsB) {
                assetsB = requiredAssetsB;
            } else if (assetsA > requiredAssetsA) {
                assetsA = requiredAssetsA;
            }
        }

        // Calculate shares based on total assets value
        // For simplicity, we use assetsA + assetsB as the combined value
        // In a real implementation, you'd want to price these properly
        uint256 totalAssets = assetsA + assetsB;
        uint256 totalMarketAssets = market[id].totalSupplyAssetsA + market[id].totalSupplyAssetsB;
        
        if (shares == 0) {
            if (market[id].totalSupplyShares == 0) {
                shares = totalAssets;
            } else {
                shares = totalAssets.toSharesDown(totalMarketAssets, market[id].totalSupplyShares);
            }
        } else {
            // If shares specified, calculate required assets
            uint256 requiredAssets = shares.toAssetsUp(totalMarketAssets, market[id].totalSupplyShares);
            require(totalAssets >= requiredAssets, ErrorsLib.INCONSISTENT_INPUT);
        }

        position[id][onBehalf].supplyShares += shares;
        market[id].totalSupplyShares += shares.toUint128();
        market[id].totalSupplyAssetsA += assetsA.toUint128();
        market[id].totalSupplyAssetsB += assetsB.toUint128();

        emit EventsLib.Supply(id, msg.sender, onBehalf, assetsA, assetsB, shares);

        if (data.length > 0) IMorphoSupplyCallback(msg.sender).onMorphoSupply(assetsA, assetsB, data);

        IERC20(marketParams.assetA).safeTransferFrom(msg.sender, address(this), assetsA);
        IERC20(marketParams.assetB).safeTransferFrom(msg.sender, address(this), assetsB);

        return (assetsA, assetsB, shares);
    }

    /// @inheritdoc IMorphoBase
    function withdraw(
        MarketParams memory marketParams,
        uint256 assetsA,
        uint256 assetsB,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256, uint256, uint256) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        // No need to verify that onBehalf != address(0) thanks to the following authorization check.
        require(_isSenderAuthorized(onBehalf), ErrorsLib.UNAUTHORIZED);

        // If shares specified, calculate proportional assets
        if (shares > 0) {
            uint256 totalMarketAssets = market[id].totalSupplyAssetsA + market[id].totalSupplyAssetsB;
            uint256 totalAssets = shares.toAssetsDown(totalMarketAssets, market[id].totalSupplyShares);
            
            // Calculate proportional amounts
            assetsA = (totalAssets * market[id].totalSupplyAssetsA) / totalMarketAssets;
            assetsB = (totalAssets * market[id].totalSupplyAssetsB) / totalMarketAssets;
        } else {
            // Calculate shares from assets
            uint256 totalAssets = assetsA + assetsB;
            uint256 totalMarketAssets = market[id].totalSupplyAssetsA + market[id].totalSupplyAssetsB;
            shares = totalAssets.toSharesUp(totalMarketAssets, market[id].totalSupplyShares);
        }

        position[id][onBehalf].supplyShares -= shares;
        market[id].totalSupplyShares -= shares.toUint128();
        market[id].totalSupplyAssetsA -= assetsA.toUint128();
        market[id].totalSupplyAssetsB -= assetsB.toUint128();


        emit EventsLib.Withdraw(id, msg.sender, onBehalf, receiver, assetsA, assetsB, shares);

        IERC20(marketParams.assetA).safeTransfer(receiver, assetsA);
        IERC20(marketParams.assetB).safeTransfer(receiver, assetsB);

        return (assetsA, assetsB, shares);
    }

    /* FLASH LOANS */

    /// @inheritdoc IMorphoBase
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        require(assets != 0, ErrorsLib.ZERO_ASSETS);

        emit EventsLib.FlashLoan(msg.sender, token, assets);

        IERC20(token).safeTransfer(msg.sender, assets);

        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);

        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    /* SWAP FUNCTIONS */

    /// @inheritdoc IMorphoBase
    function exactSwapIn(
        MarketParams memory marketParams,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver
    ) external returns (uint256 amountOut) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        require(amountIn > 0, ErrorsLib.ZERO_ASSETS);

        // Get the swap rate from the swap rate model or use default price
        uint256 swapRate;
        if (marketParams.swapRateModel != address(0)) {
            swapRate = ISwapRateModel(marketParams.swapRateModel).swapRateIn(marketParams, market[id], amountIn);
        } else {
            // For exactSwapIn (assetA -> assetB), use inverse rate: 1/price = WAD^2 / price
            swapRate = (WAD * WAD) / marketParams.price;
        }
        
        // Calculate output amount: amountOut = amountIn * swapRate / WAD
        uint256 amountOutBeforeFee = amountIn.wMulDown(swapRate);
        
        // Apply swap fee: fee stays in the market, increasing reserves
        uint256 feeAmount = amountOutBeforeFee.wMulDown(market[id].fee);
        amountOut = amountOutBeforeFee - feeAmount;
        
        require(amountOut >= minAmountOut, ErrorsLib.SLIPPAGE_EXCEEDED);
        require(amountOutBeforeFee <= market[id].totalSupplyAssetsB, ErrorsLib.INSUFFICIENT_LIQUIDITY);

        // Update market balances - fee stays in assetB reserves
        market[id].totalSupplyAssetsA += amountIn.toUint128();
        market[id].totalSupplyAssetsB -= amountOut.toUint128();
        // Note: feeAmount stays in totalSupplyAssetsB, increasing reserves for suppliers

        // Check liquidity health after swap
        if (!_isHealthy(marketParams, id)) {
            emit EventsLib.LiquidityUnhealthy(id, market[id].totalSupplyAssetsA, market[id].totalSupplyAssetsB, marketParams.price);
            revert(ErrorsLib.LIQUIDITY_UNHEALTHY);
        }

        emit EventsLib.ExactSwapIn(id, msg.sender, receiver, amountIn, amountOut);

        // Transfer tokens
        IERC20(marketParams.assetA).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(marketParams.assetB).safeTransfer(receiver, amountOut);

        return amountOut;
    }

    /// @inheritdoc IMorphoBase
    function exactSwapOut(
        MarketParams memory marketParams,
        uint256 amountOut,
        uint256 maxAmountIn,
        address receiver
    ) external returns (uint256 amountIn) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        require(receiver != address(0), ErrorsLib.ZERO_ADDRESS);
        require(amountOut > 0, ErrorsLib.ZERO_ASSETS);
        require(amountOut <= market[id].totalSupplyAssetsA, ErrorsLib.INSUFFICIENT_LIQUIDITY);

        // Get the swap rate from the swap rate model or use default price
        uint256 swapRate;
        if (marketParams.swapRateModel != address(0)) {
            swapRate = ISwapRateModel(marketParams.swapRateModel).swapRateOut(marketParams, market[id], amountOut);
        } else {
            // For exactSwapOut (assetB -> assetA), use price directly
            swapRate = marketParams.price;
        }
        
        // Calculate input amount before fee: amountIn = amountOut * swapRate / WAD
        uint256 amountInBeforeFee = amountOut.wMulDown(swapRate);
        if (amountInBeforeFee * WAD < amountOut * swapRate) amountInBeforeFee += 1; // Round up
        
        // Apply swap fee: user pays extra, fee stays in the market
        uint256 feeAmount = amountInBeforeFee.wMulDown(market[id].fee);
        amountIn = amountInBeforeFee + feeAmount;
        
        require(amountIn <= maxAmountIn, ErrorsLib.SLIPPAGE_EXCEEDED);

        // Update market balances - fee increases assetB reserves
        market[id].totalSupplyAssetsB += amountIn.toUint128();
        market[id].totalSupplyAssetsA -= amountOut.toUint128();
        // Note: feeAmount is included in amountIn, increasing reserves for suppliers

        // Check liquidity health after swap
        if (!_isHealthy(marketParams, id)) {
            emit EventsLib.LiquidityUnhealthy(id, market[id].totalSupplyAssetsA, market[id].totalSupplyAssetsB, marketParams.price);
            revert(ErrorsLib.LIQUIDITY_UNHEALTHY);
        }

        emit EventsLib.ExactSwapOut(id, msg.sender, receiver, amountIn, amountOut);

        // Transfer tokens
        IERC20(marketParams.assetB).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(marketParams.assetA).safeTransfer(receiver, amountOut);

        return amountIn;
    }

    /*  IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets, data);

        IERC20(token).safeTransferFrom(msg.sender, address(this), assets);
    }

    /* AUTHORIZATION */

    /// @inheritdoc IMorphoBase
    function setAuthorization(address authorized, bool newIsAuthorized) external {
        require(newIsAuthorized != isAuthorized[msg.sender][authorized], ErrorsLib.ALREADY_SET);

        isAuthorized[msg.sender][authorized] = newIsAuthorized;

        emit EventsLib.SetAuthorization(msg.sender, msg.sender, authorized, newIsAuthorized);
    }

    /// @inheritdoc IMorphoBase
    function setAuthorizationWithSig(Authorization memory authorization, Signature calldata signature) external {
        /// Do not check whether authorization is already set because the nonce increment is a desired side effect.
        require(block.timestamp <= authorization.deadline, ErrorsLib.SIGNATURE_EXPIRED);
        require(authorization.nonce == nonce[authorization.authorizer]++, ErrorsLib.INVALID_NONCE);

        bytes32 hashStruct = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", DOMAIN_SEPARATOR, hashStruct));
        address signatory = ecrecover(digest, signature.v, signature.r, signature.s);

        require(signatory != address(0) && authorization.authorizer == signatory, ErrorsLib.INVALID_SIGNATURE);

        emit EventsLib.IncrementNonce(msg.sender, authorization.authorizer, authorization.nonce);

        isAuthorized[authorization.authorizer][authorization.authorized] = authorization.isAuthorized;

        emit EventsLib.SetAuthorization(
            msg.sender, authorization.authorizer, authorization.authorized, authorization.isAuthorized
        );
    }

    /// @dev Returns whether the sender is authorized to manage `onBehalf`'s positions.
    function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
        return msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender];
    }

    /* HEALTH CHECK */

    /// @dev Returns whether the liquidity ratio in the given market is healthy.
    /// @dev Checks if (assetB * price) / assetA is within [0.5, 2] range.
    /// @dev Assumes that the inputs `marketParams` and `id` match.
    function _isHealthy(MarketParams memory marketParams, Id id) internal view returns (bool) {
        uint256 totalSupplyAssetsA = market[id].totalSupplyAssetsA;
        uint256 totalSupplyAssetsB = market[id].totalSupplyAssetsB;
        
        // If either reserve is zero, consider unhealthy
        if (totalSupplyAssetsA == 0 || totalSupplyAssetsB == 0) return false;
        
        // Calculate assetB * price (in WAD)
        uint256 assetBValue = totalSupplyAssetsB.wMulDown(marketParams.price);
        
        // Check if 0.5 <= (assetB * price) / assetA <= 2
        // Equivalent to: 0.5 * assetA <= assetB * price <= 2 * assetA
        uint256 halfAssetA = totalSupplyAssetsA.wMulDown(WAD / 2); // 0.5 * WAD
        uint256 doubleAssetA = totalSupplyAssetsA.wMulDown(2 * WAD); // 2 * WAD
        
        return assetBValue >= halfAssetA && assetBValue <= doubleAssetA;
    }

    /* STORAGE VIEW */

    /// @inheritdoc IMorphoBase
    function isLiqHealthy(MarketParams memory marketParams) external view returns (bool) {
        Id id = marketParams.id();
        return _isHealthy(marketParams, id);
    }

    /// @inheritdoc IMorphoBase
    function extSloads(bytes32[] calldata slots) external view returns (bytes32[] memory res) {
        uint256 nSlots = slots.length;

        res = new bytes32[](nSlots);

        for (uint256 i; i < nSlots;) {
            bytes32 slot = slots[i++];

            assembly ("memory-safe") {
                mstore(add(res, mul(i, 32)), sload(slot))
            }
        }
    }
}
