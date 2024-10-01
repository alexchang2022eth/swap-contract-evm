// SPDX-License-Identifier: MIT

pragma solidity >= 0.8.0;

import "../contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IWETH is IERC20Upgradeable {
    /// @notice Deposit ether to get wrapped ether
    function deposit() external payable;

    /// @notice Withdraw wrapped ether to get ether
    function withdraw(uint256) external;
}
