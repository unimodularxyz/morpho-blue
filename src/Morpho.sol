// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

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

import {MAX_FEE, DOMAIN_TYPEHASH, AUTHORIZATION_TYPEHASH} from "./libraries/ConstantsLib.sol";
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

        // Calculate shares based on the minimum ratio of assets supplied
        if (shares == 0) {
            if (market[id].totalSupplyShares == 0) {
                // First deposit: calculate total value in terms of assetB
                // price is assetA in terms of assetB (WAD scaled)
                // totalValue = assetsB + (assetsA * price / WAD)
                uint256 valueFromA = assetsA.wMulDown(marketParams.price);
                shares = assetsB + valueFromA;
            } else {
                // Calculate the ratio of each asset being supplied relative to market reserves
                uint256 ratioA = (assetsA * WAD) / market[id].totalSupplyAssetsA;
                uint256 ratioB = (assetsB * WAD) / market[id].totalSupplyAssetsB;
                
                // Take the minimum ratio to ensure proportional deposit
                uint256 minRatio = ratioA < ratioB ? ratioA : ratioB;
                
                // Adjust assets to match the minimum ratio (only supply what maintains proportion)
                assetsA = (market[id].totalSupplyAssetsA * minRatio) / WAD;
                assetsB = (market[id].totalSupplyAssetsB * minRatio) / WAD;
                
                // Calculate shares based on the minimum ratio
                shares = (market[id].totalSupplyShares * minRatio) / WAD;
            }
        } else {
            // If shares specified, calculate proportional assets required
            assetsA = (shares * market[id].totalSupplyAssetsA) / market[id].totalSupplyShares;
            assetsB = (shares * market[id].totalSupplyAssetsB) / market[id].totalSupplyShares;
        }

        // Apply mint fee: reduce shares minted to user
        uint256 feeShares = shares.wMulDown(market[id].fee);
        uint256 userShares = shares - feeShares;

        position[id][onBehalf].supplyShares += userShares;
        market[id].totalSupplyShares += shares.toUint128();
        market[id].totalSupplyAssetsA += assetsA.toUint128();
        market[id].totalSupplyAssetsB += assetsB.toUint128();
        
        // Allocate fee shares to fee recipient
        if (feeShares > 0 && feeRecipient != address(0)) {
            position[id][feeRecipient].supplyShares += feeShares;
        }

        emit EventsLib.Supply(id, msg.sender, onBehalf, assetsA, assetsB, userShares);

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
            // Withdraw proportional amounts from each asset based on share percentage
            assetsA = (shares * market[id].totalSupplyAssetsA) / market[id].totalSupplyShares;
            assetsB = (shares * market[id].totalSupplyAssetsB) / market[id].totalSupplyShares;
        } else {
            // If assets specified, calculate shares needed for the withdrawal
            // Use the maximum ratio to ensure we have enough shares
            uint256 ratioA = market[id].totalSupplyAssetsA > 0 
                ? (assetsA * market[id].totalSupplyShares) / market[id].totalSupplyAssetsA 
                : 0;
            uint256 ratioB = market[id].totalSupplyAssetsB > 0 
                ? (assetsB * market[id].totalSupplyShares) / market[id].totalSupplyAssetsB 
                : 0;
            shares = ratioA > ratioB ? ratioA : ratioB;
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
        // SwapRateModel includes fees in the rate calculation
        amountOut = amountIn.wMulDown(swapRate);
        
        require(amountOut >= minAmountOut, ErrorsLib.SLIPPAGE_EXCEEDED);
        require(amountOut <= market[id].totalSupplyAssetsB, ErrorsLib.INSUFFICIENT_LIQUIDITY);

        // Update market balances
        market[id].totalSupplyAssetsA += amountIn.toUint128();
        market[id].totalSupplyAssetsB -= amountOut.toUint128();

        // Check liquidity health after swap
        if (marketParams.swapRateModel != address(0)) {
            if (!ISwapRateModel(marketParams.swapRateModel).isHealthy(marketParams, market[id])) {
                emit EventsLib.LiquidityUnhealthy(id, market[id].totalSupplyAssetsA, market[id].totalSupplyAssetsB, marketParams.price);
                revert(ErrorsLib.LIQUIDITY_UNHEALTHY);
            }
        }

        emit EventsLib.ExactSwapIn(id, msg.sender, receiver, amountIn, amountOut);

        // Transfer tokens
        IERC20(marketParams.assetA).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(marketParams.assetB).safeTransfer(receiver, amountOut);

        // Update price in swap rate model if available (non-critical, don't revert swap if it fails)
        if (marketParams.swapRateModel != address(0)) {
            try ISwapRateModel(marketParams.swapRateModel).updatePrice(marketParams, market[id], amountIn, amountOut, true) {}
            catch {}
        }

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
        
        // Calculate input amount: amountIn = amountOut * swapRate / WAD
        // SwapRateModel includes fees in the rate calculation
        amountIn = amountOut.wMulDown(swapRate);
        if (amountIn * WAD < amountOut * swapRate) amountIn += 1; // Round up
        
        require(amountIn <= maxAmountIn, ErrorsLib.SLIPPAGE_EXCEEDED);

        // Update market balances
        market[id].totalSupplyAssetsB += amountIn.toUint128();
        market[id].totalSupplyAssetsA -= amountOut.toUint128();

        // Check liquidity health after swap
        if (marketParams.swapRateModel != address(0)) {
            if (!ISwapRateModel(marketParams.swapRateModel).isHealthy(marketParams, market[id])) {
                emit EventsLib.LiquidityUnhealthy(id, market[id].totalSupplyAssetsA, market[id].totalSupplyAssetsB, marketParams.price);
                revert(ErrorsLib.LIQUIDITY_UNHEALTHY);
            }
        }

        emit EventsLib.ExactSwapOut(id, msg.sender, receiver, amountIn, amountOut);

        // Transfer tokens
        IERC20(marketParams.assetB).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(marketParams.assetA).safeTransfer(receiver, amountOut);

        // Update price in swap rate model if available (non-critical, don't revert swap if it fails)
        if (marketParams.swapRateModel != address(0)) {
            try ISwapRateModel(marketParams.swapRateModel).updatePrice(marketParams, market[id], amountIn, amountOut, false) {}
            catch {}
        }

        return amountIn;
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

    /* STORAGE VIEW */

    /// @inheritdoc IMorphoBase
    function isHealthy(MarketParams memory marketParams) external view returns (bool) {
        Id id = marketParams.id();
        require(market[id].lastUpdate != 0, ErrorsLib.MARKET_NOT_CREATED);
        
        // Delegate to swap rate model for health check
        if (marketParams.swapRateModel != address(0)) {
            return ISwapRateModel(marketParams.swapRateModel).isHealthy(marketParams, market[id]);
        }
        
        // If no swap rate model, consider healthy by default
        return true;
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
