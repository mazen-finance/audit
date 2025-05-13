// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.24;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import "../interfaces/IUniswapV2Pair.sol";
import "../interfaces/IUniswapV3Pool.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IWETH.sol";
import "../interfaces/ICurve.sol";
import "../interfaces/IMaverickV2Pool.sol";
import "../interfaces/IiZiSwapPool.sol";
import "../interfaces/IMaverickRouter.sol";
import "./InputStream.sol";
import "./Utils.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "hardhat/console.sol";



address constant IMPOSSIBLE_POOL_ADDRESS = 0x0000000000000000000000000000000000000001;
address constant INTERNAL_INPUT_SOURCE = 0x0000000000000000000000000000000000000000;

address constant MAVERICK_ROUTER = 0x35e44dc4702Fd51744001E248B49CBf9fcc51f0C; //plume mainnet maverick router

uint8 constant LOCKED = 2;
uint8 constant NOT_LOCKED = 1;
uint8 constant PAUSED = 2;
uint8 constant NOT_PAUSED = 1;

/// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
uint160 constant MIN_SQRT_RATIO = 4295128739;
/// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

/// @title A simplified route processor for DeFi aggregation
contract StratusRouter is OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using Utils for IERC20;
    using Utils for address;
    using SafeERC20 for IERC20Permit;
    using InputStream for uint256;

    event SwapExecuted(
        address indexed pool, address indexed recipient, bool tokenAIn, uint256 amountIn, uint256 amountOut
    );

    event Route(
        address indexed from,
        address to,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 amountOut
    );

    error MinimalOutputBalanceViolation(uint256 amountOut);

    mapping(address => bool) public priviledgedUsers;
    address private lastCalledPool;

    uint8 private unlocked;
