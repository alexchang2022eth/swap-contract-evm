// SPDX-License-Identifier: MIT

pragma solidity >= 0.8.0;

import "./openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import "./openzeppelin-contracts/interfaces/IERC20.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./libs/UniswapV2Library.sol";
import "./interfaces/IWETH.sol";
import "./libs/SafeMath.sol";
import "./libs/Path.sol";
import "./libs/TickMath.sol";
import "./libs/SafeCast.sol";
import "./libs/PoolAddress.sol";
import "./Storage.sol";
import "./SwapBase.sol";

library SwapV3 { 

    address internal constant WETH = SwapBase.WETH;
    address internal constant factoryV3 = SwapBase.factoryV3;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputParams {
        bytes path;
        address tokenIn;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    struct ExactInputMixedParams {
        string[] routes;
        bytes path1;
        address factory1;
        bytes path2;
        address factory2;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputMixedParams {
        string[] routes;
        bytes path1;
        address factory1;
        bytes path2;
        address factory2;
        uint256 amountIn2; // only for v2-v3 router
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    struct SwapCallbackData {
        bytes path;
        address payer;
    }

    struct CacheStruct {
        uint256 amountInCached;
    }

    using SafeMath for uint;
    using Path for bytes;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;


    modifier checkDeadline(uint256 deadline) {
        require(block.timestamp <= deadline, 'Transaction too old');
        _;
    }

    function cacheStorage() internal pure returns (CacheStruct storage cache) {
        bytes32 position = keccak256("swapv3.amountin.cache.storage");
        assembly { cache.slot := position }
    }


    // V3: ExactIn single-hop 
    function swapV3ExactIn (
            ExactInputSingleParams memory params
    ) external checkDeadline(params.deadline) returns (uint256 amountOut) {

        require(params.amountIn > 0, "BOT: amount in is zero");

        if (params.tokenIn == WETH) {
            require(msg.value >= params.amountIn, "BOT: amount in and value mismatch");
            // refund
            uint amount = msg.value - params.amountIn;
            if (amount > 0) {
              (bool success, ) = address(msg.sender).call{value: amount}("");
              require(success, "BOT: refund ETH error");
            }
        }

        bool nativeOut = false;
        if (params.tokenOut == WETH) 
            nativeOut = true;

        if (!nativeOut) {
            uint256 fee = SwapBase.takeFee(params.tokenIn, params.amountIn);
            params.amountIn = params.amountIn - fee;
        }

        amountOut = exactInputInternal(
            params.amountIn,
            nativeOut ? address(0) : params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({path: abi.encodePacked(params.tokenIn, params.fee, params.tokenOut), payer: msg.sender})
        );

        require(amountOut >= params.amountOutMinimum, "BOT: insufficient out amount");

        if (nativeOut) {
            IWETH(WETH).withdraw(amountOut);
            uint256 fee = SwapBase.takeFee(address(0), amountOut);
            (bool success, ) = address(params.recipient).call{value: amountOut-fee}("");
            require(success, "BOT: send ETH out error");
        }
    }

    // V3: ExactOut single-hop 
    function swapV3ExactOut (
        ExactOutputSingleParams memory params
    ) public checkDeadline(params.deadline) returns (uint256 amountIn) {

        require(params.amountInMaximum > 0, "BOT: amount in max is zero");

        CacheStruct storage cache = cacheStorage();

        bool nativeIn = false;
        if (params.tokenIn == WETH) {
            nativeIn = true;
            require(msg.value >= params.amountInMaximum, "BOT: amount in max and value mismatch");
        }

        bool nativeOut = false;
        if (params.tokenOut == WETH) 
            nativeOut = true;

        uint256 fee = 0;
        if (!nativeOut) {
            fee = SwapBase.takeFee(params.tokenIn, amountIn);
            require(amountIn + fee <= params.amountInMaximum, "BOT: too much requested");
        }

        amountIn = exactOutputInternal(
            params.amountOut,
            nativeOut ? address(0) : params.recipient,
            params.sqrtPriceLimitX96,
            SwapCallbackData({path: abi.encodePacked(params.tokenOut, params.fee, params.tokenIn), payer: msg.sender})
        );

        if (nativeIn) {
            uint amount = msg.value - amountIn - fee;
            // refund
            if (amount > 0) {
                (bool success, ) = address(msg.sender).call{value: amount}("");
                require(success, "BOT: refund ETH error");
            }
        } 

        if (nativeOut) {
            IWETH(WETH).withdraw(params.amountOut);
            fee = SwapBase.takeFee(address(0), params.amountOut);

            (bool success, ) = address(params.recipient).call{value: params.amountOut - fee}("");
            require(success, "BOT: send ETH out error");
        }

        cache.amountInCached = type(uint256).max; 
    }

    // V3-V3: ExactIn multi-hop 
    function swapV3MultiHopExactIn (
        ExactInputParams memory params
    ) public checkDeadline(params.deadline) returns (uint256 amountOut) {

        require(params.amountIn > 0, "BOT: amount in is zero");
        if (msg.value > 0) {
            require(msg.value >= params.amountIn, "BOT: amount in and value mismatch");
            // refund
            uint amount = msg.value - params.amountIn;
            if (amount > 0) {
              (bool success, ) = address(msg.sender).call{value: amount}("");
              require(success, "BOT: refund ETH error");
            }
        }

        (address tokenIn, , ) = params.path.decodeFirstPool();
        if (tokenIn == WETH) {
            uint256 fee = SwapBase.takeFee(tokenIn, params.amountIn);
            params.amountIn = params.amountIn - fee;
        }

        address payer = msg.sender; // msg.sender pays for the first hop

        bool nativeOut = false;
        while (true) {
            bool hasMultiplePools = params.path.hasMultiplePools();

            if (!hasMultiplePools) {
                (,address tokenOut,) = params.path.decodeFirstPool();
                if (tokenOut == WETH)
                    nativeOut = true;
            }
            // the outputs of prior swaps become the inputs to subsequent ones
            params.amountIn = exactInputInternal(
                params.amountIn,
                hasMultiplePools ? address(this) : (nativeOut ? address(this) : params.recipient), 
                0,
                SwapCallbackData({
                    path: params.path.getFirstPool(), 
                    payer: payer
                })
            );

            // decide whether to continue or terminate
            if (hasMultiplePools) {
                payer = address(this); // at this point, the caller has paid
                params.path = params.path.skipToken();
            } else {
                amountOut = params.amountIn;
                break;
            }
        }
        require(amountOut >= params.amountOutMinimum, 'BOT: too little received');

        if (nativeOut) {
            IWETH(WETH).withdraw(amountOut);
            uint256 fee = SwapBase.takeFee(address(0), amountOut);

            (bool success, ) = address(params.recipient).call{value: amountOut - fee}("");
            require(success, "BOT: send ETH out error");
        }

    }

    // V3-V3: ExactOut multi-hop 
    function swapV3MultiHopExactOut(
        ExactOutputParams memory params
    ) external checkDeadline(params.deadline) returns (uint256 amountIn) {

        require(params.amountInMaximum > 0, "BOT: amount in max is zero");
        if (msg.value > 0)
            require(msg.value >= params.amountInMaximum, "BOT: amount in max and value mismatch");

        CacheStruct storage cache = cacheStorage();

        bool nativeOut = false;
        (address tokenOut, , ) = params.path.decodeFirstPool();
        if (tokenOut == WETH)
            nativeOut = true;

        uint256 fee = 0;
        if (!nativeOut) {
            fee = SwapBase.takeFee(params.tokenIn, amountIn);
            require(amountIn + fee <= params.amountInMaximum, 'BOT: too much requested');
        }

        exactOutputInternal(
            params.amountOut,
            nativeOut ? address(this) : params.recipient,
            0,
            SwapCallbackData({path: params.path, payer: msg.sender})
        );

        amountIn = cache.amountInCached;

        if (params.tokenIn == WETH) {
            if (msg.value > 0) {
                // refund
                uint256 amount = msg.value - amountIn - fee;
                if (amount > 0) {
                    (bool success, ) = address(msg.sender).call{value: amount}("");
                    require(success, "BOT: refund ETH error");
                }
            }
        }

        if (nativeOut) {
            IWETH(WETH).withdraw(params.amountOut);
            fee = SwapBase.takeFee(address(0), params.amountOut);
            (bool success, ) = address(params.recipient).call{value: params.amountOut-fee}("");
            require(success, "BOT: send ETH out error");
        }

        cache.amountInCached = type(uint256).max;
    }

    function isStrEqual(string memory str1, string memory str2) internal pure returns(bool) {
        return keccak256(bytes(str1)) == keccak256(bytes(str2));
    }

    // Mixed: ExactIn multi-hop, token not supporting zero address 
    function swapMixedMultiHopExactIn (
        ExactInputMixedParams memory params
    ) public checkDeadline(params.deadline) returns (uint256 amountOut) {

        require(params.routes.length == 2, "BOT: only 2 routes supported");

        require(params.amountIn > 0, "BOT: amount in is zero");

        (address tokenIn, address tokenOut1, uint24 fee1) = params.path1.decodeFirstPool();

        bool nativeIn = false;
        if (tokenIn == WETH) {
            require(msg.value >= params.amountIn, "BOT: amount in and value mismatch");
            nativeIn = true;
            tokenIn = WETH;
            // refund
            uint amount = msg.value - params.amountIn;
            if (amount > 0) {
              (bool success, ) = address(msg.sender).call{value: amount}("");
              require(success, "BOT: refund ETH error");
            }
            uint256 fee = SwapBase.takeFee(address(0), params.amountIn);
            params.amountIn = params.amountIn - fee;
        }

        if (isStrEqual(params.routes[0], "v2") && isStrEqual(params.routes[1], "v2")) {
            // uni - sushi, or verse
            address poolAddress1 = UniswapV2Library.pairFor(params.factory1, tokenIn, tokenOut1);
            if (nativeIn) {
                SwapBase.pay(tokenIn, address(this), poolAddress1, params.amountIn);
            } else
                SwapBase.pay(tokenIn, msg.sender, poolAddress1, params.amountIn);

            address[] memory path1 = new address[](2);
            path1[0] = tokenIn;
            path1[1] = tokenOut1;

            (, address tokenOut,) = params.path2.decodeFirstPool();
            address[] memory path2 = new address[](2); 
            path2[0] = tokenOut1;
            path2[1] = tokenOut;
            address poolAddress2 = UniswapV2Library.pairFor(params.factory2, tokenOut1, tokenOut);

            bool nativeOut = tokenOut == WETH;

            uint balanceBefore = IERC20(tokenOut).balanceOf(params.recipient);
            SwapBase._swapSupportingFeeOnTransferTokens(path1, poolAddress2, params.factory1);
            SwapBase._swapSupportingFeeOnTransferTokens(path2, nativeOut ? address(this) : params.recipient, params.factory2);
            amountOut = IERC20(tokenOut).balanceOf(params.recipient).sub(balanceBefore);
            if (nativeOut) {
                IWETH(WETH).withdraw(amountOut);
                uint256 fee = SwapBase.takeFee(address(0), amountOut);
                (bool success, ) = address(params.recipient).call{value: amountOut-fee}("");
                require(success, "BOT: send ETH out error");
            }
        } else if (isStrEqual(params.routes[0], "v2") && isStrEqual(params.routes[1], "v3")) {
            address poolAddress1 = UniswapV2Library.pairFor(params.factory1, tokenIn, tokenOut1);
            if (nativeIn) {
                SwapBase.pay(tokenIn, address(this), poolAddress1, params.amountIn);
            } else
                SwapBase.pay(tokenIn, msg.sender, poolAddress1, params.amountIn);

            address[] memory path1 = new address[](2);
            path1[0] = tokenIn;
            path1[1] = tokenOut1;
            uint[] memory amounts1 = UniswapV2Library.getAmountsOut(params.factory1, params.amountIn, path1);
            uint amountOut1 = amounts1[amounts1.length-1];

            (, address tokenOut,) = params.path2.decodeFirstPool();
            bool nativeOut = tokenOut == WETH;
            uint balanceBefore = IERC20(tokenOut).balanceOf(nativeOut ? address(this) : params.recipient);
            SwapBase._swapSupportingFeeOnTransferTokens(path1, address(this), params.factory1);

            amountOut = exactInputInternal(
                amountOut1,
                nativeOut ? address(this) : params.recipient, 
                0,
                SwapCallbackData({
                    path: params.path2, 
                    payer: address(this) 
                })
            );
            amountOut = IERC20(tokenOut).balanceOf(nativeOut ? address(this) : params.recipient).sub(balanceBefore);
            if (nativeOut) {
                IWETH(WETH).withdraw(amountOut);
                uint256 fee = SwapBase.takeFee(address(0), amountOut);
                (bool success, ) = address(params.recipient).call{value: amountOut-fee}("");
                require(success, "BOT: send ETH out error");
            }
        } else if (isStrEqual(params.routes[0], "v3") && isStrEqual(params.routes[1], "v2")) {
            (address tokenIn2, address tokenOut,) = params.path2.decodeFirstPool();
            address pairV2Address = UniswapV2Library.pairFor(params.factory2, tokenIn2, tokenOut);

            uint amountOut1 = exactInputInternal(
                params.amountIn,
                pairV2Address, 
                0,
                SwapCallbackData({
                    path: abi.encodePacked(tokenIn, fee1, tokenOut1), 
                    payer: msg.sender 
                })
            );

            address[] memory path2 = new address[](2); 
            path2[0] = tokenIn2;
            path2[1] = tokenOut;
            uint[] memory amounts2 = UniswapV2Library.getAmountsOut(params.factory2, amountOut1, path2);
            amountOut = amounts2[amounts2.length - 1];

            bool nativeOut = tokenOut == WETH;
            uint balanceBefore = IERC20(tokenOut).balanceOf(nativeOut ? address(this) : params.recipient);
            SwapBase._swapSupportingFeeOnTransferTokens(path2, nativeOut ? address(this) : params.recipient, params.factory2);
            amountOut = IERC20(tokenOut).balanceOf(nativeOut ? address(this) : params.recipient).sub(balanceBefore);
            if (nativeOut) {
                IWETH(WETH).withdraw(amountOut);
                uint256 fee = SwapBase.takeFee(address(0), amountOut);
                (bool success, ) = address(params.recipient).call{value: amountOut-fee}("");
                require(success, "BOT: send ETH out error");
            }
        } 

        require(amountOut >= params.amountOutMinimum, 'BOT: too little received');
    }

    // Mixed: ExactOut multi-hop 
    function swapMixedMultiHopExactOut(
        ExactOutputMixedParams memory params
    ) external checkDeadline(params.deadline) returns (uint256 amountIn) {

        require(params.amountInMaximum > 0, "BOT: amount in max is zero");
        if (msg.value > 0)
            require(msg.value >= params.amountInMaximum, "BOT: amount in max and value mismatch");

        (address tokenIn, address tokenOut1,) = params.path1.decodeFirstPool();
        (, address tokenOut,) = params.path2.decodeFirstPool();

        bool nativeIn = tokenIn == WETH;
        bool nativeOut = tokenOut == WETH;

        if (isStrEqual(params.routes[0], "v2") && isStrEqual(params.routes[1], "v2")) {
            // uni - sushi, or verse
            address poolAddress1 = UniswapV2Library.pairFor(params.factory1, tokenIn, tokenOut1);

            address poolAddress2 = UniswapV2Library.pairFor(params.factory2, tokenOut1, tokenOut);
            address[] memory path2 = new address[](2);
            path2[0] = tokenOut1;
            path2[1] = tokenOut;
            uint[] memory amounts2 = UniswapV2Library.getAmountsIn(params.factory2, params.amountOut, path2);

            address[] memory path1 = new address[](2);
            path1[0] = tokenIn;
            path1[1] = tokenOut1;
            uint[] memory amounts1 = UniswapV2Library.getAmountsIn(params.factory1, amounts2[0], path1);
            amountIn = amounts1[0];

            if (nativeIn) {
                SwapBase.pay(tokenIn, address(this), poolAddress1, amountIn);
            } else
                SwapBase.pay(tokenIn, msg.sender, poolAddress1, amountIn);

            uint256 balanceBefore = IERC20(tokenOut).balanceOf(nativeOut ? address(this) : params.recipient);
            SwapBase._swap(amounts1, path1, poolAddress2, params.factory1);

            SwapBase._swap(amounts2, path2, nativeOut ? address(this) : params.recipient, params.factory2);
            uint256 amountOut = IERC20(tokenOut).balanceOf(nativeOut ? address(this) : params.recipient).sub(balanceBefore);
            if (nativeOut) {
                IWETH(WETH).withdraw(amountOut);
                uint256 fee = SwapBase.takeFee(address(0), amountOut);
                (bool success, ) = address(params.recipient).call{value: amountOut-fee}("");
                require(success, "BOT: send ETH out error");
            }

        } else if (isStrEqual(params.routes[0], "v2") && isStrEqual(params.routes[1], "v3")) {
            // NOTE: v3 not support fee-on-transfer token, so the mid-token amountIn is exactly same as params.amountIn2 
            // v3 path bytes is reversed
            (tokenOut, ,) = params.path2.decodeFirstPool();

            uint256 balanceBefore = IERC20(tokenOut).balanceOf(nativeOut ? address(this) : params.recipient);

            address poolAddress1 = UniswapV2Library.pairFor(params.factory1, tokenIn, tokenOut1);
            address[] memory path1 = new address[](2);
            path1[0] = tokenIn;
            path1[1] = tokenOut1;
            uint[] memory amounts1 = UniswapV2Library.getAmountsIn(params.factory1, params.amountIn2, path1);
            amountIn = amounts1[0];
            if (nativeIn) {
                SwapBase.pay(tokenIn, address(this), poolAddress1, amountIn);
            } else
                SwapBase.pay(tokenIn, msg.sender, poolAddress1, amountIn);

            SwapBase._swap(amounts1, path1, address(this), params.factory1);

            uint amountIn2 = exactOutputInternal(
                params.amountOut,
                params.recipient,
                0,
                SwapCallbackData({path: params.path2, payer: address(this)})
            );
            require(amountIn2 == params.amountIn2, "BOT: not support fee-on-transfer token for V3");

            uint256 amountOut = IERC20(tokenOut).balanceOf(nativeOut ? address(this) : params.recipient).sub(balanceBefore);
            if (nativeOut) {
                IWETH(WETH).withdraw(amountOut);
                uint256 fee = SwapBase.takeFee(address(0), amountOut);
                (bool success, ) = address(params.recipient).call{value: amountOut-fee}("");
                require(success, "BOT: send ETH out error");
            }
        } else if (isStrEqual(params.routes[0], "v3") && isStrEqual(params.routes[1], "v2")) {

            (tokenOut1, tokenIn,) = params.path1.decodeFirstPool();

            address[] memory path2 = new address[](2); 
            path2[0] = tokenOut1;
            path2[1] = tokenOut;
            address poolAddress1 = UniswapV2Library.pairFor(params.factory2, tokenOut1, tokenOut);
            uint[] memory amounts2 = UniswapV2Library.getAmountsIn(params.factory2, params.amountOut, path2);
            uint amountIn2 = amounts2[0];

            uint256 balanceBefore = IERC20(tokenOut).balanceOf(nativeOut ? address(this) : params.recipient);
            amountIn = exactOutputInternal(
                amountIn2,
                poolAddress1,
                0,
                SwapCallbackData({path: params.path1, payer: msg.sender})
            );

            SwapBase._swap(amounts2, path2, params.recipient, params.factory2);
            uint256 amountOut = IERC20(tokenOut).balanceOf(nativeOut ? address(this) : params.recipient).sub(balanceBefore);
            if (nativeOut) {
                IWETH(WETH).withdraw(amountOut);
                uint256 fee = SwapBase.takeFee(address(0), amountOut);
                (bool success, ) = address(params.recipient).call{value: amountOut-fee}("");
                require(success, "BOT: send ETH out error");
            }
        } 

        if (nativeIn) {
            uint256 fee = SwapBase.takeFee(tokenIn, amountIn);
            require(amountIn + fee <= params.amountInMaximum, "BOT: too much requested");

            if (msg.value > 0) {
              uint amount = msg.value - amountIn - fee;
              // refund
              if (amount > 0) {
                  (bool success, ) = address(msg.sender).call{value: amount}("");
                  require(success, "BOT: refund ETH error");
              }
            }
        }
    }

    // V3: compute pool address
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) internal pure returns (IUniswapV3Pool) {
        return IUniswapV3Pool(PoolAddress.computeAddress(factoryV3, PoolAddress.getPoolKey(tokenA, tokenB, fee)));
    }

    /// V3: Performs a single exact input swap
    function exactInputInternal(
        uint256 amountIn,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) private returns (uint256 amountOut) {
        // allow swapping to the router address with address 0
        if (recipient == address(0)) recipient = address(this);

        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0, int256 amount1) =
            getPool(tokenIn, tokenOut, fee).swap(
                recipient,
                zeroForOne,
                amountIn.toInt256(),
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96,
                abi.encode(data)
            );

        return uint256(-(zeroForOne ? amount1 : amount0));
    }

    /// Performs a single exact output swap
    function exactOutputInternal(
        uint256 amountOut,
        address recipient,
        uint160 sqrtPriceLimitX96,
        SwapCallbackData memory data
    ) internal returns (uint256 amountIn) {
        // allow swapping to the router address with address 0
        if (recipient == address(0)) recipient = address(this);

        (address tokenOut, address tokenIn, uint24 fee) = data.path.decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;

        (int256 amount0Delta, int256 amount1Delta) =
            getPool(tokenIn, tokenOut, fee).swap(
                recipient,
                zeroForOne,
                -amountOut.toInt256(),
                sqrtPriceLimitX96 == 0
                    ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                    : sqrtPriceLimitX96,
                abi.encode(data)
            );

        uint256 amountOutReceived;
        (amountIn, amountOutReceived) = zeroForOne
            ? (uint256(amount0Delta), uint256(-amount1Delta))
            : (uint256(amount1Delta), uint256(-amount0Delta));
        // it's technically possible to not receive the full output amount,
        // so if no price limit has been specified, require this possibility away
        if (sqrtPriceLimitX96 == 0) require(amountOutReceived == amountOut);
    }
}
