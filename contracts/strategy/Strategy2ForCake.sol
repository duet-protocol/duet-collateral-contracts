  // SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import  "../interfaces/IPair.sol";
import  "../interfaces/ICakePool.sol";
import  "../interfaces/IRouter02.sol";

import  "./BaseStrategy.sol";

// stake Cake earn cake.
contract Strategy2ForCake is BaseStrategy {
  using SafeERC20 for IERC20;

  address public immutable cakepool;

  constructor(address _controller, address _fee, address _cakepool) 
    BaseStrategy(_controller, _fee, ICakePool(_cakepool).token(), ICakePool(_cakepool).token()) {
    cakepool = _cakepool;
    IERC20(output).safeApprove(cakepool, type(uint).max);
  }

  function balanceOfPool() public virtual override view returns (uint) {
    (uint userShares, , , , , , , ,) = ICakePool(cakepool).userInfo(address(this));
    uint pricePerFullShare = ICakePool(cakepool).getPricePerFullShare();
    uint amount = userShares * pricePerFullShare / 1e18;  
    return amount;
  }

  function pendingOutput() external virtual override view returns (uint) {
    (uint userShares, , uint cakeAtLastUserAction, , , , , ,) = ICakePool(cakepool).userInfo(address(this));
    uint pricePerFullShare = ICakePool(cakepool).getPricePerFullShare();
    uint amount = userShares * pricePerFullShare / 1e18 - cakeAtLastUserAction;
    return amount;
  }

  function deposit() public virtual override {
    uint dAmount = IERC20(want).balanceOf(address(this));
    if (dAmount > 0) {
      ICakePool(cakepool).deposit(dAmount, 0);
      emit Deposit(dAmount);
    }
  }

  // only call from dToken 
  function withdraw(uint _amount) external virtual override {
    address dToken = IController(controller).dyTokens(want);
    require(msg.sender == dToken, "invalid caller");

    uint dAmount = IERC20(want).balanceOf(address(this));
    if (dAmount < _amount) {
      ICakePool(cakepool).withdrawByAmount(_amount - dAmount);
    }

    safeTransfer(want, dToken, _amount);  // lp transfer to dToken
    emit Withdraw(_amount);
  }

  // should used for reset strategy
  function withdrawAll() external virtual override returns (uint balance) {
    address dToken = IController(controller).dyTokens(want);
    require(msg.sender == controller || msg.sender == dToken, "invalid caller");

    (uint userShares, , , , , , , ,) = ICakePool(cakepool).userInfo(address(this));
    if(userShares > 0){
      ICakePool(cakepool).withdrawAll();
      uint balance = IERC20(want).balanceOf(address(this));
      IERC20(want).safeTransfer(dToken, balance);
      emit Withdraw(balance);
    }
  }

  function emergency() external override onlyOwner {
    ICakePool(cakepool).withdrawAll();

    uint amount = IERC20(want).balanceOf(address(this));
    address dToken = IController(controller).dyTokens(want);

    if (dToken != address(0)) {
      IERC20(want).safeTransfer(dToken, amount);
    } else {
      IERC20(want).safeTransfer(owner(), amount);
    }
    emit Withdraw(amount);
  }

  function harvest() public virtual override {}

  function sendYieldFee(uint liquidity) internal returns (uint fee) {
    (address feeReceiver, uint yieldFee) = feeConf.getConfig("yield_fee");

    fee = liquidity * yieldFee / PercentBase;
    if (fee > 0) {
      IERC20(want).safeTransfer(feeReceiver, fee);
    }
  }

}