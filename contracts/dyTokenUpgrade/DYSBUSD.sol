//SPDX-License-Identifier: MIT
pragma solidity 0.8.9;
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import "./DYTokenBaseUpgradeable.sol";

import "../Constants.sol";

import "../interfaces/IVault.sol";
import "../interfaces/IDepositVault.sol";
import "../interfaces/IDUSD.sol";
import "../interfaces/IPair.sol";
import "../interfaces/IRouter02.sol";
import "../interfaces/IFeeConf.sol";
import "../interfaces/IDusdMinter.sol";

contract DYSBUSD is Constants, DYTokenBaseUpgradeable {

  using SafeERC20Upgradeable for IERC20Upgradeable;

  address public BUSD;
  address public DUSD;
  address public pair;
  address public router;
  address public minter;
  IFeeConf public feeConf;
  uint public maxPriceOffset;

  bool token0IsBUSD;

  mapping(address => uint ) public debts;
  mapping(address => uint ) public lps;

  

  event FeeConfChanged(address feeconf);
  event TransferByVault(address from, address to, uint amount);

  function initialize(address _bUSD, address _dUSD, address _pair, address _router,
    address _minter, address _controller, IFeeConf _feeConf) external initializer {
    uint8 dec = IERC20MetadataUpgradeable(_bUSD).decimals();

    DYTokenBaseUpgradeable.init(address(this), "SBUSD", dec, _controller);

    BUSD = _bUSD;
    DUSD = _dUSD;
    pair = _pair;
    router = _router;
    feeConf = _feeConf;
    if (IPair(_pair).token0() == BUSD) {
      token0IsBUSD = true;
      require(IPair(_pair).token1() == DUSD);
    } else if (IPair(_pair).token0() == DUSD) {
      token0IsBUSD = false;
      require(IPair(_pair).token1() == BUSD);
    } else {
      revert("error pair");
    }

    minter = _minter;

    IERC20Upgradeable(BUSD).safeApprove(router, type(uint).max);
    IERC20Upgradeable(DUSD).safeApprove(router, type(uint).max);
    IERC20Upgradeable(pair).safeApprove(router, type(uint).max);
    IERC20Upgradeable(BUSD).safeApprove(minter, type(uint).max);

    maxPriceOffset = 5e16; // 5% 0.05
  }

  function setMaxPriceOffset(uint offset) external onlyOwner {
    maxPriceOffset = offset;
  }

  function setFeeConf(address _feeConf) external onlyOwner {
    require(_feeConf != address(0), "INVALID_FEECONF");
    feeConf = IFeeConf(_feeConf);
    emit FeeConfChanged(_feeConf);
  }

  function underlyingTotal() public override view returns (uint) {
    return totalSupply();  
  }

  function underlyingAmount(uint amount) public override view returns (uint) {
    return amount;
  }

  function balanceOfUnderlying(address _user) public override view returns (uint) {
    return balanceOf(_user);
  }

  function earn() public override {
  }
  
  function burn(uint256 amount) public override {
    withdraw(msg.sender, amount, false);
  }

  function deposit(uint _amount, address _toVault) external override {
    depositTo(msg.sender, _amount, _toVault);
  }

  function depositTo(address _to, uint _amount, address _toVault) public override {
    require(_toVault != address(0), "miss vault");
    require(_toVault == IController(controller).dyTokenVaults(address(this)), "mismatch dToken vault");
    _mint(_toVault, _amount);
    IERC20Upgradeable(BUSD).safeTransferFrom(msg.sender, address(this), _amount);
    IDepositVault(_toVault).syncDeposit(address(this), _amount, _to);

    userEarn(_to, _amount);

  }

  function withdrawByVault(address user, uint withdrawAmount, uint totalDepositsOfUser, bool onlyBUSD) public {
    require(withdrawAmount > 0, "shares need > 0");
    address vault = IController(controller).dyTokenVaults(address(this));
    require(msg.sender == vault, "not vault");

    uint totalAmountOfUser = balanceOf(user) + totalDepositsOfUser;

    _calOutputandAllocation(user, user, msg.sender, withdrawAmount, totalAmountOfUser, onlyBUSD);

  }

  function withdraw(address user, uint amount, bool onlyBUSD) public override {
    require(amount > 0, "shares need > 0");
    require(totalSupply() > 0, "no deposit");

    address withdrawUser = msg.sender;
    require(balanceOf(withdrawUser) > 0, "The user has no deposits");
    
    address vault = IController(controller).dyTokenVaults(address(this));
    uint totalAmountOfUser;
    if(vault != address(0)){
      totalAmountOfUser+= IDepositVault(vault).deposits(withdrawUser);
    }
    totalAmountOfUser += balanceOf(withdrawUser);

    _calOutputandAllocation(withdrawUser, user, withdrawUser, amount, totalAmountOfUser, onlyBUSD);
 
  }

  function transferByVault(
    address user, 
    address to, 
    uint transferAmount,
    uint totalDepositsOfUser
  ) external returns (bool) {
    address vault = IController(controller).dyTokenVaults(address(this));
    require(msg.sender == vault, "DYSBUSD Transfer: Only Vault");
    // handle debts and lps
    if(user != to) {
      uint totalAmountOfUser = balanceOf(user) + totalDepositsOfUser;
      _allocation(user, to, transferAmount, totalAmountOfUser);
    }

    // handle dysToken
    uint256 vaultBalance = _balances[vault];
    require(vaultBalance >= transferAmount, "DYSBUSD Transfer: transfer amount exceeds balance");
    unchecked {
        _balances[vault] = vaultBalance - transferAmount;
    }
    _balances[to] += transferAmount;
   
    emit TransferByVault(vault, to, transferAmount);
    return true;
  }

  function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
      uint totalAmountOfUser;
      address vault = IController(controller).dyTokenVaults(address(this));
      if(vault != address(0)){
        totalAmountOfUser+= IDepositVault(vault).deposits(from);
      }
      totalAmountOfUser += balanceOf(from);
      _allocation(from, to, amount, totalAmountOfUser);
  }

  function checkPrice(uint reserve0, uint reserve1) internal {
    require(reserve0 > 0 && reserve1 > 0, "invalid reserve");
    if(reserve0 > reserve1) {
      require(reserve0 < (reserve1 * (1e18 + maxPriceOffset) / 1e18), "mismatch price");
    } else {
      require(reserve1 < (reserve0 * (1e18 + maxPriceOffset) / 1e18), "mismatch price");
    }
  }

  function userEarn(address user, uint bUSDAmount) internal returns(uint mintAmount) {

      (uint reserve0, uint reserve1, ) = IPair(pair).getReserves();
      checkPrice(reserve0, reserve1);

      if (token0IsBUSD) {
        mintAmount = bUSDAmount * reserve1 / reserve0;
      } else {
        mintAmount = bUSDAmount * reserve0 / reserve1;
      }

      IDUSD(DUSD).mint(address(this), mintAmount);
      debts[user] += mintAmount; 

      addLiquidity(user, bUSDAmount, mintAmount);
  }

  function addLiquidity(address user, uint bUSDAmount, uint dUSDAmount) internal {

    (, , uint liquidity) = IRouter02(router).addLiquidity(BUSD, DUSD,
        bUSDAmount, dUSDAmount,
        bUSDAmount, dUSDAmount,
        address(this),
        block.timestamp);

    lps[user] += liquidity;
  }

  function removeLiquidity(uint liquidity) internal returns (uint bUSDAmount, uint dUSDAmount){
    (bUSDAmount, dUSDAmount) = IRouter02(router).removeLiquidity(BUSD, DUSD,
        liquidity, 0, 0, address(this), block.timestamp);
  }

  function swapExactUseToken(address useToken, uint amount, address wantToken ) internal {
    address[] memory path = new address[](2);
    path[0] = useToken;
    path[1] = wantToken;
    IRouter02(router).swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp);
  }

  function swapExactGetToken(address useToken, uint max, address wantToken, uint amount) internal {
    address[] memory path = new address[](2);
    path[0] = useToken;
    path[1] = wantToken;
    IRouter02(router).swapTokensForExactTokens(amount, max, path, address(this), block.timestamp);
  }
  
  function _allocation(address _user, address _to, uint _transferAmount, uint _totalAmountOfUser) internal {
    // handle debts and lps
    if (_user != address(0) && _to != address(0)) {
      uint transferDebt = debts[_user] * _transferAmount / _totalAmountOfUser;
      debts[_user] -= transferDebt;
      debts[_to] += transferDebt;

      uint transferlp = lps[_user] * _transferAmount / _totalAmountOfUser;
      lps[_user] -= transferlp;
      lps[_to] += transferlp;
    }
  }

  function _calOutputandAllocation(
    address withdrawUser,
    address to,
    address tokenOwner,
    uint withdrawAmount,
    uint totalAmountOfUser,
    bool onlyBUSD
  ) internal {
    uint lp = lps[withdrawUser] * withdrawAmount / totalAmountOfUser;
    uint debt = debts[withdrawUser] * withdrawAmount / totalAmountOfUser;

    (uint bUSDAmount, uint dUSDAmount) = removeLiquidity(lp);
    lps[withdrawUser] -= lp;

    if (dUSDAmount > debt) {
      if (onlyBUSD) {
        swapExactUseToken(DUSD, dUSDAmount - debt, BUSD);
      }
    } else { //  dUSDAmount <= debt
      uint needDusdAmount = debt - dUSDAmount;
      if (bUSDAmount >= dUSDAmount) { // dUSD price >= 1
        (uint needBUSDAmount, ) = IDusdMinter(minter).calcInputFee(needDusdAmount);
        IDusdMinter(minter).mineDusd(needBUSDAmount, needDusdAmount, address(this));
      } else { // dUSD price < 1
        // bUSD swap to dUSD 
        swapExactGetToken(BUSD, bUSDAmount, DUSD, needDusdAmount);
      }
    }

    IDUSD(DUSD).burn(debt);
    debts[withdrawUser] -= debt;

    _burn(tokenOwner, withdrawAmount);

    (address feeReceiver, uint wdFee) = feeConf.getConfig("dybusd_wd");
    if (wdFee > 0 && feeReceiver != address(0)) {
      uint fee = withdrawAmount * wdFee / PercentBase;
      IERC20Upgradeable(BUSD).safeTransfer(feeReceiver, fee);
    }

    uint256 busdBalance = IERC20Upgradeable(BUSD).balanceOf(address(this));
    IERC20Upgradeable(BUSD).safeTransfer(to, busdBalance);

    uint256 dusdBalance = IERC20Upgradeable(DUSD).balanceOf(address(this));
    if (dusdBalance > 0) {
      IERC20Upgradeable(DUSD).safeTransfer(to, dusdBalance);
    }
  }
 

}