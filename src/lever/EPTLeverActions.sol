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

/// @title EPTLeverActions
/// @notice A set of vault actions for modifying positions collateralized by Element Finance pTokens
contract EPTLeverActions is Lever20Actions, ICreditFlashBorrower, IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    /// ======== Custom Errors ======== ///

    error EPTLeverActions__onFlashLoan_unknownInitiator();
    error EPTLeverActions__onFlashLoan_unknownToken();
    error EPTLeverActions__onFlashLoan_nonZeroFee();
    error EPTLeverActions__onCreditFlashLoan_unknownInitiator();
    error EPTLeverActions__onCreditFlashLoan_nonZeroFee();
    error EPTLeverActions__solveTradeInvariant_tokenMismatch();

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
        // Amount of `assetIn` to approve for `balancerVault` for swapping `assetIn` for `assetOut`
        uint256 approve;
    }

    struct FIATFlashLoanData {
        address vault;
        address token;
        address position;
        // Amount of underlier deposited by the user up front
        uint256 underlierAmount;
        SellFIATSwapParams fiatSwapParams;
        PTokenSwapParams swapParams;
    }

    struct CreditFlashLoanData {
        address vault;
        address token;
        address position;
        address collateralizer;
        // Amount of pTokens to be withdrawn
        uint256 pTokenAmount;
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
        uint256 underlierAmount,
        uint256 deltaNormalDebt,
        SellFIATSwapParams calldata fiatSwapParams,
        PTokenSwapParams calldata swapParams
    ) public {
        // if `collateralizer` is set to an external address then transfer amount to the proxy first
        // requires `collateralizer` to have set an allowance for the proxy
        if (collateralizer != address(0) && collateralizer != address(this)) {
            IERC20(swapParams.assetIn).safeTransferFrom(collateralizer, address(this), underlierAmount);
        }

        bytes memory data = abi.encode(
            FIATFlashLoanData(vault, swapParams.assetOut, position, underlierAmount, fiatSwapParams, swapParams)
        );
        flash.flashLoan(IERC3156FlashBorrower(address(this)), address(fiat), deltaNormalDebt, data);
    }

    /// @notice `buyCollateralAndIncreaseLever` flash loan callback
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        if (initiator != address(this)) revert EPTLeverActions__onFlashLoan_unknownInitiator();
        if (token != address(fiat)) revert EPTLeverActions__onFlashLoan_unknownToken();
        if (fee != 0) revert EPTLeverActions__onFlashLoan_nonZeroFee();

        FIATFlashLoanData memory params = abi.decode(data, (FIATFlashLoanData));

        uint256 deltaCollateral;
        {
            // 2. sell fiat for underlier
            uint256 underlierAmount = _sellFIATExactIn(params.fiatSwapParams, amount);

            // 3. sum underlier from sender and underliers from fiat swap
            underlierAmount = add(underlierAmount, params.underlierAmount);

            // 4. sell underlier for collateral token
            uint256 pTokenAmount = _buyPToken(underlierAmount, params.swapParams);
            deltaCollateral = wdiv(pTokenAmount, IVault(params.vault).tokenScale());
        }

        // 5. create position and mint fiat
        increaseCollateralAndDebt(
            params.vault,
            params.token,
            0,
            params.position,
            address(this),
            address(this),
            deltaCollateral,
            amount
        );

        // 6. payback
        fiat.approve(address(flash), amount);

        return CALLBACK_SUCCESS;
    }

    function sellCollateralAndIncreaseLever(
        address vault,
        address position,
        address collateralizer,
        uint256 pTokenAmount,
        uint256 deltaNormalDebt,
        BuyFIATSwapParams calldata fiatSwapParams,
        PTokenSwapParams calldata swapParams
    ) public {
        bytes memory data = abi.encode(
            CreditFlashLoanData(
                vault,
                swapParams.assetIn,
                position,
                collateralizer,
                pTokenAmount,
                fiatSwapParams,
                swapParams
            )
        );
        flash.creditFlashLoan(ICreditFlashBorrower(address(this)), deltaNormalDebt, data);
    }

    /// @notice `sellCollateralAndIncreaseLever` flash loan callback
    function onCreditFlashLoan(
        address initiator,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        if (initiator != address(this)) revert EPTLeverActions__onCreditFlashLoan_unknownInitiator();
        if (fee != 0) revert EPTLeverActions__onCreditFlashLoan_nonZeroFee();

        CreditFlashLoanData memory params = abi.decode(data, (CreditFlashLoanData));

        // 1. pay back debt
        decreaseCollateralAndDebt(
            params.vault,
            params.token,
            0,
            params.position,
            address(this),
            address(this),
            params.pTokenAmount,
            amount
        );

        // 2. sell collateral for underlier
        uint256 underlierAmount = _sellPToken(params.pTokenAmount, address(this), params.swapParams);

        // 3. sell part of underlier for FIAT
        uint256 underlierSwapped = _buyFIATExactOut(params.fiatSwapParams, amount);

        // 4. send underlier to collateralizer
        IERC20(params.swapParams.assetOut).transfer(params.collateralizer, sub(underlierAmount, underlierSwapped));

        // 5. payback
        fiat.approve(address(moneta), amount);
        moneta.enter(address(this), amount);
        codex.transferCredit(address(this), address(flash), amount);

        return CALLBACK_SUCCESS_CREDIT;
    }

    function _buyPToken(uint256 underlierAmount, PTokenSwapParams memory swapParams) internal returns (uint256) {
        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap(
            swapParams.poolId,
            IBalancerVault.SwapKind.GIVEN_IN,
            swapParams.assetIn,
            swapParams.assetOut,
            underlierAmount, // note precision
            new bytes(0)
        );
        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement(
            address(this),
            false,
            payable(address(this)),
            false
        );

        if (swapParams.approve != 0) {
            // approve balancer vault to transfer underlier tokens on behalf of proxy
            IERC20(swapParams.assetIn).approve(swapParams.balancerVault, swapParams.approve);
        }

        // kind == `GIVE_IN` use `minAmountOut` as `limit` to enforce min. amount of pTokens to receive
        return
            IBalancerVault(swapParams.balancerVault).swap(
                singleSwap,
                funds,
                swapParams.minAmountOut,
                swapParams.deadline
            );
    }

    function _sellPToken(
        uint256 pTokenAmount,
        address to,
        PTokenSwapParams memory swapParams
    ) internal returns (uint256) {
        // approve Balancer to transfer PToken
        IERC20(swapParams.assetIn).approve(swapParams.balancerVault, pTokenAmount);

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

        if (swapParams.approve != 0) {
            // approve balancer vault to transfer pTokens on behalf of proxy
            IERC20(swapParams.assetIn).approve(swapParams.balancerVault, swapParams.approve);
        }

        // kind == `GIVE_IN` use `minAmountOut` as `limit` to enforce min. amount of underliers to receive
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
                revert EPTLeverActions__solveTradeInvariant_tokenMismatch();
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
