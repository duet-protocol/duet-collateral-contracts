// SPDX-License-Identifier: MIT

pragma solidity 0.8.9;


import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";


import "../interfaces/IController.sol";
import "../interfaces/IDYToken.sol";
import "../interfaces/IPair.sol";
import "../interfaces/IUSDOracle.sol";
import "../interfaces/IZap.sol";
import "../interfaces/IWithdrawCallee.sol";

import '../libs/HomoraMath.sol';

import "./DepositVaultBase.sol";

// LpFarmingVault only for deposit
contract LpFarmingVault is DepositVaultBase {
  using HomoraMath for uint;
  using SafeERC20Upgradeable for IERC20Upgradeable;

  address public pair;
  address public token0;
  uint internal decimal0Scale; // no used again
  address public token1;
  uint internal decimal1Scale; // no used again

  function initialize(
    address _controller,
    address _feeConf,
    address _underlying) external initializer {
    DepositVaultBase.init(_controller, _feeConf, _underlying);
    pair = IDYToken(_underlying).underlying(); 
    
    token0 = IPair(pair).token0();
    token1 = IPair(pair).token1();
  }


  function underlyingTransferIn(address sender, uint256 amount) internal virtual override {
    IERC20Upgradeable(underlying).safeTransferFrom(sender, address(this), amount);
  }

  function underlyingTransferOut(address receipt, uint256 amount, bool) internal virtual override {
    //  skip transfer to myself
    if (receipt == address(this)) {
        return;
    }

    require(receipt != address(0), "receipt is empty");
    IERC20Upgradeable(underlying).safeTransfer(receipt, amount);
  }

  function deposit(address dtoken, uint256 amount) external virtual override {
    require(dtoken == address(underlying), "TOKEN_UNMATCH");
    underlyingTransferIn(msg.sender, amount);
    _deposit(msg.sender, amount);
  }

  function depositTo(address dtoken, address to, uint256 amount) external {
    require(dtoken == address(underlying), "TOKEN_UNMATCH");
    underlyingTransferIn(msg.sender, amount);
    _deposit(to, amount);
  }

  // call from dToken
  function syncDeposit(address dtoken, uint256 amount, address user) external virtual override {
    address vault = IController(controller).dyTokenVaults(dtoken);
    require(msg.sender == underlying && dtoken == address(underlying), "TOKEN_UNMATCH");
    require(vault == address(this), "VAULT_UNMATCH");
    _deposit(user, amount);
  }

  function withdraw(uint256 amount, bool unpack) external {
    _withdraw(msg.sender, amount, unpack);
  }

  function withdrawTo(address to, uint256 amount, bool unpack) external {
    _withdraw(to, amount, unpack);
  }

  function withdrawCall(address to, uint256 amount, bool unpack, bytes calldata data) external {
    uint actualAmount = _withdraw(to, amount, unpack);
    if (data.length > 0) {
      address asset = unpack ? pair : underlying;
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
    uint lpSupply = IERC20(pair).totalSupply();

    (uint reserve0, uint reserve1, ) = IPair(pair).getReserves();
    uint sqrtK = HomoraMath.sqrt(reserve0 * reserve1).fdiv(lpSupply);  // in 2**112
    
    // get lp amount
    uint amount = IDYToken(underlying).underlyingAmount(_amount);

    (address oracle0, uint dr0, ,
    address oracle1, uint dr1,) = IController(controller).getValueConfs(token0, token1);

    uint price0 = IUSDOracle(oracle0).getPrice(token0);
    uint price1 = IUSDOracle(oracle1).getPrice(token1);

    uint lp_price =  (sqrtK * 2 * (HomoraMath.sqrt(price0)) / (2**56)) * HomoraMath.sqrt(price1) / 2**56;

    if (dp) {
      value = lp_price * amount * (dr0 + dr1) / 2 / PercentBase / (10 ** 18);
    } else {
      value = lp_price * amount / (10 ** 18);
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

}
