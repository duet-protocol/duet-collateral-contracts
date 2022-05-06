

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IDusdMinter {
    function dusd() external view returns(address);
    function stableToken() external view returns(address);
    function mineDusd(uint amount, uint minDusd, address to) external returns(uint amountOut);
    function calcInputFee(uint amountOut) external view returns (uint amountIn, uint fee);
}