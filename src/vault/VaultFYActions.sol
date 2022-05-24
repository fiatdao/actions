// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVault} from "fiat/interfaces/IVault.sol";
import {WAD, toInt256, wmul, wdiv, sub} from "fiat/utils/Math.sol";

import {Vault20Actions} from "./Vault20Actions.sol";

interface IFYPool {
    function sellBasePreview(uint128 baseIn) external view returns (uint128);

    function sellBase(address to, uint128 min) external returns (uint128);

    function sellFYTokenPreview(uint128 fyTokenIn) external view returns (uint128);

    function sellFYToken(address to, uint128 min) external returns (uint128);
}

interface IFYToken {
    function redeem(address to, uint256 amount) external returns (uint256 redeemed);
}

/// @title VaultFYActions
/// @notice A set of vault actions for modifying positions collateralized by Yield Protocol Fixed Yield Tokens
contract VaultFYActions is Vault20Actions {
    using SafeERC20 for IERC20;

    /// ======== Custom Errors ======== ///

    error VaultFYActions__buyCollateralAndModifyDebt_overflow();
    error VaultFYActions__buyCollateralAndModifyDebt_zeroUnderlierAmount();
    error VaultFYActions__sellCollateralAndModifyDebt_overflow();
    error VaultFYActions__sellCollateralAndModifyDebt_zeroFYTokenAmount();
    error VaultFYActions__redeemCollateralAndModifyDebt_zeroFYTokenAmount();
    error VaultFYActions__buyFYToken_slippageExceedsMinAmountOut();
    error VaultFYActions__sellFYToken_slippageExceedsMinAmountOut();
    error VaultFYActions__underlierToFYToken__overflow();
    error VaultFYActions__fyTokenToUnderlier__overflow();

    /// ======== Types ======== ///

    // Swap data
    struct SwapParams {
        // Min amount of asset out
        uint256 minAssetOut;
        // Address of the yield space v2 pool
        address yieldSpacePool;
        // Underlier token address when adding collateral and `collateral` when removing
        address assetIn;
        // Collateral token address when adding collateral and `underlier` when removing
        address assetOut;
    }

    constructor(
        address codex_,
        address moneta_,
        address fiat_,
        address publican_
    ) Vault20Actions(codex_, moneta_, fiat_, publican_) {}

    /// ======== Position Management ======== ///

    /// @notice Buys fyTokens from underliers before it modifies a Position's collateral
    /// and debt balances and mints/burns FIAT using the underlier token.
    /// The underlier is swapped to fyTokens and used as collateral.
    /// @dev The user needs to previously approve the UserProxy for spending underlier tokens,
    /// collateral tokens, or FIAT tokens. If `position` is not the UserProxy, the `position` owner
    /// needs grant a delegate to UserProxy via Codex.
    /// @param vault Address of the Vault
    /// @param position Address of the position's owner
    /// @param collateralizer Address of who puts up or receives the collateral delta as underlier tokens
    /// @param creditor Address of who provides or receives the FIAT delta for the debt delta
    /// @param underlierAmount Amount of underlier to swap for fyToken to put up for collateral [underlierScale]
    /// @param deltaNormalDebt Amount of normalized debt (gross, before rate is applied) to generate (+) or
    /// settle (-) on this Position [wad]
    /// @param swapParams Parameters of the underlier to fyToken swap
    function buyCollateralAndModifyDebt(
        address vault,
        address position,
        address collateralizer,
        address creditor,
        uint256 underlierAmount,
        int256 deltaNormalDebt,
        SwapParams calldata swapParams
    ) public {
        if (underlierAmount == 0) revert VaultFYActions__buyCollateralAndModifyDebt_zeroUnderlierAmount();
        // Yield Space Contracts use uint128 for all amounts
        if (underlierAmount >= type(uint128).max) revert VaultFYActions__buyCollateralAndModifyDebt_overflow();
        // buy fyToken according to `swapParams` data and transfer tokens to be used as collateral into VaultFY
        uint256 fyTokenAmount = _buyFYToken(underlierAmount, collateralizer, swapParams);
        int256 deltaCollateral = toInt256(wdiv(fyTokenAmount, IVault(vault).tokenScale()));

        // enter fyToken and collateralize position
        modifyCollateralAndDebt(
            vault,
            swapParams.assetOut,
            0,
            position,
            address(this),
            creditor,
            deltaCollateral,
            deltaNormalDebt
        );
    }

    /// @notice Sells fyTokens for underliers after it modifies a Position's collateral and debt balances
    /// and mints/burns FIAT using the underlier token. fyTokens cannot be sold after maturity, they should be redeemed.
    /// @dev The user needs to previously approve the UserProxy for spending collateral tokens or FIAT tokens
    /// If `position` is not the UserProxy, the `position` owner needs grant a delegate to UserProxy via Codex
    /// @param vault Address of the Vault
    /// @param position Address of the position's owner
    /// @param collateralizer Address of who puts up or receives the collateral delta as underlier tokens
    /// @param creditor Address of who provides or receives the FIAT delta for the debt delta
    /// @param fyTokenAmount Amount of fyToken to remove as collateral and to swap for underlier [tokenScale]
    /// @param deltaNormalDebt Amount of normalized debt (gross, before rate is applied) to generate (+) or
    /// settle (-) on this Position [wad]
    /// @param swapParams Parameters of the underlier to fyToken swap
    function sellCollateralAndModifyDebt(
        address vault,
        address position,
        address collateralizer,
        address creditor,
        uint256 fyTokenAmount,
        int256 deltaNormalDebt,
        SwapParams calldata swapParams
    ) public {
        if (fyTokenAmount == 0) revert VaultFYActions__sellCollateralAndModifyDebt_zeroFYTokenAmount();
        // Yield Space Contracts use uint128 for all amounts
        if (fyTokenAmount >= type(uint128).max) revert VaultFYActions__sellCollateralAndModifyDebt_overflow();
        int256 deltaCollateral = -toInt256(wdiv(fyTokenAmount, IVault(vault).tokenScale()));

        // withdraw fyToken from the position
        modifyCollateralAndDebt(
            vault,
            swapParams.assetIn,
            0,
            position,
            address(this),
            creditor,
            deltaCollateral,
            deltaNormalDebt
        );

        // sell fyToken according to `swapParams`
        _sellFYToken(fyTokenAmount, collateralizer, swapParams);
    }

    /// @notice Redeems fyTokens for underliers after it modifies a Position's collateral
    /// and debt balances and mints/burns FIAT using the underlier token. Fails if fyToken hasn't matured yet.
    /// @dev The user needs to previously approve the UserProxy for spending collateral tokens or FIAT tokens
    /// If `position` is not the UserProxy, the `position` owner needs grant a delegate to UserProxy via Codex
    /// @param vault Address of the Vault
    /// @param token Address of the collateral token (fyToken)
    /// @param position Address of the position's owner
    /// @param collateralizer Address of who puts up or receives the collateral delta as underlier tokens
    /// @param creditor Address of who provides or receives the FIAT delta for the debt delta
    /// @param fyTokenAmount Amount of fyToken to remove as collateral and to swap or redeem for underlier [tokenScale]
    /// @param deltaNormalDebt Amount of normalized debt (gross, before rate is applied) to generate (+) or
    /// settle (-) on this Position [wad]
    function redeemCollateralAndModifyDebt(
        address vault,
        address token,
        address position,
        address collateralizer,
        address creditor,
        uint256 fyTokenAmount,
        int256 deltaNormalDebt
    ) public {
        if (fyTokenAmount == 0) revert VaultFYActions__redeemCollateralAndModifyDebt_zeroFYTokenAmount();

        int256 deltaCollateral = -toInt256(wdiv(fyTokenAmount, IVault(vault).tokenScale()));

        // withdraw fyToken from the position
        modifyCollateralAndDebt(vault, token, 0, position, address(this), creditor, deltaCollateral, deltaNormalDebt);

        // redeem fyToken for underlier
        IFYToken(token).redeem(collateralizer, fyTokenAmount);
    }

    function _buyFYToken(
        uint256 underlierAmount,
        address from,
        SwapParams calldata swapParams
    ) internal returns (uint256) {
        // Asks Yield Math to calculate the expected amount of fyToken received for underlier
        uint128 minFYToken = IFYPool(swapParams.yieldSpacePool).sellBasePreview(uint128(underlierAmount));
        if (swapParams.minAssetOut > minFYToken) revert VaultFYActions__buyFYToken_slippageExceedsMinAmountOut();

        // if `from` is set to an external address then transfer amount to the proxy first
        // requires `from` to have set an allowance for the proxy
        if (from != address(0) && from != address(this)) {
            IERC20(swapParams.assetIn).safeTransferFrom(from, address(this), underlierAmount);
        }

        // Performs transfer of underlier into yieldspace pool
        IERC20(swapParams.assetIn).safeTransfer(swapParams.yieldSpacePool, underlierAmount);
        // Sells underlier for fyToken. fyToken are transferred to the proxy to be entered into a vault
        return uint256(IFYPool(swapParams.yieldSpacePool).sellBase(address(this), minFYToken));
    }

    function _sellFYToken(
        uint256 fyTokenAmount,
        address to,
        SwapParams calldata swapParams
    ) internal returns (uint256) {
        // Asks Yield Math to calculate the expected amount of underlier received for fyToken
        uint128 minUnderlier = IFYPool(swapParams.yieldSpacePool).sellFYTokenPreview(uint128(fyTokenAmount));
        if (swapParams.minAssetOut > minUnderlier) revert VaultFYActions__sellFYToken_slippageExceedsMinAmountOut();
        // Transfer from this contract to fypool
        IERC20(swapParams.assetIn).safeTransfer(swapParams.yieldSpacePool, fyTokenAmount);
        return uint256(IFYPool(swapParams.yieldSpacePool).sellFYToken(to, minUnderlier));
    }

    /// ======== View Methods ======== ///

    /// @notice Returns an amount of fyToken for a given an amount of the underlier token (e.g. USDC)
    /// @param underlierAmount Amount of underlier to be used to by fyToken
    /// @param yieldSpacePool Address of the underlier-fyToken LP
    /// @return Amount of fyToken [tokenScale]
    function underlierToFYToken(uint256 underlierAmount, address yieldSpacePool) external view returns (uint256) {
        if (underlierAmount >= type(uint128).max) revert VaultFYActions__underlierToFYToken__overflow();
        return uint256(IFYPool(yieldSpacePool).sellBasePreview(uint128(underlierAmount)));
    }

    /// @notice Returns an amount of underlier for a given an amount of the fyToken
    /// @param fyTokenAmount Amount of fyToken to be traded for underlier
    /// @param yieldSpacePool Address of the underlier-fyToken LP
    /// @return Amount of underlier expected on trade [underlierScale]
    function fyTokenToUnderlier(uint256 fyTokenAmount, address yieldSpacePool) external view returns (uint256) {
        if (fyTokenAmount >= type(uint128).max) revert VaultFYActions__fyTokenToUnderlier__overflow();
        return uint256(IFYPool(yieldSpacePool).sellFYTokenPreview(uint128(fyTokenAmount)));
    }
}
