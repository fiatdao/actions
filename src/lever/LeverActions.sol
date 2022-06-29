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
import {WAD, toInt256, wmul, wdiv, sub} from "fiat/utils/Math.sol";

interface IBalancerVault {
    enum SwapKind {
        GIVEN_IN,
        GIVEN_OUT
    }

    struct FundManagement {
        address sender;
        bool fromInternalBalance;
        address payable recipient;
        bool toInternalBalance;
    }

    struct SingleSwap {
        bytes32 poolId;
        SwapKind kind;
        address assetIn;
        address assetOut;
        uint256 amount;
        bytes userData;
    }

    function swap(
        SingleSwap memory singleSwap,
        FundManagement memory funds,
        uint256 limit,
        uint256 deadline
    ) external payable returns (uint256);

    function getPoolTokens(bytes32 poolId)
        external
        view
        returns (
            address[] memory tokens,
            uint256[] memory balances,
            uint256 lastChangeBlock
        );

    enum PoolSpecialization {
        GENERAL,
        MINIMAL_SWAP_INFO,
        TWO_TOKEN
    }

    function getPool(bytes32 poolId) external view returns (address, PoolSpecialization);
}

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// WARNING: These functions meant to be used as a a library for a PRBProxy. Some are unsafe if you call them directly.
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

