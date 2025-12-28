// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Id, MarketParams} from "../interfaces/IMorpho.sol";

/// @title EventsLib
/// @author Morpho Labs
/// @custom:contact security@morpho.org
/// @notice Library exposing events.
library EventsLib {
    /// @notice Emitted when setting a new owner.
    /// @param newOwner The new owner of the contract.
    event SetOwner(address indexed newOwner);

    /// @notice Emitted when setting a new fee.
    /// @param id The market id.
    /// @param newFee The new fee.
    event SetFee(Id indexed id, uint256 newFee);

    /// @notice Emitted when setting a new fee recipient.
    /// @param newFeeRecipient The new fee recipient.
    event SetFeeRecipient(address indexed newFeeRecipient);

    /// @notice Emitted when enabling a swap rate model.
    /// @param swapRateModel The swap rate model that was enabled.
    event EnableSwapRateModel(address indexed swapRateModel);

    /// @notice Emitted when creating a market.
    /// @param id The market id.
    /// @param marketParams The market that was created.
    event CreateMarket(Id indexed id, MarketParams marketParams);

    /// @notice Emitted on supply of assets.
    /// @dev Warning: `feeRecipient` receives some shares during interest accrual without any supply event emitted.
    /// @param id The market id.
    /// @param caller The caller.
    /// @param onBehalf The owner of the modified position.
    /// @param assetsA The amount of assetA supplied.
    /// @param assetsB The amount of assetB supplied.
    /// @param shares The amount of shares minted.
    event Supply(Id indexed id, address indexed caller, address indexed onBehalf, uint256 assetsA, uint256 assetsB, uint256 shares);

    /// @notice Emitted on withdrawal of assets.
    /// @param id The market id.
    /// @param caller The caller.
    /// @param onBehalf The owner of the modified position.
    /// @param receiver The address that received the withdrawn assets.
    /// @param assetsA The amount of assetA withdrawn.
    /// @param assetsB The amount of assetB withdrawn.
    /// @param shares The amount of shares burned.
    event Withdraw(
        Id indexed id,
        address caller,
        address indexed onBehalf,
        address indexed receiver,
        uint256 assetsA,
        uint256 assetsB,
        uint256 shares
    );

    /// @notice Emitted on flash loan.
    /// @param caller The caller.
    /// @param token The token that was flash loaned.
    /// @param assets The amount that was flash loaned.
    event FlashLoan(address indexed caller, address indexed token, uint256 assets);

    /// @notice Emitted when setting an authorization.
    /// @param caller The caller.
    /// @param authorizer The authorizer address.
    /// @param authorized The authorized address.
    /// @param newIsAuthorized The new authorization status.
    event SetAuthorization(
        address indexed caller, address indexed authorizer, address indexed authorized, bool newIsAuthorized
    );

    /// @notice Emitted when setting an authorization with a signature.
    /// @param caller The caller.
    /// @param authorizer The authorizer address.
    /// @param usedNonce The nonce that was used.
    event IncrementNonce(address indexed caller, address indexed authorizer, uint256 usedNonce);

    /// @notice Emitted on an exact swap in operation.
    /// @param id The market id.
    /// @param caller The caller.
    /// @param receiver The receiver of the output asset.
    /// @param amountIn The amount of assetA swapped in.
    /// @param amountOut The amount of assetB received.
    event ExactSwapIn(Id indexed id, address indexed caller, address indexed receiver, uint256 amountIn, uint256 amountOut);

    /// @notice Emitted on an exact swap out operation.
    /// @param id The market id.
    /// @param caller The caller.
    /// @param receiver The receiver of the output asset.
    /// @param amountIn The amount of assetB swapped in.
    /// @param amountOut The amount of assetA received.
    event ExactSwapOut(Id indexed id, address indexed caller, address indexed receiver, uint256 amountIn, uint256 amountOut);

    /// @notice Emitted when a swap would result in unhealthy liquidity ratio.
    /// @param id The market id.
    /// @param totalSupplyAssetsA The total supply of assetA after the failed swap.
    /// @param totalSupplyAssetsB The total supply of assetB after the failed swap.
    /// @param price The market price.
    event LiquidityUnhealthy(Id indexed id, uint256 totalSupplyAssetsA, uint256 totalSupplyAssetsB, uint256 price);
}
