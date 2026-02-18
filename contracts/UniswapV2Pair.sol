pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';


/**
Note: Every pair contract is inherited from UniswapV2ERC20 contract. It is LP token. 
 */
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {      
    using SafeMath for uint;
    using UQ112x112 for uint224;

    uint public constant MINIMUM_LIQUIDITY = 10 ** 3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0; // uses single storage slot, accessible via getReserves
    uint112 private reserve1; // uses single storage slot, accessible via getReserves
    uint32 private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        // uint112(-1) = 2**112 - 1 = type(uint112).max = 5192296858534827628530496329220095
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');

        /**
         2**32 = 4294967296 == type(uint32).max + 1
         block.timestamp = 1771199112
         blockTimestamp = uint32(block.timestamp % 2**32)
                        = uint32(1771199112 % 4294967296)
                        = 1771199112    =>>> Note that the modulus always returns the block.timestamp no matter what the block.timestamp is. That is why
                                             it returned 1771199112. 
                                             For that reason the blockTimestamp variable gets the actual block.timestamp,

        When the modulus has no effect on the block.timestamp as it is returning exact block.timestamp we they are using it?
        => until block.timestamp is 2**32 the modulus will return the exact block.timestamp whichwill satisfy the bound of uint32.
         When the block.timestamp will cross the 2**32 then the modulus will start working and help to keep the block.timestamp under uint32.  
         So roughly at 2106 year the block.timestamp will reach 2**32 cap. Till now the modulus has not any effect. After reaching that 2**32
         cap the modulo starts showing effect i.e starts returning value. This modulo keeps working until the returned value of the modulus reaches
         2**32 cap. 

         Year          |        unix timestamp        |            Modulus value      |   Less than 2**32?
         2442          |          14898884536         |             2013982648        |     Yes       
         2578          |          19190631736         |             2010762552        |     Yes
         2714          |          23482292536         |             2007456056        |     Yes
         5000          |          95621540536         |             1132260024        |     Yes
         100_000       |        3093531937336         |             1155484216        |     Yes

         So, here we can see the logic will never overflow. 
         */
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            /**
            encode(y) = uint224(y) * Q112 where Q112 = 2**112 == 5192296858534827628530496329220096
            x.uqdiv9(y) = x / uint224(y)
            For example lets calculate price0CumulativeLast:
            reserve0 = 100, reserve1 = 100 and timeElapsed = 300 (5 minutes)
            (encode(100).uqdiv(100)) * 300 
            => ((100 * 5192296858534827628530496329220096).uqdiv(100)) * 300
            => (519229685853482762853049632922009600.uqdiv(100)) * 300
            => (519229685853482762853049632922009600 / uint224(100)) * 300
            => 5192296858534827628530496329220096 * 300
            => 1557689057560448288559148898766028800

            So here they are doing 2 things: (1) gets the price of token0 in terms of token1 & price of token1 in terms of token0. 
                                             (2) calculating cumulative price by multiplying timeElapsed. 
                                             Cumulative price is calculated like this: if price is 10 then for 10 seconds (timeElapsed = 10)
                                             the cumulative price will be 10*10 = 100. 
             */
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }

        // Making the balance0 and balance1 as reserve0 and reserve1. Note that this balance0 and balance1 is balance of token0 and token1 of this pair contract
        // after the swap.
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    /**
    mintFee is taken if feeOn address is set. The mintFee amount is 1/6th LP token growth based on the liquidity growth. 
    (1) Current liqudity is calculated. √k means liquidity. 
    (2) Last liqidity is fetched. 
    (3) (rootK - rootKLast) is the liquidity growth.
    (4) if (rootK > rootKLast) then it means there is a growth in liquidity. By multiplying it with totalSupply of LP token we are 
    achieving the growth in LP token. 
    (5) 
     */
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();

        //
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                // k != 0 means both token's reserve is non-zero
                /**
                 * NOTE: mintFee and swapFee is different. 
                Every mint() and burn() kLast is updated after calculating mintFee. During calculating mintFee K is calculated based on the current value of 
                reserves. 

                rootK = currentRootK = current liquidity = √k = √(reserve0 * reserve1)
                lastRootK = √kLast 
                rootK = This contains latest reserve value after last update() call
                 */
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));  // NOTE: Liquidity is represented by √k, not k.  
                // So, rootK = current liquidity
                // rootKLast = previous liquidity
                uint rootKLast = Math.sqrt(_kLast);


                /**
                (1)
                √k / totalSupply = liquidity per LP token 
                means, if totalSupply 10 and liquidity is 100 then : 100/10 = 10, 1 lp token for 10 liquidity. 
                Now, change in liquity is: (rootK - rootKLast). So if rootK = 110 and rootKLast = 100 so change in liquidity = (110 - 100) = 10. 
                so for this change LP token will be 1. So we can say that LP token growth is 1.
                (2)
                110 * 5 + 100 => 550 + 100 = 650 
                (3)
                Following the (1), we have rootK = 110, rootKLast = 100 and totalSupply = 10. 
                numerator = 10 * (110 - 100) = 100
                denominator = rootK * 5 + rootKLast = 550 + 100 = 650
                liquidity = 100/650 = 0.153  
                NOTE: 1/6th is measured on LP token growth.
                As LP token growth is 1 and if we multiply the 0.153 with 6 so we get (0.153 * 6) = 0.91, almost 1. 
                (4)
                This 0.153 LP token is minted to feeTo address. 

                Now one doubt can come in mind that why we need to multiply the totalSupply here? We just do the operation without the totalSupply. Right?
                No, lets do the equation first without totalSupply of LP token :
                (rootK - rootKLast) / (rootK * 5 + rootKLast) = (110 - 100) / (110 * 5 + 100) = (10 / 650) = 0.0153 
                So we can directly mint this 0.0153 to the feeOn address, right? No, because:
                Because if we mint 0.0153 LP token to feeOn then protocol will get 1.53% of 1 LP growth. Which is too small than 1/6th. 
                That is why we are multiplying it with totalsupply, as shown above after multiplying the value becomes 0.153 which is 15.3% of 1 LP growth, which is
                roughly 1/6th. 

                */
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));   // totalSupply = total supply of LP token
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    /**
    When we add liquidity from router these are done:
    TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
    TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
    liquidity = IUniswapV2Pair(pair).mint(to); 
     */
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));

        // amount0 and amount1 => amount of token0 and token1 just added. 
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);

    
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee

        /**
        totalSupply = 0 means there is no liquidity, and NO LIQUIDITY MEANS NO SWAP CAN POSSIBLE, AND NO SWAP MEANS NO reserve0 and reserve1. 
        In that case liquidity(√k) can not be √(reserve0 * reserve1) because both are 0 now. So liquidity is calculated with passed amount, 
        i.e amount0 and amount1. So, for the first liquidity deposit, √k = √(amount0 * amount1). 
         */
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {

            /**
            Math.min(amount0 * totalSupply / reserve0, amount1 * totalSupply / reserve1) 
            liquidity = (theAmountWeDeposited * totalLPTokenInCirculation / totalAmountAlreadyInPool) 
            liquidity amount of LP token will be minted to `to` [to = liquidity provider]
             */
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }


        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));

        /**
        (1) Why liquidity is calculated like this?
        (2) Why amounts are fetched like that?
         */

        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution

        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        // Either amount0 or amount1 must be non-zero
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        // Getting the reserve, for very first call its lool like _reserve0 and _reserve1 is 0.
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        // To be amount out must less than reserve
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;
            // 'to' can't be any of token in pair
            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');

            /**
        In practice only one of amount0Out and amount1Out is >0. Lets assume amount0Out is >0. Note that, to use this contract first user
        need to transfer token to the pair. So as amount0Out is >0 so user has sent token0 to this pair. i.e he wants to swap token0 for token1. 

        user wants to swap 50 token0 for 60 token1. Router sends 50 token0 to this pair. Now token0.balanceOf(address(this)) = 150. [assuming it has 100]
        reserve0 = 100.
        reserve1 = 100.
        swap() called. 
        60 token1 was transferred to recipient. 
        reserve1 = (100 - 60) = 40. 
        balance0 = 150. 
        balance1 = (100 - 60) = 40. 
         amount0Out = 0, because user wants to get token1. 
         so, 
         amount0In = balance0 > reserve0 - amount0Out
                       = 150 > 100 - 0
                       = 150 > 100
                                  = (balance0 - (reserve0 - amount0Out))
                                  = (150 - (100 - 0))
                                  = (150 - 100)
                                  = 50   =>>>  Correct, user input was 50 token0
        
        amount1In = balance1 > reserve1 - amount1Out
                  = 40 > (100 - 60)
                  = 40 == 40 
                            = 0 =>>> Correct, user did not put any token1

         */

            // OPTIMISTIC TRANSFER = The contract will transfer the token to receiver of swap without verifying that user has transferred the input
            // token before. For ex-  user wants to swap 10 token0 for 11 token1. So this contract will send the 11 token1 to recipient whithout 
            // verifying that the user has sent the 10 token0 to this contract. 

            // if amount0 is to be out then token0 will be transferred to 'to'
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            // if amount1 is to be out then token1 will be transferred to 'to'
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens

            // Doubt: What is uniswapV2Callee contract ?? What uniswapV2Call() does ??
            // @note uniswapV2Call() is to be implemented in 'to' contract/EOA. Now as
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);

            // Getting token0 balance of this pair
            balance0 = IERC20(_token0).balanceOf(address(this));
            // Getting token1 balance of this pair
            balance1 = IERC20(_token1).balanceOf(address(this));
        }

        /**
        Getting the amount of token transferred by the user, through router, to the pair. 
        If user swapping token0 for token1 then amount0In will be >0, to be precise the amount0In will be the transferred amount by user. And amount1In will be 0.
        If user swapping token1 for token0 then amount1In will be >0. And amount0In will be 0.
         */
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;

        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');

        {
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            /// (balance * 1000) - (amountIn * 3)
            /**
         balance = 1000
         amountIn = 100
         (1000 * 1000) - (100 * 3)
         => 1000000 - 300
         => 999700

         =>>> Here 3 is 0.3% fee

         during this calculation swap has done and balance0, balance1 is updated

         For ex- amount0In = 50, balance0 = 150
         (150 x 1000) - (50 x 3)
        => 150000 - 150
        => 149850 => 149.850
         */
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));

            /**
         Here it is checking that : balance after deducting the 0.3% fee is greater than or equal to previous reserve [reserve befre swap]. 
         Here the acctual thing it is checking is : x*y = k. 
         But as fee is deducted so balanceAdjusted will be slightly greater than the reserve. That is why it is requiring: x*y >= k. 
         */
        //                                               =: FEE DEDUCTING MECHANISM :=
        // In swap() fee is not taken directly with token transfer, instead of that it compares the reserve with deducted fee. 
        // If previous (x*y) is not greater/equal to (x*y with deducted fee) then it will revert.
            require(
                balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000 ** 2),
                'UniswapV2: K'
            );
        }

        // _update() is called with the - after swap token0 balance & token1 balance of this pair contrct, before swap reserve0 and reserve1
        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
