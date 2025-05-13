// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

interface ITridentVault {
    event TransferApproval(address indexed owner, address indexed operator, bool approved);

    // View functions
    function wETH() external view returns (address);
    function balanceOf(address token, address account) external view returns (uint256 balance);
    function reserves(address token) external view returns (uint256);

    // Core functions
    function deposit(address token, address to) external payable returns (uint256 amount);
    function depositETH(address to) external payable returns (uint256 amount);
    function transferAndDeposit(address token, address to, uint256 amount) external payable returns (uint256);
    
    // Transfer functions
    function transfer(address token, address to, uint256 amount) external;
    function transferFrom(address token, address from, address to, uint256 amount) external;
    function approveTransfer(address operator, bool approved) external;

    // Withdraw functions
    function withdraw(address token, address to, uint256 amount) external;
    function withdrawETH(address to, uint256 amount) external;
    function withdrawAlternative(
        address token, 
        address to, 
        uint256 amount, 
        uint8 mode  // 0 = DEFAULT, 1 = UNWRAPPED, 2 = WRAPPED
    ) external;

    // Flash loan functions (如果繼承了 VaultFlashLoans)
    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external;

    // Native token handling
    receive() external payable;
}