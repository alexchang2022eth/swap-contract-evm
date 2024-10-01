// SPDX-License-Identifier: MIT

pragma solidity >= 0.8.0;

import "./interfaces/IWETH.sol";
import "./interfaces/IUniswapV2Pair.sol";
import "./libs/UniswapV2Library.sol";
import "./libs/SafeMath.sol";
import "./SwapBase.sol";

library SwapV2 {

    using SafeMath for uint;

    address internal constant WETH = SwapBase.WETH;

    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, 'Transaction too old');
        _;
    }

    // V2: Any swap, ExactIn single-hop - SupportingFeeOnTransferTokens
    function swapV2ExactIn (
        address tokenIn, 
        address tokenOut, 
        uint256 amountIn, 
        uint256 amountOutMin, 
        address poolAddress
    ) external returns (uint amountOut) {

        require(poolAddress != address(0), "BOT: invalid pool address");
        require(amountIn > 0, "BOT: amout in is zero");

        bool nativeIn = false;
        if (tokenIn == address(0)) {
            require(msg.value >= amountIn, "BOT: amount in and value mismatch");
            nativeIn = true;
            tokenIn = WETH;
            // refund
            uint amount = msg.value - amountIn;
            if (amount > 0) {
              (bool success, ) = address(msg.sender).call{value: amount}("");
              require(success, "BOT: refund ETH error");
            }
        }
        bool nativeOut = false;
        if (tokenOut == address(0))
            nativeOut = true;

        if (!nativeOut) {
            uint256 fee = SwapBase.takeFee(tokenIn, amountIn);
            amountIn = amountIn - fee;
        }

        if (nativeIn) {
            SwapBase.pay(tokenIn, address(this), poolAddress, amountIn);
        } else
            SwapBase.pay(tokenIn, msg.sender, poolAddress, amountIn);


        uint balanceBefore = nativeOut ? 
            IERC20Upgradeable(WETH).balanceOf(address(this)) :  IERC20Upgradeable(tokenOut).balanceOf(msg.sender);
        
        IUniswapV2Pair pair = IUniswapV2Pair(poolAddress);
        address token0 = pair.token0();
        uint amountInput;
        uint amountOutput;
        { // scope to avoid stack too deep errors
            (uint reserve0, uint reserve1,) = pair.getReserves();
            (uint reserveInput, uint reserveOutput) = tokenIn == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            amountInput = IERC20Upgradeable(tokenIn).balanceOf(address(pair)).sub(reserveInput);
            amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
        }
        (uint amount0Out, uint amount1Out) = tokenIn == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
        address to = nativeOut ? address(this) : msg.sender;
        pair.swap(amount0Out, amount1Out, to, new bytes(0));

        if (nativeOut) {
            amountOut = IERC20Upgradeable(WETH).balanceOf(address(this)).sub(balanceBefore);
            IWETH(WETH).withdraw(amountOut);
            uint256 fee = SwapBase.takeFee(address(0), amountOut);
            (bool success, ) = address(msg.sender).call{value: amountOut-fee}("");
            require(success, "BOT: send ETH out error");
        } else {
            amountOut = IERC20Upgradeable(tokenOut).balanceOf(msg.sender).sub(balanceBefore);
        }
        require(
            amountOut >= amountOutMin,
            'BOT: insufficient output amount'
        );
    }

    // V2: Any swap, ExactOut single-hop - * not support fee-on-transfer tokens *
    function swapV2ExactOut (
        address tokenIn, 
        address tokenOut, 
        uint256 amountInMax, 
        uint256 amountOut, 
        address poolAddress
     ) external returns (uint amountIn){

        require(poolAddress != address(0), "BOT: invalid pool address");
        require(amountInMax > 0, "BOT: amout in max is zero");

        bool nativeIn = false;
        if (tokenIn == address(0)) {
            tokenIn = WETH;
            nativeIn = true;
            require(msg.value >= amountInMax, "BOT: amount in and value mismatch");
        }

        bool nativeOut = false;
        if (tokenOut == address(0)) 
            nativeOut = true;

        IUniswapV2Pair pair = IUniswapV2Pair(poolAddress);
        address token0 = pair.token0();
        { // scope to avoid stack too deep errors
            (uint256 reserve0, uint256 reserve1,) = pair.getReserves();
            (uint256 reserveInput, uint256 reserveOutput) = tokenIn == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            amountIn = UniswapV2Library.getAmountIn(amountOut, reserveInput, reserveOutput);

            uint256 fee = 0;
            if (!nativeOut) {
                fee = SwapBase.takeFee(tokenIn, amountIn);
                require(amountIn + fee <= amountInMax, "BOT: excessive input amount");
            }

            if(nativeIn) {
                SwapBase.pay(tokenIn, address(this), poolAddress, amountIn);
                uint256 amount = msg.value - amountIn - fee;
                // refund
                if (amount > 0) {
                    (bool success, ) = address(msg.sender).call{value: amount}("");
                    require(success, "BOT: refund ETH error");
                }
            } else { 
                SwapBase.pay(tokenIn, msg.sender, poolAddress, amountIn);
            }
        }
        (uint256 amount0Out, uint256 amount1Out) = tokenIn == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        address to = nativeOut ? address(this) : msg.sender;
        pair.swap(amount0Out, amount1Out, to, new bytes(0));

        if (nativeOut) {
            IWETH(WETH).withdraw(amountOut);
            uint256 fee = SwapBase.takeFee(address(0), amountOut);
            (bool success, ) = address(msg.sender).call{value: amountOut-fee}("");
            require(success, "BOT: send ETH out error");
        }
    }


    // V2-V2: Uniswap/Sushiswap, SupportingFeeOnTransferTokens and multi-hop
    function swapV2MultiHopExactIn(
        address tokenIn,
        uint256 amountIn, 
        uint256 amountOutMin, 
        address[] calldata path, 
        address recipient,
        uint deadline,
        address factory
    ) external checkDeadline(deadline) returns (uint[] memory amounts){

        require(amountIn > 0, "BOT: amout in is zero");

        bool nativeIn = false;
        if (tokenIn == address(0)) {
            require(msg.value >= amountIn, "BOT: amount in and value mismatch");
            nativeIn = true;
            tokenIn = WETH;
            // refund
            uint amount = msg.value - amountIn;
            if (amount > 0) {
              (bool success, ) = address(msg.sender).call{value: amount}("");
              require(success, "BOT: refund ETH error");
            }
        }

        bool nativeOut = false;
        address tokenOut = path[path.length-1];
        if (tokenOut == WETH) {
            nativeOut = true;
        }

        if (!nativeOut) {
            uint256 fee = SwapBase.takeFee(tokenIn, amountIn);
            amountIn = amountIn - fee;
        }

        address firstPool = UniswapV2Library.pairFor(factory, path[0], path[1]);
        if (nativeIn) {
            SwapBase.pay(tokenIn, address(this), firstPool, amountIn);
        } else
            SwapBase.pay(tokenIn, msg.sender, firstPool, amountIn);
        require(tokenIn == path[0], "invalid path");

        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);

        uint balanceBefore = IERC20Upgradeable(tokenOut).balanceOf(nativeOut ? address(this) : recipient);
        SwapBase._swapSupportingFeeOnTransferTokens(path, nativeOut ? address(this) : recipient, factory);
        uint amountOut = IERC20Upgradeable(tokenOut).balanceOf(nativeOut ? address(this) : recipient).sub(balanceBefore);
        amounts[path.length - 1] = amountOut;
        require(
            amountOut >= amountOutMin,
            'BOT: insufficient output amount'
        );

        if (nativeOut) {
            IWETH(WETH).withdraw(amountOut);
            uint256 fee = SwapBase.takeFee(address(0), amountOut);
            (bool success, ) = address(recipient).call{value: amountOut-fee}("");
            require(success, "BOT: send ETH out error");
        }
    }

    // V2-V2: Uniswap, ExactOut multi-hop, not support fee-on-transfer token in output
    function swapV2MultiHopExactOut(
        address tokenIn, 
        uint256 amountInMax, 
        uint256 amountOut, 
        address[] calldata path, 
        address recipient,
        uint deadline,
        address factory
    ) public checkDeadline(deadline) returns (uint[] memory amounts){

        require(amountInMax > 0, "BOT: amount in max is zero");

        bool nativeIn = false;
        if (tokenIn == address(0)) {
            nativeIn = true;
            tokenIn = WETH;
            require(msg.value >= amountInMax, "BOT: amount in and value mismatch");
        }

        bool nativeOut = false;
        address tokenOut = path[path.length-1];
        if (tokenOut == WETH)
            nativeOut = true;

        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);

        uint256 fee = 0;
        if (!nativeOut) {
            fee = SwapBase.takeFee(tokenIn, amounts[0]);
            require(amounts[0] + fee <= amountInMax, 'BOT: excessive input amount');
        }

        address firstPool = UniswapV2Library.pairFor(factory, path[0], path[1]);
        if (nativeIn) {
            SwapBase.pay(tokenIn, address(this), firstPool, amounts[0]);
            uint amount = msg.value - amounts[0] - fee;
            // refund
            if (amount > 0) {
                (bool success, ) = address(msg.sender).call{value: amount}("");
                require(success, "BOT: refund ETH error");
            }
        } else
            SwapBase.pay(tokenIn, msg.sender, firstPool, amounts[0]);


        SwapBase._swap(amounts, path, nativeOut ? address(this) : recipient, factory);

        if (nativeOut) {
            IWETH(WETH).withdraw(amountOut);
            fee = SwapBase.takeFee(address(0), amountOut);
            (bool success, ) = address(recipient).call{value: amountOut-fee}("");
            require(success, "BOT: send ETH out error");
        }
    }
}
