//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IMasterChefV2 {
  function CAKE() external view returns (address) ;
  function poolLength() external view returns (uint256);

  function cakePerBlock(bool _isRegular) external view returns (uint256);

  function lpToken(uint pid) external view returns (address );
  function poolInfo(uint pid) external view returns (uint256 accCakePerShare, uint256 lastRewardBlock, uint256 allocPoint, uint256 totalBoostedShare, bool isRegular);
  function userInfo(uint pid, address user) external view returns (uint amount, uint rewardDebt, uint256 boostMultiplier);
  
  // View function to see pending SUSHIs on frontend.
  function pendingCake(uint256 _pid, address _user) external view returns (uint256);
  
  function deposit(uint256 _pid, uint256 _amount) external;
  function withdraw(uint256 _pid, uint256 _amount) external;
  function emergencyWithdraw(uint256 _pid) external;
}