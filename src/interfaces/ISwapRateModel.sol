// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {MarketParams, Market} from "./IMorpho.sol";

/// @title ISwapRateModel
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Interface that Swap Rate Models (SRMs) used by Morpho must implement.
interface ISwapRateModel {
    /// @notice Returns the swap rate for swapping assetA to assetB (scaled by WAD).
    /// @dev The swap rate represents how much assetB you get per unit of assetA.
    /// @dev Assumes that `market` corresponds to `marketParams`.
    /// @param marketParams The market parameters.
    /// @param market The market state.
    /// @param amountIn The amount of assetA to swap in.
    /// @return The swap rate (WAD scaled).
    function swapRateIn(MarketParams memory marketParams, Market memory market, uint256 amountIn) external returns (uint256);

    /// @notice Returns the swap rate for swapping assetA to assetB without modifying any storage.
    /// @dev The swap rate represents how much assetB you get per unit of assetA.
    /// @dev Assumes that `market` corresponds to `marketParams`.
    /// @param marketParams The market parameters.
    /// @param market The market state.
    /// @param amountIn The amount of assetA to swap in.
    /// @return The swap rate (WAD scaled).
    function swapRateInView(MarketParams memory marketParams, Market memory market, uint256 amountIn) external view returns (uint256);

    /// @notice Returns the swap rate for swapping assetB to assetA (scaled by WAD).
    /// @dev The swap rate represents how much assetA you get per unit of assetB.
    /// @dev Assumes that `market` corresponds to `marketParams`.
    /// @param marketParams The market parameters.
    /// @param market The market state.
    /// @param amountOut The desired amount of assetA to receive.
    /// @return The swap rate (WAD scaled).
    function swapRateOut(MarketParams memory marketParams, Market memory market, uint256 amountOut) external returns (uint256);

    /// @notice Returns the swap rate for swapping assetB to assetA without modifying any storage.
    /// @dev The swap rate represents how much assetA you get per unit of assetB.
    /// @dev Assumes that `market` corresponds to `marketParams`.
    /// @param marketParams The market parameters.
    /// @param market The market state.
    /// @param amountOut The desired amount of assetA to receive.
    /// @return The swap rate (WAD scaled).
    function swapRateOutView(MarketParams memory marketParams, Market memory market, uint256 amountOut) external view returns (uint256);

    /// @notice Returns whether the liquidity ratio in the given market is healthy.
    /// @dev Checks if the market's asset ratio is within acceptable bounds.
    /// @dev Assumes that `market` corresponds to `marketParams`.
    /// @param marketParams The market parameters.
    /// @param market The market state.
    /// @return True if the market is healthy, false otherwise.
    function isHealthy(MarketParams memory marketParams, Market memory market) external view returns (bool);

    /// @notice Updates the price after a swap.
    /// @dev Called by Morpho after each swap to allow the model to update internal state.
    /// @param marketParams The market parameters.
    /// @param market The market state.
    /// @param amountIn The amount swapped in.
    /// @param amountOut The amount swapped out.
    /// @param isSwapIn True if this was a swapIn (A->B), false if swapOut (B->A).
    function updatePrice(MarketParams memory marketParams, Market memory market, uint256 amountIn, uint256 amountOut, bool isSwapIn) external;
}
