//SPDX-License-Identifier: MIT
pragma solidity 0.8.9;

import "./draft-ERC20PermitUpgradeable.sol";

import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

import "../interfaces/TokenRecipient.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IDYToken.sol";
import "../interfaces/IController.sol";

abstract contract DYTokenBaseUpgradeable is IDYToken, ERC20PermitUpgradeable, OwnableUpgradeable {
  using AddressUpgradeable for address;

  address public underlying;
  uint8 internal dec;
  address public controller;

  event SetController(address controller);

  constructor() {
  }

  function init(address _underlying, 
    string memory _symbol, uint8 _dec, 
    address _controller) internal {
        __Context_init_unchained();
        __Ownable_init_unchained();
        __ERC20_init("DYToken", string(abi.encodePacked("DY-", _symbol)));
        __ERC20Permit_init("DYToken");

        underlying = _underlying;
        dec = _dec;
        controller = _controller;
    }

  function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {

  }

  function decimals() public view virtual override returns (uint8) {
    return dec;
  }

  function burn(uint256 amount) public virtual {
    _burn(msg.sender, amount);
  }

  function send(address recipient, uint256 amount, bytes calldata exData) external returns (bool) {
    _transfer(msg.sender, recipient, amount);

    if (recipient.isContract()) {
      bool rv = TokenRecipient(recipient).tokensReceived(msg.sender, amount, exData);
      require(rv, "No tokensReceived");
    }

    return true;
  }

  // ====== Controller ======
  function setController(address _controller) public onlyOwner {
    require(_controller != address(0), "INVALID_CONTROLLER");
    controller = _controller;
    emit SetController(_controller);
  }

  // ====== yield functions  =====

  // total hold
  function underlyingTotal() public virtual view returns (uint);

  function underlyingAmount(uint amount) public virtual override view returns (uint);

  function balanceOfUnderlying(address _user) public virtual override view returns (uint);

    // 单位净值
  function pricePerShare() public view returns (uint price) {
    if (totalSupply() > 0) {
      return underlyingTotal() * 1e18 / totalSupply();
    }
  }

  function depositTo(address _to, uint _amount, address _toVault) public virtual;

  // for native coin
  function depositCoin(address _to, address _toVault) public virtual payable {
  }

  function depositAll(address _toVault) external virtual {
    address user = msg.sender;
    depositTo(user, IERC20Upgradeable(underlying).balanceOf(user), _toVault);
  }

  // withdraw underlying asset, brun dyTokens
  function withdraw(address _to, uint _shares, bool needETH) public virtual;

  function withdrawAll() external virtual {
      withdraw(msg.sender, balanceOf(msg.sender), true);
  }

  // transfer all underlying asset to yield strategy
  function earn() public virtual;

}