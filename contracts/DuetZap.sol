// SPDX-License-Identifier: MIT
pragma solidity >= 0.8.0;
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./interfaces/IPair.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IRouter02.sol";
import "./interfaces/IPancakeFactory.sol";
import "./interfaces/IController.sol";
import "./interfaces/IDYToken.sol";
import "./interfaces/IDusdMinter.sol";


contract DuetZap is OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IRouter02 private router;
    IPancakeFactory private factory;
    address private wbnb;
    IController public controller;

    event ZapToLP(address token, uint amount, address lp, uint liquidity);

    /* ========== STATE VARIABLES ========== */
    mapping(address => address) private routePairAddresses;

    address public minter;

    /* ========== INITIALIZER ========== */
    function initialize(address _controller, address _factory, address _router, address _wbnb) external initializer {
        __Ownable_init();
        require(owner() != address(0), "Zap: owner must be set");
        controller = IController(_controller);
        factory = IPancakeFactory(_factory);
        router = IRouter02(_router);
        wbnb = _wbnb;
    }

    receive() external payable {}

    /* ========== View Functions ========== */

    function routePair(address _address) external view returns(address) {
        return routePairAddresses[_address];
    }

    /* ========== External Functions ========== */
    function setMinter(address _minter) external onlyOwner {
        minter = _minter;
    }

    function tokenToLp(address _token, uint amount, address _lp, bool needDeposit) external {
        address receiver = msg.sender;
        if (needDeposit) {
           receiver = address(this);
        }
        IERC20Upgradeable(_token).safeTransferFrom(msg.sender, address(this), amount);
        _approveTokenIfNeeded(_token, address(router), amount);

        IPair pair = IPair(_lp);
        address token0 = pair.token0();
        address token1 = pair.token1();
        require(factory.getPair(token0, token1) == _lp, "NO_PAIR");

        uint liquidity;

        if (_token == token0 || _token == token1) {
            // swap half amount for other
            address other = _token == token0 ? token1 : token0;
            _approveTokenIfNeeded(other, address(router), amount);
            uint sellAmount = amount / 2;

            uint otherAmount = _swap(_token, sellAmount, other, address(this));
            pair.skim(address(this));

            (, , liquidity) = router.addLiquidity(_token, other, amount - sellAmount, otherAmount, 0, 0, receiver, block.timestamp);
        } else {
            uint bnbAmount = _token == wbnb ? amount : _swapTokenForBNB(_token, amount, address(this), false);
            require(IERC20Upgradeable(wbnb).balanceOf(address(this)) >= bnbAmount, "Zap: Not enough wbnb balance");
            liquidity = _swapBNBToLp(_lp, bnbAmount, receiver, false);
        }

        emit ZapToLP(_token, amount, _lp, liquidity);
        if (needDeposit) {
          deposit(_lp, liquidity, msg.sender);
        }

    }

    function tokenToLpbyPath(
        address _token, 
        uint amount, 
        address _lp, 
        bool needDeposit,
        address [] memory pathArr0,
        address [] memory pathArr1
    ) external {
        require(amount > 0, "Zero Amount");
        
        IERC20Upgradeable(_token).safeTransferFrom(msg.sender, address(this), amount);

        _approveTokenIfNeeded(_token, address(router), amount);

        uint liquidity = _zapToLPbyPath(_token, amount, _lp, needDeposit, pathArr0, pathArr1);

    }

    function coinToLp(address _lp, bool needDeposit) external payable returns (uint liquidity){
        if (!needDeposit) {
          liquidity = _swapBNBToLp(_lp, msg.value, msg.sender, true);
          emit ZapToLP(address(0), msg.value, _lp, liquidity);
        } else {
          liquidity = _swapBNBToLp(_lp, msg.value, address(this), true);
          emit ZapToLP(address(0), msg.value, _lp, liquidity);
          deposit(_lp, liquidity, msg.sender);
        }
    }

    function coinToLpbyPath(
        address _lp, 
        bool needDeposit,
        address [] memory pathArr0,
        address [] memory pathArr1
    ) external payable returns (uint liquidity){
        require(msg.value > 0, "Zap: coin zero");
        IWETH(wbnb).deposit{value: msg.value}();
        uint wbnbAmount = msg.value;
        _approveTokenIfNeeded(wbnb, address(router), wbnbAmount);
        liquidity = _zapToLPbyPath(wbnb, wbnbAmount, _lp, needDeposit, pathArr0, pathArr1);
    }

    function coinToToken(address _token, bool needDeposit) external payable returns (uint amountOut) {
       if (!needDeposit) {
        amountOut = _swapBNBForToken(_token, msg.value, msg.sender, true);
       } else {
        amountOut = _swapBNBForToken(_token, msg.value, address(this), true); 
        deposit(_token, amountOut, msg.sender);
      }
    }

    function coinToTokenbyPath(
        bool needDeposit,
        address[] memory pathArr
    ) external payable returns (uint amountOut) {

        require(pathArr.length > 1, "Wrong Path: length of pathArr should exceed 1");
        address _from = pathArr[0];
        require(_from == wbnb, "Wrong Path: First item of PathArr should be WBNB!");
        
        IWETH(wbnb).deposit{value: msg.value}();
        uint wbnbAmount = msg.value;

        _approveTokenIfNeeded(_from, address(router), wbnbAmount);

        address _to;
        if (needDeposit) {
            (_to, amountOut) = _swapbyPath(_from, wbnbAmount, pathArr, address(this));
            deposit(_to, amountOut, msg.sender);
        } else {
            (_to, amountOut) = _swapbyPath(_from, wbnbAmount, pathArr, msg.sender);
        }
    }

    function tokenToToken(address _token, uint _amount, address _to, bool needDeposit) external returns (uint amountOut){
      IERC20Upgradeable(_token).safeTransferFrom(msg.sender, address(this), _amount);
      _approveTokenIfNeeded(_token, address(router), _amount);
      
      if (needDeposit) {
        amountOut = _swap(_token, _amount, _to, address(this));
        deposit(_to, amountOut, msg.sender);
      } else {
        amountOut = _swap(_token, _amount, _to, msg.sender);
      }
    }

    function tokenToTokenbyPath(
        uint _amount, 
        bool needDeposit,
        address[] memory pathArr
    ) external returns (uint amountOut){
        require(pathArr.length > 1, "Wrong Path: length of pathArr should exceed 1");
        address _from = pathArr[0];
        IERC20Upgradeable(_from).safeTransferFrom(msg.sender, address(this), _amount);
        _approveTokenIfNeeded(_from, address(router), _amount);

        address _to;
        if (needDeposit) {
            (_to, amountOut) = _swapbyPath(_from, _amount, pathArr, address(this));
            deposit(_to, amountOut, msg.sender);
        } else {
            (_to, amountOut) = _swapbyPath(_from, _amount, pathArr, msg.sender);
        }
    }

    // unpack lp 
    function zapOut(address _from, uint _amount) external {
        IERC20Upgradeable(_from).safeTransferFrom(msg.sender, address(this), _amount);
        _approveTokenIfNeeded(_from, address(router), _amount);

        IPair pair = IPair(_from);
        address token0 = pair.token0();
        address token1 = pair.token1();

        if (pair.balanceOf(_from) > 0) {
            pair.burn(address(this));
        }

        if (token0 == wbnb || token1 == wbnb) {
            router.removeLiquidityETH(token0 != wbnb ? token0 : token1, _amount, 0, 0, msg.sender, block.timestamp);
        } else {
            router.removeLiquidity(token0, token1, _amount, 0, 0, msg.sender, block.timestamp);
        }
    }

    /* ========== Private Functions ========== */
    function deposit(address token, uint amount, address toUser) private {
        address dytoken = controller.dyTokens(token);
        require(dytoken != address(0), "NO_DYTOKEN");
        address vault = controller.dyTokenVaults(dytoken);
        require(vault != address(0), "NO_VAULT");

        _approveTokenIfNeeded(token, dytoken, amount);
        IDYToken(dytoken).depositTo(toUser, amount, vault);
    }

    function _approveTokenIfNeeded(address token, address spender, uint amount) private {
        uint allowed = IERC20Upgradeable(token).allowance(address(this), spender);
        if (allowed == 0) {
            IERC20Upgradeable(token).safeApprove(spender, type(uint).max);
        } else if (allowed < amount) {
          IERC20Upgradeable(token).safeApprove(spender, 0);
          IERC20Upgradeable(token).safeApprove(spender, type(uint).max);
        }
                    
    }

    function _swapBNBToLp(address lp, uint amount, address receiver, bool byBNB) private returns (uint liquidity) {
        IPair pair = IPair(lp);
        address token0 = pair.token0();
        address token1 = pair.token1();
        if (token0 == wbnb || token1 == wbnb) {
            address token = token0 == wbnb ? token1 : token0;
            uint tokenAmount = _swapBNBForToken(token, amount / 2, address(this), byBNB);
            _approveTokenIfNeeded(token, address(router), tokenAmount);
            pair.skim(address(this));
            if (byBNB) {
                // BNB to LP
                (, , liquidity) = router.addLiquidityETH{value : amount - amount / 2 }(token, tokenAmount, 0, 0, receiver, block.timestamp);
            } else {
                // WBNB to LP
                (, , liquidity) = router.addLiquidity(wbnb, token, amount - amount / 2, tokenAmount, 0, 0, receiver, block.timestamp);
            }
            
        } else {
            uint token0Amount = _swapBNBForToken(token0, amount / 2, address(this), byBNB);
            uint token1Amount = _swapBNBForToken(token1, amount - amount / 2, address(this), byBNB);

            _approveTokenIfNeeded(token0, address(router), token0Amount);
            _approveTokenIfNeeded(token1, address(router), token1Amount);
            pair.skim(address(this));
            (, , liquidity) = router.addLiquidity(token0, token1, token0Amount, token1Amount, 0, 0, receiver, block.timestamp);
        }
    }

    function _swapBNBForToken(address token, uint value, address receiver, bool byBNB) private returns (uint) {
        address[] memory path;

        if (routePairAddresses[token] != address(0)) {
            path = new address[](3);
            path[0] = wbnb;
            path[1] = routePairAddresses[token];
            path[2] = token;
        } else {
            path = new address[](2);
            path[0] = wbnb;
            path[1] = token;
        }

        uint[] memory amounts;
        if (byBNB) {
            // BNB to other Token
            amounts = router.swapExactETHForTokens{value : value}(0, path, receiver, block.timestamp);
        } else {
            // WBNB to other Token
            _approveTokenIfNeeded(wbnb, address(router), value);
            amounts = router.swapExactTokensForTokens(value, 0, path, receiver, block.timestamp); 
        }
        return amounts[amounts.length - 1];
    }

    function _swapTokenForBNB(address token, uint amount, address receiver, bool byBNB) private returns (uint) {
        address[] memory path;
        if (routePairAddresses[token] != address(0)) {
            path = new address[](3);
            path[0] = token;
            path[1] = routePairAddresses[token];
            path[2] = wbnb;
        } else {
            path = new address[](2);
            path[0] = token;
            path[1] = wbnb;
        }

        uint[] memory amounts;
        if (byBNB) {
            // Token to BNB
            amounts = router.swapExactTokensForETH(amount, 0, path, receiver, block.timestamp);
        } else {
            // Token to WBNB
            amounts = router.swapExactTokensForTokens(amount, 0, path, receiver, block.timestamp); 
        }
         
        return amounts[amounts.length - 1];
    }

    function _checkAmountOutbyPath(
        address _lp, 
        address _token0,
        address _token1,
        uint _amountOutbyPath0,
        uint _amountOutbyPath1
    ) private {
        IPair pair = IPair(_lp);
        address token0 = pair.token0();
        address token1 = pair.token1();

        require(factory.getPair(token0, token1) == _lp, "Zap: NO_PAIR");
        require(_amountOutbyPath0 > 0 && _amountOutbyPath1 > 0, "Wrong Path: amountOut is zero");
        require(_token0 != _token1, "Zap: target tokens should't be the same");
        require(_token0 == token0 || _token0 == token1, "Wrong Path: target tokens don't match");
        require(_token1 == token0 || _token1 == token1, "Wrong Path: target tokens don't match");
    }

    function _checkAmountOut(uint amount, address[] memory path) private returns (uint amountOut){
 
        try router.getAmountsOut(amount, path) returns (uint[] memory amounts) {
                amountOut = amounts[amounts.length - 1];
        } catch {}

    }

    function _calSuitablePath(
        uint amount, 
        address _from, 
        address intermediate, 
        address _to
    ) private returns (address[] memory pathOut){
        
        address[] memory pathL2 = new address[](2);
        pathL2[0] = _from;
        pathL2[1] = _to;
        address[] memory pathL3 = new address[](3);
        pathL3[0] = _from;
        pathL3[1] = intermediate;
        pathL3[2] = _to;

        uint amountOutL2 = _checkAmountOut(amount, pathL2);
        uint amountOutL3 = _checkAmountOut(amount, pathL3);

        require(amountOutL2 > 0 || amountOutL3 >0, "Wrong Path: amountOutLX is zero");
        return amountOutL2 > amountOutL3? pathL2 : pathL3;

    }

    function _swap(address _from, uint amount, address _to, address receiver) private returns (uint) {
        if (minter != address(0) && IDusdMinter(minter).stableToken() == _from && IDusdMinter(minter).dusd() == _to) {
            uint output = _mineDusd(_from, amount);
            return output;
        }
        
        address intermediate = routePairAddresses[_from];
        if (intermediate == address(0)) {
            intermediate = routePairAddresses[_to];
        }

        address[] memory path;
        if (intermediate == address(0) || _from == intermediate || _to == intermediate ) {
            // [DUET, BUSD] or [BUSD, DUET]
            path = new address[](2);
            path[0] = _from;
            path[1] = _to;
            uint amountOut = _checkAmountOut(amount, path);
            require(amountOut != 0, "Wrong Path: amountOut is zero");
        } else {
            path = _calSuitablePath(amount, _from, intermediate, _to);
        }

        uint[] memory amounts = router.swapExactTokensForTokens(amount, 0, path, receiver, block.timestamp);
        return amounts[amounts.length - 1];
    }

    function _swapbyPath(
        address _from, 
        uint amount, 
        address [] memory pathArr,
        address receiver
    ) private returns (address _to, uint amountOut) {
        if (pathArr.length == 0) {
            return (_from, amount);
        }

        require(pathArr.length > 1, "Wrong path: one path");
        require(_from == pathArr[0], "Wrong path: swapped token not in pathArr");
        require(minter != address(0), "Should set DusdMinter");

        // check busd -> dusd
        for (uint i = 0; i < pathArr.length; i++) {
            if(pathArr[i] == IDusdMinter(minter).stableToken() && i < pathArr.length - 1) {
                if(pathArr[i+1] == IDusdMinter(minter).dusd()) {
                    return _swapPathArrofStableTokentoDUSD(pathArr, i, amount);
                }
            }
        }

        uint[] memory amounts = router.swapExactTokensForTokens(amount, 0, pathArr, receiver, block.timestamp);
        return (pathArr[amounts.length - 1], amounts[amounts.length - 1]);

    }

    function _swapPathArrofStableTokentoDUSD(
        address[] memory pathArr, 
        uint position,
        uint amount
        ) private returns(address _to, uint amountOut) {
        uint len = pathArr.length;

        // len = 2, busd -> dusd
        if(len == 2) {
            amountOut = _mineDusd(pathArr[0], amount);
            return (pathArr[1], amountOut);
        }

        // len > 2, ...busd -> dusd...
        if(position == 0) {
            // busd -> dusd, and then swap [dusd, ...]
            uint dusdAmount = _mineDusd(pathArr[position], amount);
            address[] memory newPathArr = new address[](len-1);
            newPathArr = _fillArrbyPosition(1, len-1, pathArr);
            uint[] memory amounts = router.swapExactTokensForTokens(dusdAmount, 0, newPathArr, address(this), block.timestamp);
            return (newPathArr[newPathArr.length - 1], amounts[amounts.length - 1]);
        }else if(position == len - 2) {
            // swap [..., busd], and then busd -> dusd
            address[] memory newPathArr = new address[](len-1);
            newPathArr = _fillArrbyPosition(0, len-2, pathArr);
            uint[] memory amounts = router.swapExactTokensForTokens(amount, 0, newPathArr, address(this), block.timestamp);
            uint dusdAmount = _mineDusd(pathArr[position], amounts[amounts.length - 1]);
            return (pathArr[pathArr.length - 1], dusdAmount);
        } else {
            // swap [..., busd], and then busd -> dusd, and swap [dusd, ...]
            address[] memory newPathArr0 = new address[](position+1);
            address[] memory newPathArr1 = new address[](len-position-1);
            newPathArr0 = _fillArrbyPosition(0, position, pathArr);
            newPathArr1 = _fillArrbyPosition(position+1, len-1, pathArr);
            uint[] memory amounts0 = router.swapExactTokensForTokens(amount, 0, newPathArr0, address(this), block.timestamp);
            uint dusdAmount = _mineDusd(pathArr[position], amounts0[amounts0.length - 1]);
            uint[] memory amounts1 = router.swapExactTokensForTokens(dusdAmount, 0, newPathArr1, address(this), block.timestamp);
            return (pathArr[pathArr.length - 1], amounts1[amounts1.length - 1]);
        }
    }

    function _mineDusd(address _from, uint amount) private returns (uint amountOut) {
        _approveTokenIfNeeded(_from, minter, amount);
        amountOut = IDusdMinter(minter).mineDusd(amount, 0, address(this));
    }

    function _fillArrbyPosition(
        uint start,
        uint end,
        address[] memory originArr
    ) private returns (address[] memory) {
        uint newLen = end-start+1;
        address[] memory newArr = new address[](newLen);
        for (uint i = 0; i < newLen; i++) {
            newArr[i] = originArr[i+start];
        }
        return newArr;
    }

    
    function _safeSwapToBNB(uint amount) private returns (uint) {
        require(IERC20Upgradeable(wbnb).balanceOf(address(this)) >= amount, "Zap: Not enough wbnb balance");
        uint beforeBNB = address(this).balance;
        IWETH(wbnb).withdraw(amount);
        return address(this).balance - beforeBNB;
    }

    function _zapToLPbyPath(
        address _token, 
        uint amount, 
        address _lp, 
        bool needDeposit, 
        address [] memory pathArr0,
        address [] memory pathArr1
    ) private returns(uint liquidity) {
        address receiver = msg.sender;
        if (needDeposit) {
           receiver = address(this);
        }
        (address _token0 ,uint _amountOutbyPath0) = _swapbyPath(_token, amount / 2, pathArr0, address(this));
        (address _token1 ,uint _amountOutbyPath1) = _swapbyPath(_token, amount - amount / 2, pathArr1, address(this));
        _checkAmountOutbyPath(_lp, _token0, _token1, _amountOutbyPath0, _amountOutbyPath1);
        
        _approveTokenIfNeeded(_token0, address(router), _amountOutbyPath0);
        _approveTokenIfNeeded(_token1, address(router), _amountOutbyPath1);
        (, , liquidity) = router.addLiquidity(_token0, _token1, _amountOutbyPath0, _amountOutbyPath1, 0, 0, receiver, block.timestamp);

        if (needDeposit) {
            deposit(_lp, liquidity, msg.sender);
        } 
        emit ZapToLP(_token, amount, _lp, liquidity);
        return liquidity;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setRoutePairAddress(address asset, address route) public onlyOwner {
        routePairAddresses[asset] = route;
    }

    function sweep(address[] memory tokens, bool byBNB) external onlyOwner {
        for (uint i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            if (token == address(0)) continue;
            uint amount = IERC20Upgradeable(token).balanceOf(address(this));
            if (amount > 0) {
                _swapTokenForBNB(token, amount, owner(), byBNB);
            }
        }
    }

    function withdraw(address token) external onlyOwner {
        if (token == address(0)) {
            payable(owner()).transfer(address(this).balance);
            return;
        }

        IERC20Upgradeable(token).transfer(owner(), IERC20Upgradeable(token).balanceOf(address(this)));
    }

}