/// @title LeverActions
/// @notice
abstract contract LeverActions {
    /// ======== Custom Errors ======== ///

    error LeverActions__exitMoneta_zeroUserAddress();

    /// ======== Storage ======== ///

    struct SellFIATSwapParams {
        // Paired asset with FIAT (e.g. DAI, USDC)
        address assetOut;
        // Min. amount of tokens we would accept to receive from the swap
        uint256 minAmountOut;
        // Timestamp at which swap must be confirmed by [seconds]
        uint256 deadline;
    }

    struct BuyFIATSwapParams {
        // Paired asset with FIAT (e.g. DAI, USDC)
        address assetIn;
        // Max. amount of tokens to be swapped for exactAmountOut of FIAT
        uint256 maxAmountIn;
        // Timestamp at which swap must be confirmed by [seconds]
        uint256 deadline;
    }

    /// @notice Codex
    ICodex public immutable codex;
    /// @notice FIAT token
    IFIAT public immutable fiat;
    /// @notice Flash
    IFlash public immutable flash;
    /// @notice Moneta
    IMoneta public immutable moneta;
    /// @notice Publican
    IPublican public immutable publican;

    // FIAT - DAI - USDC Balancer Pool
    bytes32 public immutable fiatPoolId;
    address public immutable fiatBalancerVault;

    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    bytes32 public constant CALLBACK_SUCCESS_CREDIT = keccak256("CreditFlashBorrower.onCreditFlashLoan");

    constructor(
        address codex_,
        address fiat_,
        address flash_,
        address moneta_,
        address publican_,
        bytes32 fiatPoolId_,
        address fiatBalancerVault_
    ) {
        codex = ICodex(codex_);
        fiat = IFIAT(fiat_);
        flash = IFlash(flash_);
        moneta = IMoneta(moneta_);
        publican = IPublican(publican_);
        fiatPoolId = fiatPoolId_;
        fiatBalancerVault = fiatBalancerVault_;

        (address[] memory tokens, , ) = IBalancerVault(fiatBalancerVault_).getPoolTokens(fiatPoolId);
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).approve(fiatBalancerVault_, type(uint256).max);
        }
    }

    /// @notice Sets `amount` as the allowance of `spender` over the UserProxy's FIAT
    /// @param spender Address of the spender
    /// @param amount Amount of tokens to approve [wad]
    function approveFIAT(address spender, uint256 amount) external {
        fiat.approve(spender, amount);
    }

    /// @dev Redeems FIAT for internal credit
    /// @param to Address of the recipient
    /// @param amount Amount of FIAT to exit [wad]
    function exitMoneta(address to, uint256 amount) public {
        if (to == address(0)) revert LeverActions__exitMoneta_zeroUserAddress();

        // proxy needs to delegate ability to transfer internal credit on its behalf to Moneta first
        if (codex.delegates(address(this), address(moneta)) != 1) codex.grantDelegate(address(moneta));

        moneta.exit(to, amount);
    }

    /// @dev The user needs to previously call approveFIAT with the address of Moneta as the spender
    /// @param from Address of the account which provides FIAT
    /// @param amount Amount of FIAT to enter [wad]
    function enterMoneta(address from, uint256 amount) public {
        // if `from` is set to an external address then transfer amount to the proxy first
        // requires `from` to have set an allowance for the proxy
        if (from != address(0) && from != address(this)) fiat.transferFrom(from, address(this), amount);

        moneta.enter(address(this), amount);
    }

    /// @notice Deposits `amount` of `token` with `tokenId` from `from` into the `vault`
    /// @dev Virtual method to be implement in token specific UserAction contracts
    function enterVault(
        address vault,
        address token,
        uint256 tokenId,
        address from,
        uint256 amount
    ) public virtual;

    /// @notice Withdraws `amount` of `token` with `tokenId` to `to` from the `vault`
    /// @dev Virtual method to be implement in token specific UserAction contracts
    function exitVault(
        address vault,
        address token,
        uint256 tokenId,
        address to,
        uint256 amount
    ) public virtual;

    function increaseCollateralAndDebt(
        address vault,
        address token,
        uint256 tokenId,
        address position,
        address collateralizer,
        address creditor,
        uint256 deltaCollateral,
        uint256 deltaDebt
    ) public {
        // update the interest rate accumulator in Codex for the vault
        if (deltaDebt != 0) publican.collect(vault);

        // transfer tokens to be used as collateral into Vault
        enterVault(vault, token, tokenId, collateralizer, wmul(uint256(deltaCollateral), IVault(vault).tokenScale()));

        // update collateral and debt balanaces
        (, uint256 rate, , ) = codex.vaults(vault);
        codex.modifyCollateralAndDebt(
            vault,
            tokenId,
            position,
            address(this),
            address(this),
            toInt256(deltaCollateral),
            toInt256(wdiv(deltaDebt, rate))
        );

        // redeem newly generated internal credit for FIAT
        exitMoneta(creditor, deltaDebt);
    }

    function decreaseCollateralAndDebt(
        address vault,
        address token,
        uint256 tokenId,
        address position,
        address collateralizer,
        address creditor,
        uint256 deltaCollateral,
        uint256 deltaNormalDebt
    ) public {
        // update the interest rate accumulator in Codex for the vault
        if (deltaNormalDebt != 0) publican.collect(vault);

        // add due interest from normal debt
        (, uint256 rate, , ) = codex.vaults(vault);
        enterMoneta(creditor, wmul(rate, deltaNormalDebt));

        // update collateral and debt balanaces
        codex.modifyCollateralAndDebt(
            vault,
            tokenId,
            position,
            address(this),
            address(this),
            toInt256(deltaCollateral),
            toInt256(deltaNormalDebt)
        );

        // withdraw tokens not be used as collateral anymore from Vault
        exitVault(vault, token, tokenId, collateralizer, wmul(deltaCollateral, IVault(vault).tokenScale()));
    }

    function _sellFIATExactIn(SellFIATSwapParams memory params, uint256 exactAmountIn) internal returns (uint256) {
        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap(
            fiatPoolId,
            IBalancerVault.SwapKind.GIVEN_IN,
            address(fiat),
            params.assetOut,
            exactAmountIn,
            new bytes(0)
        );
        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement(
            address(this),
            false,
            payable(address(this)),
            false
        );
        return IBalancerVault(fiatBalancerVault).swap(singleSwap, funds, params.minAmountOut, params.deadline);
    }

    function _buyFIATExactOut(BuyFIATSwapParams memory params, uint256 exactAmountOut) internal returns (uint256) {
        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap(
            fiatPoolId,
            IBalancerVault.SwapKind.GIVEN_OUT,
            params.assetIn,
            address(fiat),
            exactAmountOut,
            new bytes(0)
        );
        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement(
            address(this),
            false,
            payable(address(this)),
            false
        );
        return IBalancerVault(fiatBalancerVault).swap(singleSwap, funds, params.maxAmountIn, params.deadline);
    }
}
