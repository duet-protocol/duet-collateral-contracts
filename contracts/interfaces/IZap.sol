pragma solidity >=0.8.0;

interface IZap {
    function lpToToken(address _lp, uint _amount, address _token, address _toUser,  uint minAmout) external returns (uint amount);
    
    function tokenToLpbyPath(
        address _token, 
        uint amount, 
        address _lp, 
        bool needDeposit,
        address [] memory pathArr0,
        address [] memory pathArr1
    ) external;
    
}