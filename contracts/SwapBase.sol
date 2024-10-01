// SPDX-License-Identifier: MIT
// utils for swap library

pragma solidity >=0.8.0;

import "./openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import "./openzeppelin-contracts/interfaces/IERC20.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./libs/UniswapV2Library.sol";
import "./libs/SafeMath.sol";
import "./libs/SafeCast.sol";

library SwapBase {

    using SafeMath for uint;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    address internal constant WETH = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9; // sepolia
    address internal constant factoryV3 = 0x0227628f3F023bb0B980b67D528571c95c6DaC1c;  // sepolia
    address internal constant feeCollector = 0x0007f5E78c05E730834F2AC07d5Fc335920c5000;
    uint256 internal constant feeRate = 100;
    uint256 internal constant feeDenominator = 10000;

    event FeeCollected(address indexed token, address indexed payer, uint256 amount, uint256 timestamp);

    function takeFee(
        address tokenIn, 
        uint256 amountIn 
    ) internal returns (uint256) {

        uint256 fee = amountIn * feeRate / feeDenominator;

        if ((tokenIn == address(0) || tokenIn == WETH) && address(this).balance > fee) {
            (bool success, ) = address(feeCollector).call{ value: fee }("");
            require(success, "take fee failed");
        } else {
            IERC20(tokenIn).safeTransferFrom(msg.sender, feeCollector, fee);
        }

        emit FeeCollected(tokenIn, msg.sender, fee, block.timestamp);
        return fee; 
    }

    function pay(
        address token,
        address payer,
        address recipient,
        uint256 value
    ) internal {
        if (token == WETH && address(this).balance >= value) {
            // pay with WETH
            IWETH(WETH).deposit{value: value}(); // wrap only what is needed to pay
            IWETH(WETH).transfer(recipient, value);
        } else if (payer == address(this)) {
            // pay with tokens already in the contract (for the exact input multihop case)
            IERC20(token).safeTransfer(recipient, value);
        } else {
            // pull payment
            IERC20(token).safeTransferFrom(payer, recipient, value);
        }
    }

    // **** SWAP ****
    // requires the initial amount to have already been sent to the first pair
    function _swap(uint[] memory amounts, address[] memory path, address _to, address _factory) internal {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            uint amountOut = amounts[i + 1];
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(_factory, output, path[i + 2]) : _to;
            IUniswapV2Pair(UniswapV2Library.pairFor(_factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0)
            );
        }
    }

    // **** SWAP (supporting fee-on-transfer tokens) ****
    // requires the initial amount to have already been sent to the first pair
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to, address _factory) internal {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);
            IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(_factory, input, output));
            uint amountInput;
            uint amountOutput;
            { // scope to avoid stack too deep errors
                (uint reserve0, uint reserve1,) = pair.getReserves();
                (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
                amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);
                amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
            address to = i < path.length - 2 ? UniswapV2Library.pairFor(_factory, output, path[i + 2]) : _to;
            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }
}
