// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ISwapRateModel} from "../interfaces/ISwapRateModel.sol";
import {MarketParams, Market} from "../interfaces/IMorpho.sol";
import {MathLib, WAD} from "../libraries/MathLib.sol";

/// @title SwapRateModelMock
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Simple constant product (x*y=k) swap rate model mock for testing.
contract SwapRateModelMock is ISwapRateModel {
    using MathLib for uint256;

    /// @notice Fee parameter (in WAD, e.g., 0.003e18 for 0.3% fee).
    uint256 public immutable fee;

    constructor(uint256 _fee) {
        fee = _fee;
    }

    /// @inheritdoc ISwapRateModel
    function swapRateIn(MarketParams memory, Market memory market, uint256 amountIn)
        external
        view
        returns (uint256)
    {
        return _calculateSwapRateIn(market.totalSupplyAssetsA, market.totalSupplyAssetsB, amountIn);
    }

    /// @inheritdoc ISwapRateModel
    function swapRateInView(MarketParams memory, Market memory market, uint256 amountIn)
        external
        view
        returns (uint256)
    {
        return _calculateSwapRateIn(market.totalSupplyAssetsA, market.totalSupplyAssetsB, amountIn);
    }

    /// @inheritdoc ISwapRateModel
    function swapRateOut(MarketParams memory, Market memory market, uint256 amountOut)
        external
        view
        returns (uint256)
    {
        return _calculateSwapRateOut(market.totalSupplyAssetsB, market.totalSupplyAssetsA, amountOut);
    }

    /// @inheritdoc ISwapRateModel
    function swapRateOutView(MarketParams memory, Market memory market, uint256 amountOut)
        external
        view
        returns (uint256)
    {
        return _calculateSwapRateOut(market.totalSupplyAssetsB, market.totalSupplyAssetsA, amountOut);
    }

    /// @dev Calculates the swap rate for swapping assetA to assetB using constant product formula.
    /// @param reserveIn The reserve of the input asset (assetA).
    /// @param reserveOut The reserve of the output asset (assetB).
    /// @param amountIn The amount of input asset.
    /// @return The amount of output asset (scaled to represent rate).
    function _calculateSwapRateIn(uint256 reserveIn, uint256 reserveOut, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        if (reserveIn == 0 || reserveOut == 0 || amountIn == 0) return 0;

        // Apply fee: amountInWithFee = amountIn * (1 - fee)
        uint256 amountInWithFee = amountIn.wMulDown(WAD - fee);

        // Constant product formula: amountOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee)
        uint256 amountOut = (reserveOut * amountInWithFee) / (reserveIn + amountInWithFee);

        // Return as rate: amountOut / amountIn (scaled by WAD)
        return amountOut.wDivDown(amountIn);
    }

    /// @dev Calculates the swap rate for swapping assetB to assetA to get exact amountOut.
    /// @param reserveIn The reserve of the input asset (assetB).
    /// @param reserveOut The reserve of the output asset (assetA).
    /// @param amountOut The desired amount of output asset.
    /// @return The required amount of input asset (scaled to represent rate).
    function _calculateSwapRateOut(uint256 reserveIn, uint256 reserveOut, uint256 amountOut)
        internal
        view
        returns (uint256)
    {
        if (reserveIn == 0 || reserveOut == 0 || amountOut == 0) return 0;
        require(amountOut < reserveOut, "insufficient liquidity");

        // Constant product formula (reverse): amountIn = (reserveIn * amountOut) / (reserveOut - amountOut)
        uint256 amountInBeforeFee = (reserveIn * amountOut) / (reserveOut - amountOut);

        // Apply fee: amountIn = amountInBeforeFee / (1 - fee)
        uint256 amountIn = amountInBeforeFee.wDivUp(WAD - fee);

        // Return as rate: amountIn / amountOut (scaled by WAD)
        return amountIn.wDivUp(amountOut);
    }

    /// @inheritdoc ISwapRateModel
    function isHealthy(MarketParams memory marketParams, Market memory market) external view returns (bool) {
        uint256 totalSupplyAssetsA = market.totalSupplyAssetsA;
        uint256 totalSupplyAssetsB = market.totalSupplyAssetsB;
        
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

    /// @inheritdoc ISwapRateModel
    function updatePrice(MarketParams memory, Market memory, uint256, uint256, bool) external {
        // This mock implementation doesn't need to update anything
        // Real implementations can use this to update oracles or internal state
    }
}
