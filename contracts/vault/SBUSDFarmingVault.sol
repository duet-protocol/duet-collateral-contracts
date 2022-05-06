// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";


import "../interfaces/IController.sol";
import "../interfaces/IDYSToken.sol";
import "../interfaces/IPair.sol";
import "../interfaces/IUSDOracle.sol";
import "../interfaces/IWithdrawCallee.sol";

import "./DepositVaultBase.sol";

// SBUSDFarmingVault only for deposit
contract SBUSDFarmingVault is DepositVaultBase {

  using SafeERC20Upgradeable for IERC20Upgradeable;

  address public underlyingToken;
  uint internal underlyingScale;

  function initialize(
    address _controller,
    address _feeConf,
    address _underlying) external initializer {
    DepositVaultBase.init(_controller, _feeConf, _underlying);
    underlyingToken = IDYSToken(_underlying).underlying(); 
    
    uint decimal = IERC20Metadata(underlyingToken).decimals();
    underlyingScale = 10 ** decimal;
  }


  function underlyingTransferIn(address sender, uint256 amount) internal virtual override {}

  function underlyingTransferOut(address receipt, uint256 amount, bool) internal virtual override {}

  function deposit(address dytoken, uint256 amount) external virtual override {}

  function depositTo(address dytoken, address to, uint256 amount) external {}

  // call from dToken
  function syncDeposit(address dytoken, uint256 amount, address user) external virtual override {
    address vault = IController(controller).dyTokenVaults(dytoken);
    require(msg.sender == underlying && dytoken == address(underlying), "TOKEN_UNMATCH");
    require(vault == address(this), "VAULT_UNMATCH");
    _deposit(user, amount);
  }

  function withdraw(uint256 amount, bool unpack) external {
    _withdraw(msg.sender, amount, unpack, false);
  }

  function withdrawOnlyBUSD(uint256 amount, bool unpack, bool onlyBUSD) external {
    _withdraw(msg.sender, amount, unpack, onlyBUSD);
  }

  function withdrawTo(address to, uint256 amount, bool unpack) external {
    require(msg.sender == to, "WITHDRAW_USER_UNMATCH");
    _withdraw(to, amount, unpack, false);
  }

  function withdrawCall(address to, uint256 amount, bool unpack, bytes calldata data) external {
    require(msg.sender == to, "WITHDRAW_USER_UNMATCH");
    uint actualAmount = _withdraw(to, amount, unpack, false);
    if (data.length > 0) {
      address asset = unpack ? underlyingToken : underlying;
      IWithdrawCallee(to).execCallback(msg.sender, asset, actualAmount, data);
    }
  }

  function liquidate(address liquidator, address borrower, bytes calldata data) external override {
    _liquidate(liquidator, borrower, data);
  }

  function underlyingAmountValue(uint _amount, bool dp) public view returns(uint value) {
    if(_amount == 0) {
      return 0;
    }
    uint amount = IDYSToken(underlying).underlyingAmount(_amount);


    (address oracle, uint dr,  ) = IController(controller).getValueConf(underlyingToken);

    uint price = IUSDOracle(oracle).getPrice(underlyingToken);

    if (dp) { 
      value = (amount * price * dr / PercentBase / underlyingScale);
    } else {
      value = (amount * price / underlyingScale);
    }
  }

  /**
    @notice 用户 Vault 价值估值
    @param dp Discount 或 Premium
  */
  function userValue(address user, bool dp) external override view returns(uint) {
    if(deposits[user] == 0) {
      return 0;
    }
    return underlyingAmountValue(deposits[user], dp);
  }

  // amount > 0 : deposit
  // amount < 0 : withdraw  
  function pendingValue(address user, int amount) external override view returns(uint) {
    if (amount >= 0) {
      return underlyingAmountValue(deposits[user] + uint(amount), true);
    } else {
      return underlyingAmountValue(deposits[user] - uint(0 - amount), true);
    }
  }
  
  function _deposit(address supplyer, uint256 amount) internal override  nonReentrant {
    require(amount > 0, "DEPOSITE_IS_ZERO");
    IController(controller).beforeDeposit(supplyer, address(this), amount);

    deposits[supplyer] += amount;
    emit Deposit(supplyer, amount);
    _updateJoinStatus(supplyer);

    if (address(farm) != address(0)) {
      farm.syncDeposit(supplyer, amount, underlying);
    }
  }

  /**
    @notice 取款
    @dev 提现转给指定的接受者 to 
    @param amount 提取数量
    @param unpack 是否解包underlying
    @param onlyBUSD 用户withdraw的资产是否只接收BUSD, false表示允许接收BUSD和DUSD两种
    */
  function _withdraw(
      address to,
      uint256 amount,
      bool unpack,
      bool onlyBUSD
  ) internal nonReentrant returns (uint256 actualAmount) {
      address redeemer = msg.sender;
      uint totalDepositsOfRedeemer = deposits[redeemer];
      require(totalDepositsOfRedeemer >= amount, "INSUFFICIENT_DEPOSIT");
      IController(controller).beforeWithdraw(redeemer, address(this), amount);

      deposits[redeemer] -= amount;
      emit Withdraw(redeemer, amount);
      _updateJoinStatus(redeemer);

      if (address(farm) != address(0)) {
        farm.syncWithdraw(redeemer, amount, underlying);
      }

      IDYSToken(underlying).withdrawByVault(to, amount, totalDepositsOfRedeemer, onlyBUSD);
      return amount;
  }

  /**
    * @notice 清算账户资产
    * @param liquidator 清算人
    * @param borrower 借款人
    */
  function _liquidate(
    address liquidator, 
    address borrower, 
    bytes calldata data
  ) internal override nonReentrant{
    require(msg.sender == controller, "LIQUIDATE_INVALID_CALLER");
    require(liquidator != borrower, "LIQUIDATE_DISABLE_YOURSELF");

    uint256 supplies = deposits[borrower];


    //获得抵押品
    if (supplies > 0) {
      uint256 toLiquidatorAmount = supplies;
      IDYSToken(underlying).transferByVault(borrower, liquidator, toLiquidatorAmount, supplies); 
      if (data.length > 0) ILiquidateCallee(liquidator).liquidateDeposit(borrower, underlying, toLiquidatorAmount, data);
    }

    deposits[borrower] = 0;
    emit Liquidated(liquidator, borrower, supplies);
    _updateJoinStatus(borrower);

    if (address(farm) != address(0)) {
      farm.syncLiquidate(borrower, underlying);
    }
  }

}
