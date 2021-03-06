// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {DSTest} from "ds-test/test.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockProvider} from "mockprovider/MockProvider.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {Codex} from "fiat/Codex.sol";
import {Publican} from "fiat/Publican.sol";
import {Moneta} from "fiat/Moneta.sol";
import {FIAT} from "fiat/FIAT.sol";
import {IMoneta} from "fiat/interfaces/IMoneta.sol";
import {IVault} from "fiat/interfaces/IVault.sol";

import {Vault20Actions} from "../../vault/Vault20Actions.sol";

interface IERC20Safe {
    function safeTransfer(address to, uint256 value) external;

    function safeTransferFrom(
        address from,
        address to,
        uint256 value
    ) external;
}

contract Vault20Actions_UnitTest is DSTest {
    Codex codex;
    Moneta moneta;
    MockProvider mockCollateral;
    PRBProxy userProxy;
    PRBProxyFactory prbProxyFactory;
    Vault20Actions vaultActions;
    FIAT fiat;

    address me = address(this);

    function setUp() public {
        fiat = new FIAT();
        codex = new Codex();
        moneta = new Moneta(address(codex), address(fiat));
        mockCollateral = new MockProvider();

        prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        vaultActions = new Vault20Actions(address(codex), address(moneta), address(fiat), address(0));

        fiat.allowCaller(keccak256("ANY_SIG"), address(moneta));
        codex.createUnbackedDebt(address(userProxy), address(userProxy), 100);

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), 100)
        );
    }

    function test_exitMoneta() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.exitMoneta.selector, address(userProxy), 100)
        );

        assertEq(codex.credit(address(userProxy)), 0);
        assertEq(fiat.balanceOf(address(userProxy)), 100);
        assertEq(codex.credit(address(moneta)), 100);
        assertEq(fiat.balanceOf(address(moneta)), 0);
    }

    function test_exitMoneta_to_user() public {
        userProxy.execute(address(vaultActions), abi.encodeWithSelector(vaultActions.exitMoneta.selector, me, 100));

        assertEq(codex.credit(address(userProxy)), 0);
        assertEq(fiat.balanceOf(address(userProxy)), 0);
        assertEq(codex.credit(address(moneta)), 100);
        assertEq(fiat.balanceOf(address(moneta)), 0);
        assertEq(fiat.balanceOf(me), 100);
    }

    function test_enterMoneta() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.exitMoneta.selector, address(userProxy), 100)
        );
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.enterMoneta.selector, address(userProxy), 100)
        );

        assertEq(fiat.balanceOf(address(userProxy)), 0);
        assertEq(codex.credit(address(userProxy)), 100);
        assertEq(codex.credit(address(moneta)), 0);
    }

    function test_enterMoneta_from_user() public {
        userProxy.execute(address(vaultActions), abi.encodeWithSelector(vaultActions.exitMoneta.selector, me, 100));

        fiat.approve(address(userProxy), 100);

        userProxy.execute(address(vaultActions), abi.encodeWithSelector(vaultActions.enterMoneta.selector, me, 100));

        assertEq(fiat.balanceOf(me), 0);
        assertEq(codex.credit(address(userProxy)), 100);
        assertEq(codex.credit(address(moneta)), 0);
    }
}
