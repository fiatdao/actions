// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {DSTest} from "ds-test/test.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockProvider} from "mockprovider/MockProvider.sol";

import {Codex} from "fiat/Codex.sol";
import {IVault} from "fiat/interfaces/IVault.sol";
import {IMoneta} from "fiat/interfaces/IMoneta.sol";
import {Moneta} from "fiat/Moneta.sol";
import {FIAT} from "fiat/FIAT.sol";
import {WAD, toInt256, wmul, wdiv, sub, add} from "fiat/utils/Math.sol";

import {VaultFYActions} from "../../vault/VaultFYActions.sol";
import {Hevm} from "../utils/Hevm.sol";

contract YieldSpaceMock {
    function sellBasePreview(uint128 baseIn) external pure returns (uint128) {
        return (baseIn * 102) / 100;
    }

    function sellBase(address, uint128 min) external pure returns (uint128) {
        return (min * 102) / 100;
    }

    function sellFYTokenPreview(uint128 fyTokenIn) external pure returns (uint128) {
        return (fyTokenIn * 99) / 100;
    }

    function sellFYToken(address, uint128 min) external pure returns (uint128) {
        return (min * 99) / 100;
    }
}

contract VaultEPTActions_UnitTest is DSTest {
    MockProvider codex;
    MockProvider moneta;
    MockProvider publican;
    MockProvider mockCollateral;
    MockProvider mockVault;
    VaultFYActions VaultActions;
    MockProvider fiat;
    YieldSpaceMock yieldSpace;
    MockProvider ccp;

    Hevm internal hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address me = address(this);
    bytes32 poolId = bytes32("somePoolId");

    address internal underlierUSDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    address internal fyUSDC06 = address(0x4568bBcf929AB6B4d716F2a3D5A967a1908B4F1C); // FYUSDC06

    uint256 underlierScale = uint256(1e6);
    uint256 tokenScale = uint256(1e6);
    uint256 percentFee = 1e16;

    function setUp() public {
        fiat = new MockProvider();
        codex = new MockProvider();
        moneta = new MockProvider();
        publican = new MockProvider();
        mockCollateral = new MockProvider();
        mockVault = new MockProvider();
        ccp = new MockProvider();
        yieldSpace = new YieldSpaceMock();

        VaultActions = new VaultFYActions(address(codex), address(moneta), address(fiat), address(publican));

        mockVault.givenSelectorReturnResponse(
            IVault.token.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(fyUSDC06)}),
            false
        );

        mockVault.givenSelectorReturnResponse(
            IVault.underlierToken.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(underlierUSDC)}),
            false
        );

        mockVault.givenSelectorReturnResponse(
            IVault.underlierScale.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(uint256(1e6))}),
            false
        );

        mockVault.givenSelectorReturnResponse(
            IVault.tokenScale.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(uint256(1e6))}),
            false
        );
    }

    function test_underlierToFYToken() public {
        assertEq(VaultActions.underlierToFYToken(1e6, address(yieldSpace)), yieldSpace.sellBasePreview(1e6));
    }

    function test_fyTokenToUnderlier() public {
        assertEq(VaultActions.fyTokenToUnderlier(1e6, address(yieldSpace)), yieldSpace.sellFYTokenPreview(1e6));
    }

    function test_underlierToFYTokenOverflow() public {
        bytes memory customError = abi.encodeWithSignature("VaultFYActions__underlierToFYToken_overflow()");
        hevm.expectRevert(customError);
        VaultActions.underlierToFYToken(type(uint128).max, address(yieldSpace));
    }

    function test_fyTokenToUnderlierOverflow() public {
        bytes memory customError = abi.encodeWithSignature("VaultFYActions__fyTokenToUnderlier_overflow()");
        hevm.expectRevert(customError);
        VaultActions.fyTokenToUnderlier(type(uint128).max, address(yieldSpace));
    }
}
