// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVault} from "fiat/interfaces/IVault.sol";
import {WAD, toInt256, wmul, wdiv, sub} from "fiat/utils/Math.sol";

import {Vault20Actions} from "./Vault20Actions.sol";

interface IFYPool {
    function sellBasePreview(uint128 baseIn) external view returns(uint128);
    function sellBase(address to, uint128 min) external returns(uint128);    
    function sellFYTokenPreview(uint128 fyTokenIn) external view  returns(uint128);
    function sellFYToken(address to, uint128 min) external returns(uint128);
}

interface IFYToken {
    function redeem(address to, uint256 amount) external returns (uint256 redeemed);
}

contract VaultFYActions is Vault20Actions {
    using SafeERC20 for IERC20;

    error VaultFYActions__overflow();
    error VaultFYActions__buyCollateralAndModifyDebt_zeroUnderlierAmount();
    error VaultFYActions__sellCollateralAndModifyDebt_zeroFYTokenAmount();
    error VaultFYActions__redeemCollateralAndModifyDebt_zeroFYTokenAmount();

    // Yield Space Contracts use uint128 for all amounts
    uint256 public constant MAX = type(uint128).max;

    struct SwapParams {
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
        if (underlierAmount >= MAX) revert VaultFYActions__overflow();
        // buy fyToken according to `swapParams` data and transfer tokens to be used as collateral into VaultFY
        uint128 fyTokenAmount = _buyFYToken(uint128(underlierAmount), collateralizer, swapParams);
        int256 deltaCollateral = toInt256(wdiv(uint256(fyTokenAmount), IVault(vault).tokenScale()));

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
        if (fyTokenAmount >= MAX) revert VaultFYActions__overflow();
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
        _sellFYToken(uint128(fyTokenAmount), collateralizer, swapParams);
    }

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


    function _buyFYToken(uint128 underlierAmount, address from, SwapParams calldata swapParams) internal returns(uint128) {
        address fyPool = swapParams.yieldSpacePool;
        // Todo: Maybe adjust minFYToken to account for slippage
        uint128 minFYToken = IFYPool(fyPool).sellBasePreview(underlierAmount);
        IERC20(swapParams.assetIn).safeTransferFrom(from, fyPool, underlierAmount);
        return IFYPool(fyPool).sellBase(from, minFYToken);
    }

    function _sellFYToken(
        uint128 fyTokenAmount,
        address to,
        SwapParams calldata swapParams
    ) internal returns (uint256) {
        address fyPool = swapParams.yieldSpacePool;
        uint128 minUnderlier = IFYPool(fyPool).sellFYTokenPreview(fyTokenAmount);
        // Transfer from this contract to fypool
        IERC20(swapParams.assetIn).safeTransfer(fyPool, fyTokenAmount);
        return IFYPool(fyPool).sellFYToken(to, minUnderlier);
    }

    /// ======== View Methods ======== ///
    function underlierToFYToken(
        uint256 underlierAmount,
        address yieldSpacePool
    ) external view returns (uint256) {
        if (underlierAmount >= MAX) return 0;
        return uint256(IFYPool(yieldSpacePool).sellBasePreview(uint128(underlierAmount)));
    }

    function fyTokenToUnderlier(
        uint256 fyTokenAmount,
        address yieldSpacePool
    ) external view returns (uint256) {
        if (fyTokenAmount >= MAX) return 0;
        return uint256(IFYPool(yieldSpacePool).sellFYTokenPreview(uint128(fyTokenAmount)));
    }
}