uint8 private paused;

    modifier lock() {
        require(unlocked == NOT_LOCKED, "RouteProcessor is locked");
        require(paused == NOT_PAUSED, "RouteProcessor is paused");
        unlocked = LOCKED;
        _;
        unlocked = NOT_LOCKED;
    }

    modifier onlyOwnerOrPriviledgedUser() {
        require(
            msg.sender == owner() || priviledgedUsers[msg.sender], "RP: caller is not the owner or a privileged user"
        );
        _;
    }

   function initialize(address[] memory priviledgedUserList) public initializer {
    __Ownable_init();
    __UUPSUpgradeable_init();
    
    unlocked = NOT_LOCKED;
    paused = NOT_PAUSED;
    
    lastCalledPool = IMPOSSIBLE_POOL_ADDRESS;

    for (uint256 i = 0; i < priviledgedUserList.length; i++) {
        priviledgedUsers[priviledgedUserList[i]] = true;
    }
}


    function setPriviledge(address user, bool priviledge) external onlyOwner {
        priviledgedUsers[user] = priviledge;
    }

    function pause() external onlyOwnerOrPriviledgedUser {
        paused = PAUSED;
    }

    function resume() external onlyOwnerOrPriviledgedUser {
        paused = NOT_PAUSED;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {

    }

    /// @notice For native unwrapping
    receive() external payable {}

    /// @notice Executes the swap route generated off-chain. Has a lock
    /// @param tokenIn Address of the input token
    /// @param amountIn Amount of the input token
    /// @param tokenOut Address of the output token
    /// @param amountOutMin Minimum amount of the output token
    /// @param to Where to transfer output tokens
    /// @param route Route to process
    /// @return amountOut Actual amount of the output token
    function executeSwap(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOutMin,
        address to,
        bytes memory route
    ) external payable lock returns (uint256 amountOut) {
        return executeSwapInternal(tokenIn, amountIn, tokenOut, amountOutMin, to, route);
    }

    /// @notice Transfers some value to <transferValueTo> and then executes the swap
    /// @param transferValueTo Address where the value should be transferred
    /// @param amountValueTransfer How much value to transfer
    /// @param tokenIn Address of the input token
    /// @param amountIn Amount of the input token
    /// @param tokenOut Address of the output token
    /// @param amountOutMin Minimum amount of the output token
    /// @return amountOut Actual amount of the output token
    function transferValueAndExecuteSwap(
        address transferValueTo,
        uint256 amountValueTransfer,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOutMin,
        address to,
        bytes memory route
    ) external payable lock returns (uint256 amountOut) {
        transferValueTo.transferNative(amountValueTransfer);
        return executeSwapInternal(tokenIn, amountIn, tokenOut, amountOutMin, to, route);
    }

    /// @notice Transfers some value of input tokens to <transferValueTo> and then executes the swap
    /// @param transferValueTo Address where the value should be transferred
    /// @param amountValueTransfer How much value to transfer
    /// @param tokenIn Address of the input token
    /// @param amountIn Amount of the input token
    /// @param tokenOut Address of the output token
    /// @param amountOutMin Minimum amount of the output token
    /// @return amountOut Actual amount of the output token
    function executeSwapWithTransferValueInput(
        address payable transferValueTo,
        uint256 amountValueTransfer,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOutMin,
        address to,
        bytes memory route
    ) external payable lock returns (uint256 amountOut) {
        tokenIn.transferAnyFromSender(transferValueTo, amountValueTransfer);
        return executeSwapInternal(tokenIn, amountIn, tokenOut, amountOutMin, to, route);
    }

    /// @notice executes the swap and sends <amountValueTransfer> amount of output token to <transferValueTo>
    /// @param transferValueTo Address where the value should be transferred
    /// @param amountValueTransfer How much value to transfer
    /// @param tokenIn Address of the input token
    /// @param amountIn Amount of the input token
    /// @param tokenOut Address of the output token
    /// @param amountOutMin Minimum amount of the output token
    /// @return amountOut Actual amount of the output token
    function executeSwapWithTransferValueOutput(
        address payable transferValueTo,
        uint256 amountValueTransfer,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOutMin,
        address to,
        bytes memory route
    ) external payable lock returns (uint256 amountOut) {
        amountOut = executeSwapInternal(tokenIn, amountIn, tokenOut, amountOutMin, address(this), route);
        tokenOut.transferAny(transferValueTo, amountValueTransfer);
        tokenOut.transferAny(to, amountOut - amountValueTransfer);
    }

    /// @notice Executes the swap route generated off-chain
    /// @param tokenIn Address of the input token
    /// @param amountIn Amount of the input token
    /// @param tokenOut Address of the output token
    /// @param amountOutMin Minimum amount of the output token
    /// @return amountOut Actual amount of the output token
    function executeSwapInternal(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOutMin,
        address to,
        bytes memory route
    ) private returns (uint256 amountOut) {
        uint256 balanceInInitial = tokenIn.anyBalanceOf(msg.sender);
        uint256 balanceOutInitial = tokenOut.anyBalanceOf(to);

        uint256 realAmountIn = amountIn;
        {
            uint256 step = 0;
            uint256 stream = InputStream.createStream(route);
            while (stream.isNotEmpty()) {
                uint8 commandCode = stream.readUint8();
                if (commandCode == 1) {
                    uint256 usedAmount = processMyERC20(stream);
                    if (step == 0) realAmountIn = usedAmount;
                } else if (commandCode == 2) {
                    processUserERC20(stream, amountIn);
                } else if (commandCode == 3) {
                    uint256 usedAmount = processNative(stream);
                    if (step == 0) realAmountIn = usedAmount;
                } else if (commandCode == 4) {
                    processOnePool(stream);
                } else if (commandCode == 6) {
                    applyPermit(tokenIn, stream);
                } else {
                    revert("RouteProcessor: Unknown command code");
                }
                ++step;
            }
        }

        uint256 balanceInFinal = tokenIn.anyBalanceOf(msg.sender);
        if (tokenIn != Utils.NATIVE_ADDRESS) {
            require(
                balanceInFinal + amountIn + 10 >= balanceInInitial, "RouteProcessor: Minimal input balance violation"
            );
        }

        uint256 balanceOutFinal = tokenOut.anyBalanceOf(to);
        if (balanceOutFinal < balanceOutInitial + amountOutMin) {
            revert MinimalOutputBalanceViolation(balanceOutFinal - balanceOutInitial);
        }

        amountOut = balanceOutFinal - balanceOutInitial;

        emit Route(msg.sender, to, tokenIn, tokenOut, realAmountIn, amountOutMin, amountOut);
    }

    /// @notice Applies ERC-2612 permit
    /// @param tokenIn permitted token
    /// @param stream Streamed program
    function applyPermit(address tokenIn, uint256 stream) private {
        uint256 value = stream.readUint();
        uint256 deadline = stream.readUint();
        uint8 v = stream.readUint8();
        bytes32 r = stream.readBytes32();
        bytes32 s = stream.readBytes32();
        if (IERC20(tokenIn).allowance(msg.sender, address(this)) < value) {
            IERC20Permit(tokenIn).safePermit(msg.sender, address(this), value, deadline, v, r, s);
        }
    }

    /// @notice Processes native coin: call swap for all pools that swap from native coin
    /// @param stream Streamed program
    function processNative(uint256 stream) private returns (uint256 amountTotal) {
        amountTotal = address(this).balance;
        distributeAndSwap(stream, address(this), Utils.NATIVE_ADDRESS, amountTotal);
    }

    /// @notice Processes ERC20 token from this contract balance:
    /// @notice Call swap for all pools that swap from this token
    /// @param stream Streamed program
    function processMyERC20(uint256 stream) private returns (uint256 amountTotal) {
        address token = stream.readAddress();
        amountTotal = IERC20(token).balanceOf(address(this));
        unchecked {
            if (amountTotal > 0) amountTotal -= 1; // slot undrain protection
        }
        distributeAndSwap(stream, address(this), token, amountTotal);
    }

    /// @notice Processes ERC20 token from msg.sender balance:
    /// @notice Call swap for all pools that swap from this token
    /// @param stream Streamed program
    /// @param amountTotal Amount of tokens to take from msg.sender
    function processUserERC20(uint256 stream, uint256 amountTotal) private {
        address token = stream.readAddress();
        distributeAndSwap(stream, msg.sender, token, amountTotal);
    }

    /// @notice Processes ERC20 token for cases when the token has only one output pool
    /// @notice In this case liquidity is already at pool balance. This is an optimization
    /// @notice Call swap for all pools that swap from this token
    /// @param stream Streamed program
    function processOnePool(uint256 stream) private {
        address token = stream.readAddress();
        swap(stream, INTERNAL_INPUT_SOURCE, token, 0);
    }

    /// @notice Distributes amountTotal to several pools according to their shares and calls swap for each pool
    /// @param stream Streamed program
    /// @param from Where to take liquidity for swap
    /// @param tokenIn Input token
    /// @param amountTotal Total amount of tokenIn for swaps
    function distributeAndSwap(uint256 stream, address from, address tokenIn, uint256 amountTotal) private {
        uint8 num = stream.readUint8();
        unchecked {
            for (uint256 i = 0; i < num; ++i) {
                uint16 share = stream.readUint16();
                uint256 amount = (amountTotal * share) / type(uint16).max; /*65535*/
                amountTotal -= amount;
                swap(stream, from, tokenIn, amount);
            }
        }
    }

    /// @notice Makes swap
    /// @param stream Streamed program
    /// @param from Where to take liquidity for swap
    /// @param tokenIn Input token
    /// @param amountIn Amount of tokenIn to take for swap
    function swap(uint256 stream, address from, address tokenIn, uint256 amountIn) private {
        uint8 poolType = stream.readUint8();
        if (poolType == 0) swapUniV2(stream, from, tokenIn, amountIn);
        else if (poolType == 1) swapUniV3(stream, from, tokenIn, amountIn);
        else if (poolType == 2) wrapNative(stream, from, tokenIn, amountIn);
        else if (poolType == 5) swapCurve(stream, from, tokenIn, amountIn);
        else if (poolType == 7) swapMaverickV2(stream, from, tokenIn, amountIn);
        else if (poolType == 8) swapIzumi(stream, from, tokenIn, amountIn);
        else revert("RouteProcessor: Unknown pool type");
    }

    /// @notice Wraps/unwraps native token
    /// @param stream [direction & fake, recipient, wrapToken?]
    /// @param from Where to take liquidity for swap
    /// @param tokenIn Input token
    /// @param amountIn Amount of tokenIn to take for swap
    function wrapNative(uint256 stream, address from, address tokenIn, uint256 amountIn) private {
        uint8 directionAndFake = stream.readUint8();
        address to = stream.readAddress();

        if (directionAndFake & 1 == 1) {
            // wrap native
            address wrapToken = stream.readAddress();
            if (directionAndFake & 2 == 0) IWETH(wrapToken).deposit{value: amountIn}();
            if (to != address(this)) IERC20(wrapToken).safeTransfer(to, amountIn);
        } else {
            // unwrap native
            if (directionAndFake & 2 == 0) {
                if (from == msg.sender) IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
                IWETH(tokenIn).withdraw(amountIn);
            }
            to.transferNative(amountIn);
        }
    }

    /// @notice UniswapV2 pool swap
    /// @param stream [pool, direction, recipient, fee]
    /// @param from Where to take liquidity for swap
    /// @param tokenIn Input token
    /// @param amountIn Amount of tokenIn to take for swap
    function swapUniV2(uint256 stream, address from, address tokenIn, uint256 amountIn) private {
        address pool = stream.readAddress();
        uint8 direction = stream.readUint8();
        address to = stream.readAddress();
        uint24 fee = stream.readUint24(); // pool fee in 1/1_000_000

        if (from == address(this)) IERC20(tokenIn).safeTransfer(pool, amountIn);
        else if (from == msg.sender) IERC20(tokenIn).safeTransferFrom(msg.sender, pool, amountIn);

        (uint256 r0, uint256 r1,) = IUniswapV2Pair(pool).getReserves();
        require(r0 > 0 && r1 > 0, "Wrong pool reserves");
        (uint256 reserveIn, uint256 reserveOut) = direction == 1 ? (r0, r1) : (r1, r0);
        amountIn = IERC20(tokenIn).balanceOf(pool) - reserveIn; // tokens already were transferred

        uint256 amountInWithFee = amountIn * (1_000_000 - fee);
        uint256 amountOut = (amountInWithFee * reserveOut) / (reserveIn * 1_000_000 + amountInWithFee);
        (uint256 amount0Out, uint256 amount1Out) = direction == 1 ? (uint256(0), amountOut) : (amountOut, uint256(0));
        IUniswapV2Pair(pool).swap(amount0Out, amount1Out, to, new bytes(0));
    }

    function swapMaverickV2(uint256 stream, address from, address tokenIn, uint256 amountIn) private {
        address pool = stream.readAddress();
        bool tokenAIn = stream.readUint8() > 0;
        bool exactOutput = stream.readUint8() > 0;
        uint32 tickLimit = stream.readUint32(); 
        address recipient = stream.readAddress();
        uint256 amountOutMinimum = stream.readUint();

        if (from == msg.sender) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        if (IERC20(tokenIn).allowance(address(this), MAVERICK_ROUTER) < amountIn) {
            IERC20(tokenIn).safeApprove(MAVERICK_ROUTER, type(uint256).max);
        }

        uint256 amountOut = IMaverickRouter(MAVERICK_ROUTER).exactInputSingle(
            recipient,
            pool,
            tokenAIn,
            amountIn,
            amountOutMinimum
        );

        require(amountOut >= amountOutMinimum, "MaverickV2: Output amount too low");

        emit SwapExecuted(pool, recipient, tokenAIn, amountIn, amountOut);
    }

    function maverickV2SwapCallback(uint256 amountToPay, bytes calldata data) external {
        require(msg.sender == lastCalledPool, "Maverick: Invalid callback");

        address tokenIn = abi.decode(data, (address));

        require(IERC20(tokenIn).balanceOf(address(this)) >= amountToPay, "Maverick: Insufficient balance");

        console.log("Callback executing:");
        console.log("- amountToPay:", amountToPay);
        console.log("- tokenIn:", tokenIn);
        console.log("- caller:", msg.sender);

        IERC20(tokenIn).safeTransfer(msg.sender, amountToPay);

        lastCalledPool = IMPOSSIBLE_POOL_ADDRESS;
    }

    /// @notice UniswapV3 pool swap
    /// @param stream [pool, direction, recipient]
    /// @param from Where to take liquidity for swap
    /// @param tokenIn Input token
    /// @param amountIn Amount of tokenIn to take for swap
    function swapUniV3(uint256 stream, address from, address tokenIn, uint256 amountIn) private {
        address pool = stream.readAddress();
        bool zeroForOne = stream.readUint8() > 0;
        address recipient = stream.readAddress();

        if (from == msg.sender) IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), uint256(amountIn));

        lastCalledPool = pool;
        IUniswapV3Pool(pool).swap(
            recipient,
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            abi.encode(tokenIn)
        );
        require(lastCalledPool == IMPOSSIBLE_POOL_ADDRESS, "RouteProcessor.swapUniV3: unexpected"); // Just to be sure
    }

    /// @notice Called to `msg.sender` after executing a swap via IUniswapV3Pool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    /// The caller of this method must be checked to be a UniswapV3Pool deployed by the canonical UniswapV3Factory.
    /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the IUniswapV3PoolActions#swap call
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) public {
        require(msg.sender == lastCalledPool, "RouteProcessor.uniswapV3SwapCallback: call from unknown source");
        int256 amount = amount0Delta > 0 ? amount0Delta : amount1Delta;
        require(amount > 0, "RouteProcessor.uniswapV3SwapCallback: not positive amount");

        lastCalledPool = IMPOSSIBLE_POOL_ADDRESS;
        (address tokenIn) = abi.decode(data, (address));
        IERC20(tokenIn).safeTransfer(msg.sender, uint256(amount));
    }

    /// @notice Called to `msg.sender` after executing a swap via IAlgebraPool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    /// The caller of this method _must_ be checked to be a AlgebraPool deployed by the canonical AlgebraFactory.
    /// amount0Delta and amount1Delta can both be 0 if no tokens were swapped.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the IAlgebraPoolActions#swap call
    function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
    }

    /// @notice Called to `msg.sender` after executing a swap via PancakeV3Pool#swap.
    /// @dev In the implementation you must pay the pool tokens owed for the swap.
    /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token0 to the pool.
    /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive) by the pool by
    /// the end of the swap. If positive, the callback must send that amount of token1 to the pool.
    /// @param data Any data passed through by the caller via the PancakeV3Pool#swap call
    function pancakeV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        uniswapV3SwapCallback(amount0Delta, amount1Delta, data);
    }

    /// @notice Curve pool swap. Legacy pools that don't return amountOut and have native coins are not supported
    /// @param stream [pool, poolType, fromIndex, toIndex, recipient, output token]
    /// @param from Where to take liquidity for swap
    /// @param tokenIn Input token
    /// @param amountIn Amount of tokenIn to take for swap
    function swapCurve(uint256 stream, address from, address tokenIn, uint256 amountIn) private {
        address pool = stream.readAddress();
        uint8 poolType = stream.readUint8();
         uint8 fromIndex = stream.readUint8();
        uint8 toIndex = stream.readUint8();
        address to = stream.readAddress();
        address tokenOut = stream.readAddress();

        uint256 amountOut;
        if (tokenIn == Utils.NATIVE_ADDRESS) {
            amountOut = ICurve(pool).swap(
                fromIndex,
                toIndex,
                amountIn,
                0,
                block.timestamp
            );
        } else {
            if (from == msg.sender) IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            IERC20(tokenIn).approveSafe(pool, amountIn);
            if (poolType == 0) {
                amountOut = ICurve(pool).swap(fromIndex, toIndex, amountIn, 0, block.timestamp);
            } else {
                uint256 balanceBefore = tokenOut.anyBalanceOf(address(this));
                ICurveLegacy(pool).swap(fromIndex, toIndex, amountIn, 0, block.timestamp);
                uint256 balanceAfter = tokenOut.anyBalanceOf(address(this));
                amountOut = balanceAfter - balanceBefore;
            }
        }

        if (to != address(this)) tokenOut.transferAny(to, amountOut);
    }

    function swapIzumi(uint256 stream, address from, address tokenIn, uint256 amountIn) private {
        address pool = stream.readAddress();
        bool isX2Y = stream.readUint8() > 0;
        bool exactOutput = stream.readUint8() > 0;
        int24 pointLimit = int24(uint24(stream.readUint24()));
        address recipient = stream.readAddress();

        if (from == msg.sender) {
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        lastCalledPool = pool;

        if (isX2Y) {
            if (exactOutput) {
              
                IiZiSwapPool(pool).swapX2YDesireY(recipient, uint128(amountIn), pointLimit, abi.encode(tokenIn));
            } else {
   
                IiZiSwapPool(pool).swapX2Y(recipient, uint128(amountIn), pointLimit, abi.encode(tokenIn));
            }
        } else {
            if (exactOutput) {
        
                IiZiSwapPool(pool).swapY2XDesireX(recipient, uint128(amountIn), pointLimit, abi.encode(tokenIn));
            } else {
      
                IiZiSwapPool(pool).swapY2X(recipient, uint128(amountIn), pointLimit, abi.encode(tokenIn));
            }
        }
        require(lastCalledPool == IMPOSSIBLE_POOL_ADDRESS, "RouteProcessor.swapIzumi: unexpected");
    }


    function swapX2YCallback(uint256 amountX, uint256 amountY, bytes calldata data) external {
        require(msg.sender == lastCalledPool, "RouteProcessor.swapX2YCallback: call from unknown source");
        lastCalledPool = IMPOSSIBLE_POOL_ADDRESS;

        address tokenIn = abi.decode(data, (address));
        IERC20(tokenIn).safeTransfer(msg.sender, amountX);
    }

    function swapY2XCallback(uint256 amountX, uint256 amountY, bytes calldata data) external {
        require(msg.sender == lastCalledPool, "RouteProcessor.swapY2XCallback: call from unknown source");
        lastCalledPool = IMPOSSIBLE_POOL_ADDRESS;

        address tokenIn = abi.decode(data, (address));
        IERC20(tokenIn).safeTransfer(msg.sender, amountY);
    }
}
