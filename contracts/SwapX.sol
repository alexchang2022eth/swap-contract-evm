// SPDX-License-Identifier: MIT

pragma solidity >= 0.8.0;

import "./contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./contracts-upgradeable/security/PausableUpgradeable.sol";
import "./contracts-upgradeable/proxy/utils/Initializable.sol";
import "./interfaces/IUniswapV3SwapCallback.sol";
import "./libs/CallbackValidation.sol";
import "./libs/Path.sol";
import "./SwapV2.sol";
import "./SwapV3.sol";

contract SwapX is IUniswapV3SwapCallback, Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable 
{

    struct CacheStruct {
        uint256 amountInCached;
    }

    using Path for bytes;

    mapping(bytes4 => address) public functionToLibrary;

    receive() external payable {}

    function initialize (
        address _swapV2,
        address _swapV3
    ) public initializer {
        __Ownable_init(msg.sender);
        __ReentrancyGuard_init();
        __Pausable_init();

        // Mapping function selectors to library addresses
        functionToLibrary[this.swapV2ExactIn.selector] = _swapV2;
        functionToLibrary[this.swapV2ExactOut.selector] = _swapV2;
        functionToLibrary[this.swapV2MultiHopExactIn.selector] = _swapV2;
        functionToLibrary[this.swapV2MultiHopExactOut.selector] = _swapV2;
        functionToLibrary[this.swapV3ExactIn.selector] = _swapV3;
        functionToLibrary[this.swapV3ExactOut.selector] = _swapV3;
        functionToLibrary[this.swapV3MultiHopExactIn.selector] = _swapV3;
        functionToLibrary[this.swapV3MultiHopExactOut.selector] = _swapV3;
        functionToLibrary[this.swapMixedMultiHopExactIn.selector] = _swapV3;
        functionToLibrary[this.swapMixedMultiHopExactOut.selector] = _swapV3;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setFunctionToLibrary(bytes4 _signature, address _libAddress) external onlyOwner {
        require(_libAddress != address(0), "invalid library addr");
        functionToLibrary[_signature] = _libAddress;
    }

    fallback() external nonReentrant whenNotPaused {
        address libraryAddress = functionToLibrary[msg.sig];
        require(libraryAddress != address(0), "Function not found");

        assembly {
            let _calldata := calldatasize()
            calldatacopy(0x0, 0x0, _calldata)

            // Forward the call using delegatecall
            let result := delegatecall(gas(), libraryAddress, 0x0, _calldata, 0, 0)

            // Load the return data size
            let returndata_size := returndatasize()

            // Copy the returned data
            returndatacopy(0x0, 0x0, returndata_size)

            // Conditional return
            switch result
            case 0 { revert(0x0, returndata_size) }
            default { return(0x0, returndata_size) }
        }
    }

    // Declare the available functions to expose their selectors.
    function swapV2ExactIn (
        address tokenIn, 
        address tokenOut, 
        uint256 amountIn, 
        uint256 amountOutMin, 
        address poolAddress
    ) payable external returns (uint amountOut) {}

    function swapV2ExactOut (
        address tokenIn, 
        address tokenOut, 
        uint256 amountInMax, 
        uint256 amountOut, 
        address poolAddress
     ) external returns (uint amountIn) {}

    function swapV2MultiHopExactIn(
        address tokenIn,
        uint256 amountIn, 
        uint256 amountOutMin, 
        address[] calldata path, 
        address recipient,
        uint deadline,
        address factory
    ) external returns (uint[] memory amounts) {}

    function swapV2MultiHopExactOut(
        address tokenIn, 
        uint256 amountInMax, 
        uint256 amountOut, 
        address[] calldata path, 
        address recipient,
        uint deadline,
        address factory
    ) public returns (uint[] memory amounts) {}

    function swapV3ExactIn (
            SwapV3.ExactInputSingleParams memory params
    ) external returns (uint256 amountOut) {}

    function swapV3ExactOut (
        SwapV3.ExactOutputSingleParams memory params
    ) public returns (uint256 amountIn) {}

    function swapV3MultiHopExactIn (
        SwapV3.ExactInputParams memory params
    ) public returns (uint256 amountOut) {}

    function swapV3MultiHopExactOut(
        SwapV3.ExactOutputParams memory params
    ) external returns (uint256 amountIn) {}

    function swapMixedMultiHopExactIn (
        SwapV3.ExactInputMixedParams memory params
    ) public returns (uint256 amountOut) {}

    function swapMixedMultiHopExactOut(
        SwapV3.ExactOutputMixedParams memory params
    ) external returns (uint256 amountIn) {}

    // V3 callback
    function cacheStorage() internal pure returns (CacheStruct storage cache) {
        bytes32 position = keccak256("swapv3.amountin.cache.storage");
        assembly { cache.slot := position }
    }

    /// UniswapV3SwapCallback
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata _data
    ) external override {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        CacheStruct storage cache = cacheStorage();
        
        SwapV3.SwapCallbackData memory data = abi.decode(_data, (SwapV3.SwapCallbackData));
        (address tokenIn, address tokenOut, uint24 fee) = data.path.decodeFirstPool();
        address factoryV3 = SwapV3.factoryV3;
        CallbackValidation.verifyCallback(factoryV3, tokenIn, tokenOut, fee);

        (bool isExactInput, uint256 amountToPay) =
            amount0Delta > 0
                ? (tokenIn < tokenOut, uint256(amount0Delta))
                : (tokenOut < tokenIn, uint256(amount1Delta));
        if (isExactInput) {
            SwapBase.pay(tokenIn, data.payer, msg.sender, amountToPay);
        } else {
            // either initiate the next swap or pay
            if (data.path.hasMultiplePools()) {
                data.path = data.path.skipToken();
                SwapV3.exactOutputInternal(amountToPay, msg.sender, 0, data);
            } else {
                cache.amountInCached = amountToPay;
                tokenIn = tokenOut; // swap in/out because exact output swaps are reversed
                SwapBase.pay(tokenIn, data.payer, msg.sender, amountToPay);
            }
        }
    }

}

