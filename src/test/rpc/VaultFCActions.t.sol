// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {DSTest} from "ds-test/test.sol";

import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {MockProvider} from "mockprovider/MockProvider.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {Codex} from "fiat/Codex.sol";
import {Publican} from "fiat/Publican.sol";
import {Collybus} from "fiat/Collybus.sol";
import {FIAT} from "fiat/FIAT.sol";
import {Moneta} from "fiat/Moneta.sol";
import {toInt256, WAD, wdiv} from "fiat/utils/Math.sol";

import {VaultFC, IVaultFC} from "vaults/VaultFC.sol";

import {Hevm} from "../utils/Hevm.sol";
import {Caller} from "../utils/Caller.sol";

import {VaultFCActions, INotional, Constants, EncodeDecode} from "../../vault/VaultFCActions.sol";

contract VaultFCActions_RPC_tests is DSTest {
    Hevm internal hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    IERC20 internal DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F); // DAI
    PRBProxyFactory internal prbProxyFactory;

    Codex internal codex;
    Publican internal publican;
    MockProvider internal collybus;
    Moneta internal moneta;
    FIAT internal fiat;
    VaultFCActions internal vaultActions;
    PRBProxy internal userProxy;
    VaultFC internal vault;
    Caller kakaroto;

    address internal me = address(this);
    uint256 internal constant QUARTER = 86400 * 6 * 5 * 3;
    uint256 internal constant collateralAmount = 100000000;

    address internal cDAI = address(0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643);
    address internal notional = address(0x1344A36A1B56144C3Bc62E7757377D288fDE0369);

    uint256 ONE_DAI = 1e18;
    uint256 ONE_FCASH = 1e8;

    uint256 internal DAI_fCashId_1;
    uint256 internal DAI_fCashId_2;
    uint16 internal DAI_currencyId = 2;

    INotional.MarketParameters internal DAI_market_1;
    INotional.MarketParameters internal DAI_market_2;

    function _mintDAI(address to, uint256 amount) internal {
        hevm.store(address(DAI), keccak256(abi.encode(address(address(this)), uint256(0))), bytes32(uint256(1)));
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(DAI).call(abi.encodeWithSignature(sig, to, amount));
        assert(ok);
    }

    function _collateral(
        address vault_,
        uint256 tokenId_,
        address user
    ) internal view returns (uint256) {
        (uint256 collateral, ) = codex.positions(vault_, tokenId_, user);
        return collateral;
    }

    function _normalDebt(
        address vault_,
        uint256 tokenId_,
        address user
    ) internal view returns (uint256) {
        (, uint256 normalDebt) = codex.positions(vault_, tokenId_, user);
        return normalDebt;
    }

    function _modifyCollateralAndDebt(
        address vault_,
        address token,
        uint256 tokenId,
        address collateralizer,
        address creditor,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    ) internal {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                vault_,
                token,
                tokenId,
                address(userProxy),
                collateralizer,
                creditor,
                deltaCollateral,
                deltaNormalDebt
            )
        );
    }

    function _buyCollateralAndModifyDebt(
        address vault_,
        uint256 tokenId,
        address collateralizer,
        address creditor,
        uint256 underlierAmount,
        int256 deltaNormalDebt,
        uint32 limitLendRate
    ) internal {
        uint256 fCashAmount = VaultFCActions(vaultActions).underlierToFCash(tokenId, underlierAmount);
        bytes memory data = abi.encodeWithSelector(
            vaultActions.buyCollateralAndModifyDebt.selector,
            vault_,
            VaultFC(vault_).token(),
            tokenId,
            address(userProxy),
            collateralizer,
            creditor,
            fCashAmount,
            deltaNormalDebt,
            limitLendRate,
            underlierAmount
        );
        userProxy.execute(address(vaultActions), data);
    }

    function _sellCollateralAndModifyDebt(
        address vault_,
        uint256 tokenId,
        address collateralizer,
        address creditor,
        uint256 fCashAmount,
        int256 deltaNormalDebt,
        uint32 limitLendRate
    ) internal {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.sellCollateralAndModifyDebt.selector,
                vault_,
                VaultFC(vault_).token(),
                tokenId,
                address(userProxy),
                collateralizer,
                creditor,
                fCashAmount,
                deltaNormalDebt,
                limitLendRate
            )
        );
    }

    function _redeemCollateralAndModifyDebt(
        address vault_,
        uint256 tokenId,
        address collateralizer,
        address creditor,
        uint256 fCashAmount,
        int256 deltaNormalDebt
    ) internal {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.redeemCollateralAndModifyDebt.selector,
                vault_,
                VaultFC(vault_).token(),
                tokenId,
                address(userProxy),
                collateralizer,
                creditor,
                fCashAmount,
                deltaNormalDebt
            )
        );
    }

    function setUp() public {
        kakaroto = new Caller();
        codex = new Codex();
        publican = new Publican(address(codex));
        collybus = new MockProvider();
        fiat = new FIAT();
        moneta = new Moneta(address(codex), address(fiat));
        fiat.allowCaller(fiat.mint.selector, address(moneta));
        vaultActions = new VaultFCActions(address(codex), address(moneta), address(fiat), address(publican), notional);

        prbProxyFactory = new PRBProxyFactory();

        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        INotional.MarketParameters[] memory markets = INotional(notional).getActiveMarkets(2);

        DAI_market_1 = markets[0];
        DAI_fCashId_1 = EncodeDecode.encodeERC1155Id(DAI_currencyId, DAI_market_1.maturity, Constants.FCASH_ASSET_TYPE);
        DAI_market_2 = markets[1];
        DAI_fCashId_2 = EncodeDecode.encodeERC1155Id(DAI_currencyId, DAI_market_2.maturity, Constants.FCASH_ASSET_TYPE);

        vault = new VaultFC(
            address(codex),
            address(collybus),
            notional,
            address(DAI), // cDAI,
            uint256(86400 * 6 * 5 * 3),
            DAI_currencyId
        );

        codex.allowCaller(keccak256("ANY_SIG"), address(publican));
        publican.init(address(vault));
        publican.setParam(address(vault), "interestPerSecond", WAD);

        codex.setParam("globalDebtCeiling", uint256(10000 ether));
        codex.setParam(address(vault), "debtCeiling", uint256(10000 ether));
        codex.allowCaller(codex.modifyBalance.selector, address(vault));
        codex.init(address(vault));

        _mintDAI(me, 2000 ether);

        DAI.approve(address(userProxy), type(uint256).max);
        fiat.approve(address(userProxy), type(uint256).max);
        kakaroto.externalCall(
            address(fiat),
            abi.encodeWithSelector(fiat.approve.selector, address(userProxy), type(uint256).max)
        );
        kakaroto.externalCall(
            address(DAI),
            abi.encodeWithSelector(DAI.approve.selector, address(userProxy), type(uint256).max)
        );

        IERC1155(notional).setApprovalForAll(address(userProxy), true);
        kakaroto.externalCall(
            address(notional),
            abi.encodeWithSelector(IERC1155.setApprovalForAll.selector, address(userProxy), true)
        );

        collybus.givenSelectorReturnResponse(
            Collybus.read.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(uint256(WAD))}),
            false
        );

        //  need this to burn FIAT
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), type(uint256).max)
        );

        // // need this for buying fCash from Notional
        // userProxy.execute(
        //     address(vaultActions),
        //     abi.encodeWithSelector(vaultActions.approveToken.selector, address(DAI), notional, type(uint256).max)
        // );

        // TODO: do we need this?
        // need this for selling fCash to Notional
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.setApprovalForAll.selector, notional, notional, true)
        );
    }

    function test_getMaturity() public {
        assertEq(vaultActions.getMaturity(DAI_fCashId_1), DAI_market_1.maturity);
        assertEq(vaultActions.getMaturity(DAI_fCashId_2), DAI_market_2.maturity);
    }

    function test_getCurrencyId() public {
        assertEq(vaultActions.getCurrencyId(DAI_fCashId_1), DAI_currencyId);
        assertEq(vaultActions.getCurrencyId(DAI_fCashId_2), DAI_currencyId);
    }

    function test_getMarketIndex() public {
        assertEq(vaultActions.getMarketIndex(DAI_fCashId_1), 1);
        assertEq(vaultActions.getMarketIndex(DAI_fCashId_2), 2);
    }

    function test_getUnderlyingToken() public {
        (IERC20 underlying1, uint256 decimals1) = vaultActions.getUnderlierToken(DAI_fCashId_1);
        (IERC20 underlying2, uint256 decimals2) = vaultActions.getUnderlierToken(DAI_fCashId_2);
        assertEq(address(underlying1), address(DAI));
        assertEq(address(underlying2), address(DAI));
        assertEq(decimals1, uint256(10**18));
        assertEq(decimals2, uint256(10**18));
    }

    function test_getAssetToken() public {
        (IERC20 asset1, uint256 decimals1) = vaultActions.getCToken(DAI_fCashId_1);
        (IERC20 asset2, uint256 decimals2) = vaultActions.getCToken(DAI_fCashId_2);
        assertEq(address(asset1), cDAI);
        assertEq(address(asset2), cDAI);
        assertEq(decimals1, uint256(ONE_FCASH));
        assertEq(decimals2, uint256(ONE_FCASH));
    }

    function test_getfCashAmountGivenUnderlierAmount() public {
        uint256 fcashamount = vaultActions.underlierToFCash(DAI_fCashId_1, 1000 * ONE_DAI);

        emit log_named_uint("fcashamount", fcashamount);

        (int256 assetCashInternal, int256 underlyingCashInternal) = INotional(notional).getCashAmountGivenfCashAmount(
            2,
            int88(int256(fcashamount)),
            vaultActions.getMarketIndex(DAI_fCashId_1),
            block.timestamp
        );

        emit log_named_int("assetCashInternal", assetCashInternal);
        emit log_named_int("underlyingCashInternal", underlyingCashInternal);

        // assert(false);
    }

    function test_increaseCollateral_from_underlier() public {
        uint256 amount = 1000 * ONE_DAI;
        uint256 meInitialBalance = DAI.balanceOf(me);
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 fCashAmount = vaultActions.underlierToFCash(DAI_fCashId_1, 1000 * ONE_DAI);

        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, address(0), amount, 0, 0);

        uint256 meBalanceAfter = DAI.balanceOf(me);

        assertTrue(meBalanceAfter < meInitialBalance && meBalanceAfter >= meInitialBalance - amount);
        assertGe(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance + uint256(fCashAmount)
        );
        assertGe(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral + uint256(fCashAmount)
        );
    }

    function test_increaseCollateral_from_user_underlier() public {
        uint256 amount = 1000 * ONE_DAI;
        DAI.transfer(address(kakaroto), amount);

        uint256 kakarotoInitialBalance = DAI.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));

        uint256 fCashAmount = vaultActions.underlierToFCash(DAI_fCashId_1, 1000 * ONE_DAI);

        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, address(kakaroto), address(0), amount, 0, 0);

        uint256 kakarotoBalanceAfter = DAI.balanceOf(address(kakaroto));

        assertTrue(
            kakarotoBalanceAfter < kakarotoInitialBalance && kakarotoBalanceAfter >= kakarotoInitialBalance - amount
        );
        assertGe(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance + uint256(fCashAmount)
        );
        assertGe(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral + uint256(fCashAmount)
        );
    }

    function test_increaseCollateral_from_proxy_zero_underlier() public {
        uint256 amount = 1000 * ONE_DAI;
        DAI.transfer(address(userProxy), amount);

        uint256 userProxyInitialBalance = DAI.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));

        uint256 fCashAmount = vaultActions.underlierToFCash(DAI_fCashId_1, 1000 * ONE_DAI);

        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, address(0), address(0), amount, 0, 0);

        uint256 userProxyBalanceAfter = DAI.balanceOf(address(userProxy));

        assertTrue(
            userProxyBalanceAfter < userProxyInitialBalance && userProxyBalanceAfter >= userProxyInitialBalance - amount
        );
        assertGe(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance + uint256(fCashAmount)
        );
        assertGe(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral + uint256(fCashAmount)
        );
    }

    function test_increaseCollateral_from_proxy_address_underlier() public {
        uint256 amount = 1000 * ONE_DAI;
        DAI.transfer(address(userProxy), amount);

        uint256 userProxyInitialBalance = DAI.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));

        uint256 fCashAmount = vaultActions.underlierToFCash(DAI_fCashId_1, 1000 * ONE_DAI);

        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, address(userProxy), address(0), amount, 0, 0);

        uint256 userProxyBalanceAfter = DAI.balanceOf(address(userProxy));

        assertTrue(
            userProxyBalanceAfter < userProxyInitialBalance && userProxyBalanceAfter >= userProxyInitialBalance - amount
        );
        assertGe(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance + uint256(fCashAmount)
        );
        assertGe(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral + uint256(fCashAmount)
        );
    }

    function test_decreaseCollateral_get_underlier() public {
        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, address(0), 1000 * ONE_DAI, 0, 0);

        uint256 meInitialBalance = DAI.balanceOf(me);
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));

        uint256 amount = 500 * ONE_FCASH;
        // uint256 underlierAmount = vaultActions.fCashToUnderlier(DAI_fCashId_1, 500 * ONE_FCASH);

        _sellCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, address(0), amount, 0, 0);

        uint256 meBalanceAfter = DAI.balanceOf(me);

        assertGt(meBalanceAfter, meInitialBalance);
        // TODO: test that underlierAmount should be approximated to meBalanceAfter - meInitialBalance
        // assertLe(meBalanceAfter, meInitialBalance + uint256(underlierAmount));

        assertEq(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance - uint256(500 * ONE_FCASH)
        );
        assertEq(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral - wdiv(amount, ONE_FCASH)
        );
    }

    function test_decreaseCollateral_send_underlier_to_user() public {
        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, address(0), 1000 * ONE_DAI, 0, 0);

        uint256 kakrotoInitialBalance = DAI.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));

        uint256 amount = 500 * ONE_FCASH;
        // uint256 underlierAmount = vaultActions.fCashToUnderlier(DAI_fCashId_1, 500 * ONE_FCASH);

        _sellCollateralAndModifyDebt(address(vault), DAI_fCashId_1, address(kakaroto), address(0), amount, 0, 0);

        uint256 kakarotoBalanceAfter = DAI.balanceOf(address(kakaroto));

        assertGt(kakarotoBalanceAfter, kakrotoInitialBalance);
        // TODO: test that underlierAmount should be approximated to kakarotoBalanceAfter - kakrotoInitialBalance
        // assertLe(kakarotoBalanceAfter, kakrotoInitialBalance + uint256(underlierAmount));

        assertEq(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance - uint256(500 * ONE_FCASH)
        );
        assertEq(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral - wdiv(amount, ONE_FCASH)
        );
    }

    function test_decreaseCollateral_withdraw_underlier() public {
        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, address(0), 1000 * ONE_DAI, 0, 0);

        uint256 meInitialBalance = DAI.balanceOf(me);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));

        uint256 amount = 500 * ONE_FCASH;

        hevm.warp(DAI_market_1.maturity + 1);

        uint256 redeems = IVaultFC(vault).redeems(DAI_fCashId_1, 500 * ONE_FCASH, 0);

        _redeemCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, address(0), amount, 0);

        uint256 meBalanceAfter = DAI.balanceOf(me);

        // user received underlier tokens
        assertEq(meBalanceAfter - meInitialBalance, redeems);
        // should have burned all of the fCash
        assertEq(IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1), 0);
        // internal collateral balance decreased by redeemed fCash amount
        assertEq(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral - wdiv(amount, ONE_FCASH)
        );
    }

    function test_decreaseCollateral_withdraw_underlier_to_user() public {
        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, address(0), 1000 * ONE_DAI, 0, 0);

        uint256 kakrotoInitialBalance = DAI.balanceOf(address(kakaroto));
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));

        uint256 amount = 500 * ONE_FCASH;

        hevm.warp(DAI_market_1.maturity + 1);

        uint256 redeems = IVaultFC(vault).redeems(DAI_fCashId_1, 500 * ONE_FCASH, 0);

        _redeemCollateralAndModifyDebt(address(vault), DAI_fCashId_1, address(kakaroto), address(0), amount, 0);

        uint256 kakarotoBalanceAfter = DAI.balanceOf(address(kakaroto));

        // user received underlier tokens
        assertEq(kakarotoBalanceAfter - kakrotoInitialBalance, redeems);
        // should have burned all of the fCash
        assertEq(IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1), 0);
        // internal collateral balance decreased by redeemed fCash amount
        assertEq(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral - wdiv(amount, ONE_FCASH)
        );
    }

    function test_increaseDebt() public {
        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, address(0), 1000 * ONE_DAI, 0, 0);

        uint256 meInitialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));

        _modifyCollateralAndDebt(address(vault), notional, DAI_fCashId_1, address(0), me, 0, toInt256(500 * WAD));

        assertEq(fiat.balanceOf(me), meInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_increaseDebt_send_to_user() public {
        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, address(0), 1000 * ONE_DAI, 0, 0);

        uint256 initialBalance = fiat.balanceOf(address(kakaroto));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));

        _modifyCollateralAndDebt(
            address(vault),
            notional,
            DAI_fCashId_1,
            address(0),
            address(kakaroto),
            0,
            toInt256(500 * WAD)
        );

        assertEq(fiat.balanceOf(address(kakaroto)), initialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_decreaseDebt() public {
        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, me, 1000 * ONE_DAI, toInt256(500 * WAD), 0);

        uint256 initialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));

        _modifyCollateralAndDebt(address(vault), notional, DAI_fCashId_1, address(0), me, 0, -toInt256(200 * WAD));

        assertEq(fiat.balanceOf(me), initialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decreaseDebt_get_fiat_from_user() public {
        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, me, 1000 * ONE_DAI, toInt256(500 * WAD), 0);

        fiat.transfer(address(kakaroto), 500 * WAD);

        uint256 initialBalance = fiat.balanceOf(address(kakaroto));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));

        _modifyCollateralAndDebt(
            address(vault),
            notional,
            DAI_fCashId_1,
            address(0),
            address(kakaroto),
            0,
            -toInt256(200 * WAD)
        );

        assertEq(fiat.balanceOf(address(kakaroto)), initialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decreaseDebt_get_fiat_from_proxy_zero() public {
        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, me, 1000 * ONE_DAI, toInt256(500 * WAD), 0);

        fiat.transfer(address(userProxy), 500 * WAD);

        uint256 initialBalance = fiat.balanceOf(address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));

        _modifyCollateralAndDebt(
            address(vault),
            notional,
            DAI_fCashId_1,
            address(0),
            address(0),
            0,
            -toInt256(200 * WAD)
        );

        assertEq(fiat.balanceOf(address(userProxy)), initialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decreaseDebt_get_fiat_from_proxy_address() public {
        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, me, 1000 * ONE_DAI, toInt256(500 * WAD), 0);

        fiat.transfer(address(userProxy), 500 * WAD);

        uint256 initialBalance = fiat.balanceOf(address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));

        _modifyCollateralAndDebt(
            address(vault),
            notional,
            DAI_fCashId_1,
            address(0),
            address(userProxy),
            0,
            -toInt256(200 * WAD)
        );

        assertEq(fiat.balanceOf(address(userProxy)), initialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_increaseCollateral_from_underlier_and_increaseDebt() public {
        uint256 underlierInitialBalance = DAI.balanceOf(me);
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 fiatInitialBalance = fiat.balanceOf(me);

        uint256 tokenAmount = 1000 * ONE_DAI;
        uint256 debtAmount = 500 * WAD;

        uint256 fCashAmount = vaultActions.underlierToFCash(DAI_fCashId_1, 1000 * ONE_DAI);

        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, me, tokenAmount, toInt256(debtAmount), 0);

        uint256 underlierBalance = DAI.balanceOf(me);

        assertTrue(
            underlierBalance < underlierInitialBalance && underlierBalance >= underlierInitialBalance - tokenAmount
        );
        assertGe(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance + uint256(fCashAmount)
        );
        assertGe(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral + wdiv(fCashAmount, ONE_FCASH)
        );

        assertEq(fiat.balanceOf(me), fiatInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_increaseCollateral_from_user_underlier_and_increaseDebt() public {
        DAI.transfer(address(kakaroto), 1000 * ONE_DAI);
        uint256 underlierInitialBalance = DAI.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 fiatInitialBalance = fiat.balanceOf(me);

        uint256 tokenAmount = 1000 * ONE_DAI;
        uint256 debtAmount = 500 * WAD;

        uint256 fCashAmount = vaultActions.underlierToFCash(DAI_fCashId_1, 1000 * ONE_DAI);

        _buyCollateralAndModifyDebt(
            address(vault),
            DAI_fCashId_1,
            address(kakaroto),
            me,
            tokenAmount,
            toInt256(debtAmount),
            0
        );

        uint256 underlierBalance = DAI.balanceOf(address(kakaroto));

        assertTrue(
            underlierBalance < underlierInitialBalance && underlierBalance >= underlierInitialBalance - tokenAmount
        );
        assertGe(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance + uint256(fCashAmount)
        );
        assertGe(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral + wdiv(fCashAmount, ONE_FCASH)
        );

        assertEq(fiat.balanceOf(me), fiatInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_increaseCollateral_from_zeroAddress_proxy_underlier_and_increaseDebt() public {
        DAI.transfer(address(userProxy), 1000 * ONE_DAI);
        uint256 underlierInitialBalance = DAI.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 fiatInitialBalance = fiat.balanceOf(me);

        uint256 tokenAmount = 1000 * ONE_DAI;
        uint256 debtAmount = 500 * WAD;

        uint256 fCashAmount = vaultActions.underlierToFCash(DAI_fCashId_1, 1000 * ONE_DAI);

        _buyCollateralAndModifyDebt(
            address(vault),
            DAI_fCashId_1,
            address(0),
            me,
            tokenAmount,
            toInt256(debtAmount),
            0
        );

        uint256 underlierBalance = DAI.balanceOf(address(userProxy));

        assertTrue(
            underlierBalance < underlierInitialBalance && underlierBalance >= underlierInitialBalance - tokenAmount
        );
        assertGe(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance + uint256(fCashAmount)
        );
        assertGe(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral + wdiv(fCashAmount, ONE_FCASH)
        );

        assertEq(fiat.balanceOf(me), fiatInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_increaseCollateral_from_proxy_underlier_and_increaseDebt() public {
        DAI.transfer(address(userProxy), 1000 * ONE_DAI);
        uint256 underlierInitialBalance = DAI.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 fiatInitialBalance = fiat.balanceOf(me);

        uint256 tokenAmount = 1000 * ONE_DAI;
        uint256 debtAmount = 500 * WAD;

        uint256 fCashAmount = vaultActions.underlierToFCash(DAI_fCashId_1, 1000 * ONE_DAI);

        _buyCollateralAndModifyDebt(
            address(vault),
            DAI_fCashId_1,
            address(userProxy),
            me,
            tokenAmount,
            toInt256(debtAmount),
            0
        );

        uint256 underlierBalance = DAI.balanceOf(address(userProxy));

        assertTrue(
            underlierBalance < underlierInitialBalance && underlierBalance >= underlierInitialBalance - tokenAmount
        );
        assertGe(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance + uint256(fCashAmount)
        );
        assertGe(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral + wdiv(fCashAmount, ONE_FCASH)
        );

        assertEq(fiat.balanceOf(me), fiatInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_increaseCollateral_from_underlier_and_increaseDebt_send_fiat_to_user() public {
        uint256 underlierInitialBalance = DAI.balanceOf(me);
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 fiatInitialBalance = fiat.balanceOf(address(kakaroto));

        uint256 tokenAmount = 1000 * ONE_DAI;
        uint256 debtAmount = 500 * WAD;

        uint256 fCashAmount = vaultActions.underlierToFCash(DAI_fCashId_1, 1000 * ONE_DAI);

        _buyCollateralAndModifyDebt(
            address(vault),
            DAI_fCashId_1,
            me,
            address(kakaroto),
            tokenAmount,
            toInt256(debtAmount),
            0
        );

        uint256 underlierBalance = DAI.balanceOf(me);

        assertTrue(
            underlierBalance < underlierInitialBalance && underlierBalance >= underlierInitialBalance - tokenAmount
        );
        assertGe(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance + uint256(fCashAmount)
        );
        assertGe(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral + wdiv(fCashAmount, ONE_FCASH)
        );

        assertEq(fiat.balanceOf(address(kakaroto)), fiatInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_decrease_debt_and_decrease_collateral_get_underlier() public {
        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, me, 1000 * ONE_DAI, toInt256(500 * WAD), 0);

        uint256 undelierInitialBalance = DAI.balanceOf(me);
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 fiatInitialBalance = fiat.balanceOf(me);

        _sellCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, me, 300 * ONE_FCASH, -toInt256(200 * WAD), 0);

        uint256 underlierBalanceAfter = DAI.balanceOf(me);

        // TODO: test that underlierAmount should be approximated to meBalanceAfter - meInitialBalance
        assertTrue(underlierBalanceAfter > undelierInitialBalance);

        assertEq(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance - uint256(300 * ONE_FCASH)
        );
        assertEq(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral - uint256(300 * ONE_DAI)
        );

        assertEq(fiat.balanceOf(me), fiatInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decrease_debt_and_decrease_collateral_get_underlier_to_user() public {
        _buyCollateralAndModifyDebt(address(vault), DAI_fCashId_1, me, me, 1000 * ONE_DAI, toInt256(500 * WAD), 0);

        uint256 undelierInitialBalance = DAI.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 fiatInitialBalance = fiat.balanceOf(me);

        _sellCollateralAndModifyDebt(
            address(vault),
            DAI_fCashId_1,
            address(kakaroto),
            me,
            300 * ONE_FCASH,
            -toInt256(200 * WAD),
            0
        );

        uint256 underlierBalanceAfter = DAI.balanceOf(address(kakaroto));

        // TODO: test that underlierAmount should be approximated to meBalanceAfter - meInitialBalance
        assertTrue(underlierBalanceAfter > undelierInitialBalance);

        assertEq(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance - uint256(300 * ONE_FCASH)
        );
        assertEq(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral - uint256(300 * ONE_DAI)
        );

        assertEq(fiat.balanceOf(me), fiatInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decrease_debt_get_fiat_from_user_and_decrease_collateral_get_underlier() public {
        _buyCollateralAndModifyDebt(
            address(vault),
            DAI_fCashId_1,
            me,
            address(kakaroto),
            1000 * ONE_DAI,
            toInt256(500 * WAD),
            0
        );

        uint256 undelierInitialBalance = DAI.balanceOf(me);
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 fiatInitialBalance = fiat.balanceOf(address(kakaroto));

        _sellCollateralAndModifyDebt(
            address(vault),
            DAI_fCashId_1,
            me,
            address(kakaroto),
            300 * ONE_FCASH,
            -toInt256(200 * WAD),
            0
        );

        uint256 underlierBalanceAfter = DAI.balanceOf(me);

        // TODO: test that underlierAmount should be approximated to meBalanceAfter - meInitialBalance
        assertTrue(underlierBalanceAfter > undelierInitialBalance);

        assertEq(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance - uint256(300 * ONE_FCASH)
        );
        assertEq(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral - uint256(300 * ONE_DAI)
        );

        assertEq(fiat.balanceOf(address(kakaroto)), fiatInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decrease_debt_get_fiat_from_proxy_zero_and_decrease_collateral_get_underlier() public {
        _buyCollateralAndModifyDebt(
            address(vault),
            DAI_fCashId_1,
            me,
            address(userProxy),
            1000 * ONE_DAI,
            toInt256(500 * WAD),
            0
        );

        uint256 undelierInitialBalance = DAI.balanceOf(me);
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 fiatInitialBalance = fiat.balanceOf(address(userProxy));

        _sellCollateralAndModifyDebt(
            address(vault),
            DAI_fCashId_1,
            me,
            address(0),
            300 * ONE_FCASH,
            -toInt256(200 * WAD),
            0
        );

        uint256 underlierBalanceAfter = DAI.balanceOf(me);

        // TODO: test that underlierAmount should be approximated to meBalanceAfter - meInitialBalance
        assertTrue(underlierBalanceAfter > undelierInitialBalance);

        assertEq(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance - uint256(300 * ONE_FCASH)
        );
        assertEq(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral - uint256(300 * ONE_DAI)
        );

        assertEq(fiat.balanceOf(address(userProxy)), fiatInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decrease_debt_get_fiat_from_proxy_and_decrease_collateral_get_underlier() public {
        _buyCollateralAndModifyDebt(
            address(vault),
            DAI_fCashId_1,
            me,
            address(userProxy),
            1000 * ONE_DAI,
            toInt256(500 * WAD),
            0
        );

        uint256 undelierInitialBalance = DAI.balanceOf(me);
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1);
        uint256 initialCollateral = _collateral(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), DAI_fCashId_1, address(userProxy));
        uint256 fiatInitialBalance = fiat.balanceOf(address(userProxy));

        _sellCollateralAndModifyDebt(
            address(vault),
            DAI_fCashId_1,
            me,
            address(userProxy),
            300 * ONE_FCASH,
            -toInt256(200 * WAD),
            0
        );

        uint256 underlierBalanceAfter = DAI.balanceOf(me);

        // TODO: test that underlierAmount should be approximated to meBalanceAfter - meInitialBalance
        assertTrue(underlierBalanceAfter > undelierInitialBalance);

        assertEq(
            IERC1155(notional).balanceOf(address(vault), DAI_fCashId_1),
            vaultInitialBalance - uint256(300 * ONE_FCASH)
        );
        assertEq(
            _collateral(address(vault), DAI_fCashId_1, address(userProxy)),
            initialCollateral - uint256(300 * ONE_DAI)
        );

        assertEq(fiat.balanceOf(address(userProxy)), fiatInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault), DAI_fCashId_1, address(userProxy)), initialDebt - (200 * WAD));
    }
}
