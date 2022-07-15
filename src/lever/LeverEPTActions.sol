// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICodex} from "fiat/interfaces/ICodex.sol";
import {IVault} from "fiat/interfaces/IVault.sol";
import {IMoneta} from "fiat/interfaces/IMoneta.sol";
import {IFIAT} from "fiat/interfaces/IFIAT.sol";
import {IFlash, ICreditFlashBorrower, IERC3156FlashBorrower} from "fiat/interfaces/IFlash.sol";
import {IPublican} from "fiat/interfaces/IPublican.sol";
import {WAD, toInt256, add, wmul, wdiv, sub} from "fiat/utils/Math.sol";

import {Lever20Actions} from "./Lever20Actions.sol";
import {IBalancerVault} from "./LeverActions.sol";

interface IConvergentCurvePool {
    function solveTradeInvariant(
        uint256 amountX,
        uint256 reserveX,
        uint256 reserveY,
        bool out
    ) external view returns (uint256);

    function percentFee() external view returns (uint256);

    function totalSupply() external view returns (uint256);
}

interface ITranche {
    function withdrawPrincipal(uint256 _amount, address _destination) external returns (uint256);
}

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// WARNING: These functions meant to be used as a a library for a PRBProxy. Some are unsafe if you call them directly.
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

/// @title LeverEPTActions
/// @notice A set of vault actions for modifying positions collateralized by Element Finance pTokens
contract LeverEPTActions is Lever20Actions, ICreditFlashBorrower, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    /// ======== Custom Errors ======== ///

    error LeverEPTActions__onFlashLoan_unknownSender();
    error LeverEPTActions__onFlashLoan_unknownToken();
    error LeverEPTActions__onFlashLoan_nonZeroFee();
    error LeverEPTActions__onCreditFlashLoan_unknownSender();
    error LeverEPTActions__onCreditFlashLoan_nonZeroFee();
    error LeverEPTActions__solveTradeInvariant_tokenMismatch();

    /// ======== Types ======== ///

    struct PTokenSwapParams {
        // Address of the Balancer Vault
        address balancerVault;
        // Id of the Element Convergent Curve Pool containing the collateral token
        bytes32 poolId;
        // Underlier token address when adding collateral and `collateral` when removing
        address assetIn;
        // Collateral token address when adding collateral and `underlier` when removing
        address assetOut;
        // Min. amount of tokens we would accept to receive from the swap, whether it is collateral or underlier
        uint256 minAmountOut;
        // Timestamp at which swap must be confirmed by [seconds]
        uint256 deadline;
    }

    struct FIATFlashLoanData {
        address vault;
        address token;
        address position;
        uint256 upfrontUnderliers;
        SellFIATSwapParams fiatSwapParams;
        PTokenSwapParams swapParams;
    }

    struct CreditFlashLoanData {
        address vault;
        address token;
        address position;
        address collateralizer;
        uint256 subPTokenAmount;
        BuyFIATSwapParams fiatSwapParams;
        PTokenSwapParams swapParams;
    }

    constructor(
        address codex,
        address fiat,
        address flash,
        address moneta,
        address publican,
        bytes32 fiatPoolId,
        address fiatBalancerVault
    ) Lever20Actions(codex, fiat, flash, moneta, publican, fiatPoolId, fiatBalancerVault) {}

    /// ======== Position Management ======== ///

    /// @notice Increases the leverage factor of a position by flash minting `deltaNormalDebt` amount of FIAT
    /// and selling it on top of the `underlierAmount` the `collateralizer` provided for more pTokens.
    function buyCollateralAndIncreaseLever(
        address vault,
        address position,
        address collateralizer,
        uint256 upfrontUnderliers,
        uint256 addDebt,
        SellFIATSwapParams calldata fiatSwapParams,
        PTokenSwapParams calldata swapParams
    ) public {
        // if `collateralizer` is set to an external address then transfer the amount directly to Action contract
        // requires `collateralizer` to have set an allowance for the proxy
        if (collateralizer == address(this) || collateralizer == address(0)) {
            IERC20(swapParams.assetIn).safeTransfer(address(self), upfrontUnderliers);
        } else {
            IERC20(swapParams.assetIn).safeTransferFrom(collateralizer, address(self), upfrontUnderliers);
        }

        codex.grantDelegate(self);

        bytes memory data = abi.encode(
            FIATFlashLoanData(vault, swapParams.assetOut, position, upfrontUnderliers, fiatSwapParams, swapParams)
        );

        flash.flashLoan(IERC3156FlashBorrower(address(self)), address(fiat), addDebt, data);

        codex.revokeDelegate(self);
    }

    /// @notice `buyCollateralAndIncreaseLever` flash loan callback
    /// @dev Executed in the context of LeverEPTActions instead of the Proxy
    function onFlashLoan(
        address, /* initiator */
        address token,
        uint256 borrowed,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        if (msg.sender != address(flash)) revert LeverEPTActions__onFlashLoan_unknownSender();
        if (token != address(fiat)) revert LeverEPTActions__onFlashLoan_unknownToken();
        if (fee != 0) revert LeverEPTActions__onFlashLoan_nonZeroFee();

        FIATFlashLoanData memory params = abi.decode(data, (FIATFlashLoanData));

        uint256 addCollateral;
        {
            // sell fiat for underlier
            uint256 underlierAmount = _sellFIATExactIn(params.fiatSwapParams, borrowed);

            // sum underlier from sender and underliers from fiat swap
            underlierAmount = add(underlierAmount, params.upfrontUnderliers);

            // sell underlier for collateral token
            uint256 pTokenSwapped = _buyPToken(underlierAmount, params.swapParams);
            addCollateral = wdiv(pTokenSwapped, IVault(params.vault).tokenScale());
        }

        // update position and mint fiat
        addCollateralAndDebt(
            params.vault,
            params.token,
            0,
            params.position,
            address(this),
            address(this),
            addCollateral,
            borrowed
        );

        // payback
        fiat.approve(address(flash), borrowed);

        return CALLBACK_SUCCESS;
    }

    function sellCollateralAndDecreaseLever(
        address vault,
        address position,
        address collateralizer,
        uint256 subPTokenAmount,
        uint256 subNormalDebt,
        BuyFIATSwapParams calldata fiatSwapParams,
        PTokenSwapParams calldata swapParams
    ) public {
        codex.grantDelegate(self);

        bytes memory data = abi.encode(
            CreditFlashLoanData(
                vault,
                swapParams.assetIn,
                position,
                collateralizer,
                subPTokenAmount,
                fiatSwapParams,
                swapParams
            )
        );

        // update the interest rate accumulator in Codex for the vault
        if (subNormalDebt != 0) publican.collect(vault);
        // add due interest from normal debt
        (, uint256 rate, , ) = codex.vaults(vault);
        flash.creditFlashLoan(ICreditFlashBorrower(address(self)), wmul(rate, subNormalDebt), data);

        codex.revokeDelegate(self);
    }

    /// @notice `sellCollateralAndDecreaseLever` flash loan callback
    /// @dev Executed in the context of LeverEPTActions instead of the Proxy
    function onCreditFlashLoan(
        address initiator,
        uint256 borrowed,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        if (msg.sender != address(flash)) revert LeverEPTActions__onCreditFlashLoan_unknownSender();
        if (fee != 0) revert LeverEPTActions__onCreditFlashLoan_nonZeroFee();

        CreditFlashLoanData memory params = abi.decode(data, (CreditFlashLoanData));

        // pay back debt of position
        subCollateralAndDebt(
            params.vault,
            params.token,
            0,
            params.position,
            address(this),
            wdiv(params.subPTokenAmount, IVault(params.vault).tokenScale()),
            borrowed
        );

        // sell collateral for underlier
        uint256 underlierAmount = _sellPToken(params.subPTokenAmount, address(this), params.swapParams);

        // sell part of underlier for FIAT
        uint256 underlierSwapped = _buyFIATExactOut(params.fiatSwapParams, borrowed);

        // send underlier to collateralizer
        IERC20(params.swapParams.assetOut).safeTransfer(
            (params.collateralizer == address(0)) ? initiator : params.collateralizer,
            sub(underlierAmount, underlierSwapped)
        );

        // payback
        fiat.approve(address(moneta), borrowed);
        moneta.enter(address(this), borrowed);
        codex.transferCredit(address(this), address(flash), borrowed);

        return CALLBACK_SUCCESS_CREDIT;
    }

    /// @dev Executed in the context of LeverEPTActions instead of the Proxy
    function _buyPToken(uint256 underlierAmount, PTokenSwapParams memory swapParams) internal returns (uint256) {
        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap(
            swapParams.poolId,
            IBalancerVault.SwapKind.GIVEN_IN,
            swapParams.assetIn,
            swapParams.assetOut,
            underlierAmount,
            new bytes(0)
        );
        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement(
            address(this),
            false,
            payable(address(this)),
            false
        );

        if (IERC20(swapParams.assetIn).allowance(address(this), swapParams.balancerVault) < underlierAmount) {
            IERC20(swapParams.assetIn).approve(swapParams.balancerVault, type(uint256).max);
        }

        return
            IBalancerVault(swapParams.balancerVault).swap(
                singleSwap,
                funds,
                swapParams.minAmountOut,
                swapParams.deadline
            );
    }

    /// @dev Executed in the context of LeverEPTActions instead of the Proxy
    function _sellPToken(
        uint256 pTokenAmount,
        address to,
        PTokenSwapParams memory swapParams
    ) internal returns (uint256) {
        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap(
            swapParams.poolId,
            IBalancerVault.SwapKind.GIVEN_IN,
            swapParams.assetIn,
            swapParams.assetOut,
            pTokenAmount,
            new bytes(0)
        );
        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement(
            address(this),
            false,
            payable(to),
            false
        );

        if (IERC20(swapParams.assetIn).allowance(address(this), swapParams.balancerVault) < pTokenAmount) {
            IERC20(swapParams.assetIn).approve(swapParams.balancerVault, type(uint256).max);
        }

        return
            IBalancerVault(swapParams.balancerVault).swap(
                singleSwap,
                funds,
                swapParams.minAmountOut,
                swapParams.deadline
            );
    }

    /// ======== View Methods ======== ///

    /// @notice Returns an amount of pToken for a given an amount of the pTokens underlier token (e.g. USDC)
    /// @param vault Address of the Vault (FIAT)
    /// @param balancerVault Address of the Balancer V2 vault
    /// @param curvePoolId Id of the ConvergentCurvePool
    /// @param underlierAmount Amount of underlier [underlierScale]
    /// @return Amount of pToken [tokenScale]
    function underlierToPToken(
        address vault,
        address balancerVault,
        bytes32 curvePoolId,
        uint256 underlierAmount
    ) external view returns (uint256) {
        return _solveTradeInvariant(underlierAmount, vault, balancerVault, curvePoolId, true);
    }

    /// @notice Returns an amount of the pTokens underlier token for a given an amount of pToken (e.g. USDC pToken)
    /// @param vault Address of the Vault (FIAT)
    /// @param balancerVault Address of the Balancer V2 vault
    /// @param curvePoolId Id of the ConvergentCurvePool
    /// @param pTokenAmount Amount of token [tokenScale]
    /// @return Amount of underlier [underlierScale]
    function pTokenToUnderlier(
        address vault,
        address balancerVault,
        bytes32 curvePoolId,
        uint256 pTokenAmount
    ) external view returns (uint256) {
        return _solveTradeInvariant(pTokenAmount, vault, balancerVault, curvePoolId, false);
    }

    /// @dev Adapted from https://github.com/element-fi/elf-contracts/blob/main/contracts/ConvergentCurvePool.sol#L150
    function _solveTradeInvariant(
        uint256 amountIn_,
        address vault,
        address balancerVault,
        bytes32 poolId,
        bool fromUnderlier
    ) internal view returns (uint256) {
        uint256 tokenScale = IVault(vault).tokenScale();
        uint256 underlierScale = IVault(vault).underlierScale();

        // convert from either underlierScale or tokenScale to scale used by elf (== wad)
        uint256 amountIn = (fromUnderlier) ? wdiv(amountIn_, underlierScale) : wdiv(amountIn_, tokenScale);

        uint256 currentBalanceTokenIn;
        uint256 currentBalanceTokenOut;
        {
            (address[] memory tokens, uint256[] memory balances, ) = IBalancerVault(balancerVault).getPoolTokens(
                poolId
            );
            address token = IVault(vault).token();
            address underlier = IVault(vault).underlierToken();

            if (tokens[0] == underlier && tokens[1] == token) {
                currentBalanceTokenIn = (fromUnderlier)
                    ? wdiv(balances[0], underlierScale)
                    : wdiv(balances[1], tokenScale);
                currentBalanceTokenOut = (fromUnderlier)
                    ? wdiv(balances[1], tokenScale)
                    : wdiv(balances[0], underlierScale);
            } else if (tokens[0] == token && tokens[1] == underlier) {
                currentBalanceTokenIn = (fromUnderlier)
                    ? wdiv(balances[1], underlierScale)
                    : wdiv(balances[0], tokenScale);
                currentBalanceTokenOut = (fromUnderlier)
                    ? wdiv(balances[0], tokenScale)
                    : wdiv(balances[1], underlierScale);
            } else {
                revert LeverEPTActions__solveTradeInvariant_tokenMismatch();
            }
        }

        (address pool, ) = IBalancerVault(balancerVault).getPool(poolId);
        IConvergentCurvePool ccp = IConvergentCurvePool(pool);

        // https://github.com/element-fi/elf-contracts/blob/main/contracts/ConvergentCurvePool.sol#L680
        if (fromUnderlier) {
            unchecked {
                currentBalanceTokenOut += ccp.totalSupply();
            }
        } else {
            unchecked {
                currentBalanceTokenIn += ccp.totalSupply();
            }
        }

        uint256 amountOut = ccp.solveTradeInvariant(amountIn, currentBalanceTokenIn, currentBalanceTokenOut, true);
        uint256 impliedYieldFee = wmul(
            ccp.percentFee(),
            fromUnderlier
                ? sub(amountOut, amountIn) // If the output is token the implied yield is out - in
                : sub(amountIn, amountOut) // If the output is underlier the implied yield is in - out
        );

        // convert from wad to either tokenScale or underlierScale
        return wmul(sub(amountOut, impliedYieldFee), (fromUnderlier) ? tokenScale : underlierScale);
    }
}
