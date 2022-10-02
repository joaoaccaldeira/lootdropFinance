// SPDX-License-Identifier: Unlicensed
pragma solidity >= 0.8.10;
pragma abicoder v2;

import "./Context.sol";
import "./Ownable.sol";
import "./ERC20Detailed.sol";
import "../libraries/SafeMath.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IERC20Metadata.sol";
import "../interfaces/IPancakeSwapFactory.sol";
import "../interfaces/IPancakeSwapPair.sol";
import "../interfaces/IPancakeSwapRouter.sol";
import "@api3/airnode-protocol/contracts/rrp/requesters/RrpRequesterV0.sol";

contract LootdropFinanceETH is ERC20Detailed, Ownable, RrpRequesterV0 {
    using SafeMath for uint256;

    //API3 QRNG
    event RequestedUint256(bytes32 indexed requestId);
    event ReceivedUint256(bytes32 indexed requestId);
    address public airnode;
    bytes32 public endpointIdUint256;
    address public sponsorWallet;
    mapping(bytes32 => bool) public expectingRequestWithIdToBeFulfilled;
    
    bool public api3QrngEnabled = false;
    mapping(bytes32 => address) requestIdToAddress;
    mapping(bytes32 => uint256) requestNrOfLootboxes;
    mapping(address => bool) waitingForAPI3QRNG;

    modifier validRecipient(address to) {
        require(to != address(0x0));
        _;
    }

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    IPancakeSwapRouter public immutable pancakeswapRouter;
    IPancakeSwapPair public immutable pairContract;
    address public immutable pancakeswapPair;
    address public constant deadAddress = address(0xdead);
    address public pinksaleAddress = deadAddress;
    
    uint256 public DECIMALS = 5;

    bool private swapping;

    address public treasury;

    uint256 public _totalSupply = 1_000_000_000 * 10**DECIMALS;
    uint256 public initialSupply = _totalSupply;
    uint256 public maxWalletInitialSize = 3_000_000 * 10**DECIMALS; // 0.3% of total supply
    uint256 public maxWallet = maxWalletInitialSize; // 0.3% of total supply -> increases up to 3%
    uint256 public maxTransactionAmount = maxWalletInitialSize; // 0.3% of total supply -> increases up to 1.5%
    uint256 public swapTokensAtAmount = (_totalSupply * 5) / 10000; // 0.05% of total supply
    uint256 public maxWalletLimit = 30_000_000 * 10**DECIMALS; // 3% of total supply
    uint256 public maxTransactionLimit = 15_000_000 * 10**DECIMALS; // 1.5% of total supply

    uint256 public launchTime;
    bool public tradingActive = false;
    bool public swapEnabled = false;
    bool public autoLPEnabled = true;

    uint256 public buyingCompetitionsBalance = 0;
    uint256 public smallHourlyBuyAmount = (_totalSupply * 1) / 10000; // 0.01% small hourly buy
    address[] public smallHourlyBuyers;
    uint256 public nrOfSmallHourlyBuyers;
    uint256 public smallBuyPrize = 5; // 5%
    mapping(address => bool) isSmallBuyingCompetitionWinner;
    mapping(address => bool) claiming;
    address public biggestHourlyBuyer;
    uint256 public biggestHourlyBuy;
    uint256 public biggestHourlyBuyPrize = 10; // 10%
    uint256 public buyingCompetitionsPeriod = 1 hours;
    address public previousBiggestBuyWinner;
    address public previousSmallBuyWinner;
    bool public buyingCompetitionsEnabled = true;
    bool public buyingCompetitionsActive = false;
    uint256 public buyingCompetitionsStart;
    uint256 public buyingCompetitionCooldown = 1 hours;
    mapping(address => bool) isBuyingCompetitionWinner;
    uint256 public triggerBuyingCompetitionTreshold = 0;

    bool public dynamicFeeEnabled = true;
    uint256 public treasuryFee = 300;
    uint256 public liquidityFee = 300;
    uint256 public burnFee = 300;
    uint256 public buyingCompetitionsFee = 100;
    uint256 public feeDenominator = 10000;
    uint256 public feeImpact = 200; //Every 1% in price impact will result in 2% being added or removed from fee
    uint256 public totalBaseFee = treasuryFee.add(liquidityFee).add(burnFee).add(buyingCompetitionsFee);
    uint256 public buyFee = totalBaseFee;
    uint256 public sellFee = totalBaseFee;

    struct UserRewardsData {
        uint256 totalRewardsWon;
        uint256 firstBuyTimestamp;
        uint256 lastClaimedTimestamp;
    }
    uint32 public maxUnclaimedLootboxesLimit = 30;
    uint256 private lastLootboxForDeadAddressTimestamp;
    mapping(address => UserRewardsData) public userRewardsData;

    struct LootBoxRewards {
        uint256 firstTier;
        uint256 secondTier;
        uint256 thirdTier;
        uint256 fourthTier;
        uint256 fifthTier;
        uint256 sixthTier;
    }
    struct UserLootboxesWon{
        uint256 firstTierWon;
        uint256 secondTierWon;
        uint256 thirdTierWon;
        uint256 fourthTierWon;
        uint256 fifthTierWon;
        uint256 sixthTierWon;
    }
    mapping(address => UserLootboxesWon) userLootboxesWon;
    LootBoxRewards public lootboxRewards;

    bool public rewardsEnabled = true;
    uint256 public rewardsPeriod = 1 hours;

    mapping(address => bool) private _isExcludedFromFees;
    mapping(address => bool) public _isExcludedFromLimits;
    mapping(address => bool) public automatedMarketMakerPairs;
    

    constructor(address _treasury, address _router, address _airnodeRrp) ERC20Detailed("TestNL", "TestNL", uint8(DECIMALS)) Ownable() RrpRequesterV0(_airnodeRrp) {
        
        IPancakeSwapRouter _pancakeswapRouter = IPancakeSwapRouter(_router);
        pancakeswapRouter = _pancakeswapRouter;
        pancakeswapPair = IPancakeSwapFactory(_pancakeswapRouter.factory()).createPair(address(this), _pancakeswapRouter.WETH());
        pairContract = IPancakeSwapPair(pancakeswapPair);

        _setAutomatedMarketMakerPair(pancakeswapPair, true);

        treasury = _treasury;

        excludeFromFees(owner(), true);
        excludeFromFees(address(this), true);
        excludeFromFees(address(0xdead), true);
        excludeFromFees(treasury, true);

        excludeFromLimits(owner(), true);
        excludeFromLimits(address(this), true);
        excludeFromLimits(address(0xdead), true);
        excludeFromLimits(treasury, true);
        excludeFromLimits(pancakeswapPair, true);
        excludeFromLimits(_router, true);

        lootboxRewards.firstTier = 1000625;
        lootboxRewards.secondTier = 1000833;
        lootboxRewards.thirdTier = 1000041;
        lootboxRewards.fourthTier = 1001250;
        lootboxRewards.fifthTier = 1002083;
        lootboxRewards.sixthTier = 1004166;

        _allowances[address(this)][address(_pancakeswapRouter)] = 2**256 - 1;
        _balances[treasury] = _totalSupply;
        _transferOwnership(treasury);
        emit Transfer(address(0x0), treasury, _totalSupply);
    }

    function transfer(address to, uint256 value) external override validRecipient(to) returns (bool) {
        _transferFrom(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override validRecipient(to) returns (bool) {
        if (_allowances[from][msg.sender] != 2**256 - 1) {
            _allowances[from][msg.sender] = _allowances[from][
                msg.sender
            ].sub(value, "Insufficient Allowance");
        }
        if(swapping && from == address(this)){
            _basicTransfer(from, to, value);
        }
        else{
            _transferFrom(from, to, value);
        }
        return true;
    }

    function _transferFrom(address from, address to, uint256 amount) internal {
        require(_balances[from] >= amount && amount > 0, "Insufficient Balance");
        require(!claiming[from], "User is claiming tokens");
        require(!api3QrngEnabled || !waitingForAPI3QRNG[from], "Cant transfer when claiming lootboxes");

        //handle transfers from the pinksaleAddress
        if(from == pinksaleAddress) {
            _isExcludedFromFees[to];
            _basicTransfer(from, to, amount);
            return;
        }

        if(tradingActive){
            //Due to the nature of the lootbox drops, wallet-to-wallet transfers are disabled so that rewards can't be exploited
            require(from==pancakeswapPair || to == pancakeswapPair || _isExcludedFromFees[from] || _isExcludedFromFees[to], "Transfers from wallet to wallet are disabled");
        }

        //increase max limits until targets are hit after launch
        maxLimitsIncrease();

        if (from != owner() && to != owner() && to != address(0) && to != address(0xdead) && !swapping) 
        {
            if (!tradingActive) {
                require(_isExcludedFromFees[from] || _isExcludedFromFees[to], "Trading is not active.");
            }

            //when buy
            if (automatedMarketMakerPairs[from] && !_isExcludedFromLimits[to]) {
                require(amount <= maxTransactionAmount, "Buy transfer amount exceeds the maxTransactionAmount.");
                require(amount + _balances[to] <= maxWallet, "Max wallet exceeded");
            }
            //when sell
            else if (automatedMarketMakerPairs[to] && !_isExcludedFromLimits[from]) 
            {
                require(amount <= maxTransactionAmount, "Sell transfer amount exceeds the maxTransactionAmount.");
            } 
            else if (!_isExcludedFromLimits[to]) 
            {
                if(from!=pinksaleAddress){
                    require(amount + _balances[to] <= maxWallet, "Max wallet exceeded");
                }
            }
        }

        uint256 contractTokenBalance = _balances[address(this)];

        bool canSwap = contractTokenBalance >= swapTokensAtAmount;

        if (canSwap && swapEnabled && totalBaseFee > 0 && !swapping && !automatedMarketMakerPairs[from] && !_isExcludedFromFees[from] && !_isExcludedFromFees[to]) 
        {
            swapping = true;

            swapBack();

            swapping = false;
        }

        //Take fee if applicable
        uint256 amountWithoutFee = amount;
        amount = shouldTakeFee(from, to) ? takeFee(from, amount) : amount;

        //update user rewards data
        updateUserRewardsData(from, to);
        
        //Update buying competition status if applicable
        updateBuyingCompetition(from, to, amount, amountWithoutFee);

        //transfers
        _basicTransfer(from, to, amount);
    }

    function _basicTransfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0) && recipient != address(0), "ERC20: transfer from/to the zero address");

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
        unchecked {
            _balances[sender] = senderBalance - amount;
        }
        _balances[recipient] += amount;

        emit Transfer(sender, recipient, amount);
    }

    function maxLimitsIncrease() internal{
        if(!tradingActive || maxWallet == maxWalletLimit){
            return;
        }

        uint256 timeSinceLaunch = block.timestamp - launchTime;

        if(timeSinceLaunch >= 1 minutes) {
            uint256 minutesSinceLaunch = timeSinceLaunch / 1 minutes;

            //increase by 0.1% of the supply every minute until max limits are hit
            maxWallet = maxWalletInitialSize + (minutesSinceLaunch * 1_000_000*10 ** DECIMALS);
            if(maxTransactionAmount < maxTransactionLimit){
                maxTransactionAmount = maxWallet;
            }

            //sanity check
            if(maxWallet > maxWalletLimit || maxTransactionAmount > maxTransactionLimit){
                maxWallet = maxWalletLimit;
                maxTransactionAmount = maxTransactionLimit;
            }
        }
    }

    function takeFee(address from, uint256 amount) internal returns(uint256){
        uint256 feeAmount;
        uint256 _fees;

        //calculate dynamic fee change
        if(dynamicFeeEnabled){
            calculateDynamicFeeChange(from, amount);
        }

        _fees = pancakeswapPair == from ? buyFee : sellFee;

        feeAmount = amount * _fees / feeDenominator;

        if(feeAmount > 0){
            _balances[from] -= feeAmount;
            _balances[address(this)] += feeAmount;
            emit Transfer(from, address(this), feeAmount);
        }

        return amount-feeAmount;
    }

    function shouldTakeFee(address from, address to) internal view returns (bool){
        return (pancakeswapPair == from || pancakeswapPair == to) && !_isExcludedFromFees[from] && totalBaseFee > 0 && !swapping;
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the pancakeswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pancakeswapRouter.WETH();

        _allowances[address(this)][address(pancakeswapRouter)] = 2**256 - 1;

        // make the swap
        pancakeswapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _allowances[address(this)][address(pancakeswapRouter)] = 2**256 - 1;

        // add the liquidity
        pancakeswapRouter.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            deadAddress,
            block.timestamp
        );
    }

    function swapBack() private {
        uint256 contractBalance = _balances[address(this)];
        bool success;

        if (contractBalance == 0 || totalBaseFee == 0) {
            return;
        }

        if (contractBalance > swapTokensAtAmount * 20) {
            contractBalance = swapTokensAtAmount * 20;
        }

        //burn tokens
        uint256 burnAmount = contractBalance * burnFee / totalBaseFee;
        _basicTransfer(address(this), deadAddress, burnAmount);

        //get balance again
        contractBalance -= burnAmount;

        // Halve the amount of liquidity tokens
        uint256 liquidityTokens = (contractBalance * liquidityFee) / (totalBaseFee-burnFee);
        liquidityTokens = liquidityTokens.div(2);
        uint256 amountToSwapForETH = contractBalance.sub(liquidityTokens);

        uint256 initialETHBalance = address(this).balance;

        swapTokensForEth(amountToSwapForETH);

        uint256 ethBalance = address(this).balance.sub(initialETHBalance);
        uint256 ethForTreasury = ethBalance.mul(treasuryFee).div(totalBaseFee-burnFee);
        uint256 ethForBuyingCompetitions = ethBalance.mul(buyingCompetitionsFee).div(totalBaseFee-burnFee);
        uint256 ethForLiquidity = ethBalance - ethForTreasury - ethForBuyingCompetitions;

        //add liquidity
        if (liquidityTokens > 0 && ethForLiquidity > 0 && autoLPEnabled) {
            addLiquidity(liquidityTokens, ethForLiquidity);
        }

        //update buyingCompetitionsBalance
        buyingCompetitionsBalance += ethForBuyingCompetitions;

        //leftover unaccounted for eth from adding liquidity slippage is added to the treasury
        if(address(this).balance > buyingCompetitionsBalance){
            ethForTreasury = address(this).balance - buyingCompetitionsBalance;
        }

        //send eth to Treasury
        (success, ) = address(treasury).call{value: ethForTreasury}("");
    }

    /*********************************************************
    ----------------------------------------------------------
    ----------------- Dynamic Fee Functions ------------------
    ----------------------------------------------------------
    ******************************************************** */
    function calculatePriceImpact(address tokenAddress, address pairAddress, uint256 value) internal view returns (uint256) {
        IPancakeSwapPair pair = IPancakeSwapPair(pairAddress);

        (uint256 r0, uint256 r1,) = pair.getReserves();

        IERC20Metadata token0 = IERC20Metadata(pair.token0());
        IERC20Metadata token1 = IERC20Metadata(pair.token1());

        if(address(token1) == tokenAddress) {
            IERC20Metadata tokenTemp = token0;
            token0 = token1;
            token1 = tokenTemp;

            uint256 rTemp = r0;
            r0 = r1;
            r1 = rTemp;
        }

        uint256 product = r0 * r1;

        uint256 r0After = r0 + value;
        uint256 r1After = product / r0After;

        if(r1After <= r1){
            return (10000 - (r1After * 10000 / r1));
        }
        else{
            return((r1After * 10000 / r1) - 10000);
        }
    }

    function calculateDynamicFeeChange(address from, uint256 amount) internal {
        uint256 priceImpact = calculatePriceImpact(address(this), pancakeswapPair, amount);

        uint256 increaseFee = priceImpact * feeImpact / 100;

        //buy
        if(from == pancakeswapPair){
            
            buyFee += increaseFee;

            if(buyFee > totalBaseFee) {
                buyFee = totalBaseFee;
            }

            if(sellFee <= increaseFee) {
                sellFee = totalBaseFee;
            }
            else{
                sellFee -= increaseFee;
                if(sellFee < totalBaseFee) {
                    sellFee = totalBaseFee;
                }
            }

        }

        //sell
        else {
            
            sellFee = sellFee + increaseFee;
            if(sellFee >= 2000){
                sellFee = 2000;
            }

            if(buyFee >= increaseFee) {
                buyFee -= increaseFee;
            }
            else{
                buyFee = 0;
            }
        }
    }

    /*********************************************************
    ----------------------------------------------------------
    ------------------- Rewards Functions --------------------
    ----------------------------------------------------------
    ******************************************************** */
    function updateUserRewardsData(address from, address to) internal {
        if(!tradingActive){
            userRewardsData[to].firstBuyTimestamp = block.timestamp;
            userRewardsData[to].lastClaimedTimestamp = block.timestamp;
            return;
        }

        if(from == pancakeswapPair){
            //buys reset lootbox timers so that the rewards system can't be exploited
            userRewardsData[to].firstBuyTimestamp = block.timestamp;
            userRewardsData[to].lastClaimedTimestamp = block.timestamp;
        }
    }

    function requestAPI3QRNG(address from, uint256 _nrOfLootboxes) internal {

        bytes32 requestId = airnodeRrp.makeFullRequest(
            airnode,
            endpointIdUint256,
            address(this),
            sponsorWallet,
            address(this),
            this.fulfillUint256.selector,
            ""
        );
        expectingRequestWithIdToBeFulfilled[requestId] = true;
        emit RequestedUint256(requestId);

        //update variables
        requestIdToAddress[requestId] = from;
        requestNrOfLootboxes[requestId] = _nrOfLootboxes;
        if(from != deadAddress){
            waitingForAPI3QRNG[from] = true;
        }
    }

    function fulfillUint256(bytes32 requestId, bytes calldata data) external onlyAirnodeRrp {
        if(!api3QrngEnabled){
            return;
        }
        require(
            expectingRequestWithIdToBeFulfilled[requestId],
            "Request ID not known"
        );
        expectingRequestWithIdToBeFulfilled[requestId] = false;
        uint256 qrngUint256 = abi.decode(data, (uint256));
        emit ReceivedUint256(requestId);
        _fulfillUint256(requestId, qrngUint256);
    }

    function _fulfillUint256(bytes32 requestId, uint256 rand) private {
        address _user = requestIdToAddress[requestId];

        if(_user == deadAddress){
            if(nrOfSmallHourlyBuyers > 0){
                uint256 _winnerIndex = rand % nrOfSmallHourlyBuyers;
                address _winnerAddress = smallHourlyBuyers[_winnerIndex];
                isSmallBuyingCompetitionWinner[_winnerAddress] = true;
                previousSmallBuyWinner = _winnerAddress;
                nrOfSmallHourlyBuyers = 0;
            }
        }
        else if(_balances[_user] > 0){
            uint256 _rewards = 0;

            for (uint256 i = 0; i < requestNrOfLootboxes[requestId]; i++) {
                _rewards += openLootBox(uint8(rand), _user);
                rand >>= 8;
            }

            waitingForAPI3QRNG[_user] = false;
            _balances[_user] += _rewards;
            _totalSupply += _rewards;
            userRewardsData[_user].totalRewardsWon += _rewards;
            emit Transfer(address(0), _user, _rewards);
        }
    }

    function openLootBox(uint256 rand, address _user) internal returns (uint256) {
        uint256 _lootBox = rand % 256;

        if(_lootBox < 100){
            _lootBox = lootboxRewards.firstTier;
            userLootboxesWon[_user].firstTierWon++;
        }
        else if(_lootBox >= 100 && _lootBox < 150){
            _lootBox = lootboxRewards.secondTier;
            userLootboxesWon[_user].secondTierWon++;
        }
        else if(_lootBox >= 150 && _lootBox < 190){
            _lootBox = lootboxRewards.thirdTier;
            userLootboxesWon[_user].thirdTierWon++;
        }
        else if(_lootBox >= 190 && _lootBox < 220){
            _lootBox = lootboxRewards.fourthTier;
            userLootboxesWon[_user].fourthTierWon++;
        }
        else if(_lootBox >= 220 && _lootBox < 245) {
            _lootBox = lootboxRewards.fifthTier;
            userLootboxesWon[_user].fifthTierWon++;
        }
        else{
            _lootBox = lootboxRewards.sixthTier;
            userLootboxesWon[_user].sixthTierWon++;
        }

        return (_balances[_user] * _lootBox / 1000000) - _balances[_user];
    }

    function calculateNumberOfLootBoxes(address from) public view returns(uint256) {
        if(_balances[from]==0 || !tradingActive){
            return 0;
        }

        uint256 deltaTime;

        //handle presale users claiming lootboxes for the first time (timestamp is set to launch time)
        if(userRewardsData[from].lastClaimedTimestamp==0){
            deltaTime = block.timestamp - launchTime;
        }
        //else it's a standard claim
        else{
            deltaTime = block.timestamp - userRewardsData[from].lastClaimedTimestamp;
        }

        uint256 times = deltaTime.div(rewardsPeriod);

        //max lootboxes at a single time are capped
        if(times > maxUnclaimedLootboxesLimit){
            times = maxUnclaimedLootboxesLimit;
        }

        return times;
    }

    function claimLootbox() external {
        require(rewardsEnabled && tradingActive, "Rewards are disabled");
        require(_balances[msg.sender] >= 0, "Zero balance");

        //handle presale users claiming lootboxes for the first time (timestamp is set to launch time)
        if(userRewardsData[msg.sender].lastClaimedTimestamp==0) {
            userRewardsData[msg.sender].lastClaimedTimestamp = launchTime;
        }

        require(block.timestamp >= userRewardsData[msg.sender].lastClaimedTimestamp + rewardsPeriod, "On cooldown");

        uint256 nrOfLootBoxes = calculateNumberOfLootBoxes(msg.sender);

        if(nrOfLootBoxes > 0){
            if(nrOfLootBoxes == maxUnclaimedLootboxesLimit){
                userRewardsData[msg.sender].lastClaimedTimestamp = block.timestamp;
            }
            else{
                userRewardsData[msg.sender].lastClaimedTimestamp = userRewardsData[msg.sender].lastClaimedTimestamp + (nrOfLootBoxes * rewardsPeriod);
            }

            if(api3QrngEnabled){
                requestAPI3QRNG(msg.sender, nrOfLootBoxes);
            }
        }
    }

    /*********************************************************
    ----------------------------------------------------------
    ----------------- Buying Comp Functions ------------------
    ----------------------------------------------------------
    ******************************************************** */
    function updateBuyingCompetition(address from, address to, uint256 amount, uint256 amountWithoutFee) internal {
        if(!buyingCompetitionsEnabled){
            return;
        }

        //end buying competition if applicable
        if(buyingCompetitionsActive && block.timestamp > buyingCompetitionsStart + buyingCompetitionsPeriod){
            endBuyingCompetition();
            return;
        }

        //start buying competition if applicable
        if(buyFee == 0 && !buyingCompetitionsActive && block.timestamp >= buyingCompetitionsStart + buyingCompetitionsPeriod + buyingCompetitionCooldown) {
            buyingCompetitionsActive = true;
            buyingCompetitionsStart = block.timestamp;
            nrOfSmallHourlyBuyers = 0;
            biggestHourlyBuy = 0;
            //starts off as the treasury in case nobody buys during the hourly buying competition
            biggestHourlyBuyer = treasury;
            return;
        }

        //update biggest buyer accordingly if applicable
        if(buyingCompetitionsActive && from == pancakeswapPair) {
            if(amount > biggestHourlyBuy){
                biggestHourlyBuy = amount;
                biggestHourlyBuyer = to;
            }

            if(amountWithoutFee >= smallHourlyBuyAmount){
                addToSmallHourlyBuyer(to);
            }
        }
        
    }

    function endBuyingCompetition() internal {
        //end competition
        buyingCompetitionsActive = false;
        //flag biggest buy winner that will be able to claim prize
        previousBiggestBuyWinner = biggestHourlyBuyer;
        isBuyingCompetitionWinner[biggestHourlyBuyer] = true;
        //generate request for random number who will win the small buy prize
        if(nrOfSmallHourlyBuyers > 0 && api3QrngEnabled){
            requestAPI3QRNG(deadAddress, 1);
        }
    }

    function claimBiggestHourlyBuyPrize() external {
        require(buyingCompetitionsEnabled && tradingActive, "Competitions disabled");

        //end buying competition if applicable
        if(buyingCompetitionsActive && block.timestamp > buyingCompetitionsStart + buyingCompetitionsPeriod){
            endBuyingCompetition();
        }

        require(isBuyingCompetitionWinner[msg.sender], "Invalid claim");

        //reset winner flag
        isBuyingCompetitionWinner[msg.sender] = false;

        //calcualte prize and pay
        calculatePrizeAndPay(msg.sender, biggestHourlyBuyPrize);
    }

    function claimSmallBuyPrize() external{
        require(buyingCompetitionsEnabled && tradingActive, "Competitions disabled");
        require(isSmallBuyingCompetitionWinner[msg.sender], "Invalid claim");

        //reset winner flag
        isSmallBuyingCompetitionWinner[msg.sender] = false;

        //calculate prize amount and pay
        calculatePrizeAndPay(msg.sender, smallBuyPrize);
    }

    function calculatePrizeAndPay(address from, uint256 prizePercentage) internal {
        uint256 prizeAmount =  buyingCompetitionsBalance*prizePercentage/100;
        require(prizeAmount <= address(this).balance && prizeAmount > 0, "Insufficient balance");

        buyingCompetitionsBalance -= prizeAmount;
        
        claiming[from] = true;
        (bool success, ) = address(from).call{value: prizeAmount}("");
        require(success, "Failed Transfer");
        claiming[from] = false;
    }

    function addToSmallHourlyBuyer(address _addr) internal{
        nrOfSmallHourlyBuyers++;

        if(nrOfSmallHourlyBuyers > smallHourlyBuyers.length){
            smallHourlyBuyers.push(_addr);
        }
        else{
            smallHourlyBuyers[nrOfSmallHourlyBuyers-1] = _addr;
        }
    }


    /*********************************************************
    ----------------------------------------------------------
    ----------------------- ERC20 Functions ------------------
    ----------------------------------------------------------
    ******************************************************** */
    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }
   
    function balanceOf(address who) external view override returns (uint256) {
        return _balances[who];
    }

    function allowance(address owner_, address spender) external view override returns (uint256){
        return _allowances[owner_][spender];
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 oldValue = _allowances[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowances[msg.sender][spender] = 0;
        } else {
            _allowances[msg.sender][spender] = oldValue.sub(
                subtractedValue
            );
        }
        emit Approval(
            msg.sender,
            spender,
            _allowances[msg.sender][spender]
        );
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        _allowances[msg.sender][spender] = _allowances[msg.sender][
            spender
        ].add(addedValue);
        emit Approval(
            msg.sender,
            spender,
            _allowances[msg.sender][spender]
        );
        return true;
    }

    function approve(address spender, uint256 value) external override returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }


    /*********************************************************
    ----------------------------------------------------------
    ----------------------- SETTERS --------------------------
    ----------------------------------------------------------
    ******************************************************** */
    // once enabled, can never be turned off
    function enableTrading() external onlyOwner {
        tradingActive = true;
        swapEnabled = true;
        launchTime = block.timestamp;
    }

    function setRequestParameters(address _airnode, bytes32 _endpointIdUint256, address _sponsorWallet) external onlyOwner {
        airnode = _airnode;
        endpointIdUint256 = _endpointIdUint256;
        sponsorWallet = _sponsorWallet;
    }

    function setPinksaleAddress(address _addr) external onlyOwner{
        pinksaleAddress = _addr;
        _isExcludedFromFees[pinksaleAddress] = true;
        _isExcludedFromLimits[pinksaleAddress] = true;
    }

    function setLootboxTiers(uint256 _firstTier, uint256 _secondTier, uint256 _thirdTier, uint256 _fourthTier, uint256 _fifthTier, uint256 _sixthTier) external onlyOwner{
        lootboxRewards.firstTier = _firstTier;
        lootboxRewards.secondTier = _secondTier;
        lootboxRewards.thirdTier = _thirdTier;
        lootboxRewards.fourthTier = _fourthTier;
        lootboxRewards.fifthTier = _fifthTier;
        lootboxRewards.sixthTier = _sixthTier;
    }

    function setapi3QrngEnabled(bool flag) external onlyOwner{
        api3QrngEnabled = flag;
    }

    function setRewardOptions(bool flag, uint256 _rewardsPeriod, uint32 _maxUnclaimedLootboxesLimit) external onlyOwner{
        require(_rewardsPeriod <= 1 days, "Invalid ROI");
        rewardsEnabled = flag;
        rewardsPeriod = _rewardsPeriod;
        maxUnclaimedLootboxesLimit = _maxUnclaimedLootboxesLimit;
    }

    function setBuyingCompetitionsEnabled(bool flag) external onlyOwner{
        buyingCompetitionsEnabled = flag;
    }

    function setBuyingCompetitionOptions(uint256 _bigPrize, uint256 _smallPrize, uint256 _smallAmount, uint256 _period, uint256 _cooldown, uint256 _threshold) external onlyOwner{
        require(_bigPrize > 0 && _bigPrize <= 100 && _smallPrize > 0 && _smallPrize <= 100, "Invalid Prize Amount");
        require(_smallAmount >= _totalSupply/1000000, "Invalid Amount");
        require(_cooldown >= 10 minutes, "Invalid Cooldown");
        require(_period >= 1 hours, "Invalid Period");
        require(_threshold <= 1000, "Invalid Threshold");
        biggestHourlyBuyPrize = _bigPrize;
        smallBuyPrize = _smallPrize;
        smallHourlyBuyAmount = _smallAmount;
        buyingCompetitionsPeriod = _period;
        buyingCompetitionCooldown = _cooldown;
        triggerBuyingCompetitionTreshold = _threshold;
    }

    function setDynamicFeeEnabled(bool flag) external onlyOwner{
        dynamicFeeEnabled = flag;
        if(!flag){
            sellFee = totalBaseFee;
            buyFee = totalBaseFee;
        }
    }

    function changeAutoLPEnabled (bool flag) external onlyOwner{
        autoLPEnabled = flag;
    }

    function setFeeImpact(uint256 _impact) external onlyOwner{
        require(_impact <= 200 && _impact > 0, "Invalid Value");
        feeImpact = _impact;
    }

    // change the minimum amount of tokens to sell from fees
    function updateSwapTokensAtAmount(uint256 newAmount) external onlyOwner returns (bool) {
        require(newAmount >= (_totalSupply * 1) / 100000 && newAmount <= (_totalSupply * 5) / 1000, "Invalid Amount");

        swapTokensAtAmount = newAmount;
        return true;
    }

    function updateMaxTxnAmount(uint256 newNum) external onlyOwner {
        require( newNum >= ((_totalSupply * 1) / 1000) / 1e18, "Invalid amount");

        maxTransactionAmount = newNum * (10**18);
    }

    function updateMaxWalletAmount(uint256 newNum) external onlyOwner {
        require(newNum >= ((_totalSupply * 5) / 1000) / 1e18, "Invalid Amount");

        maxWallet = newNum * (10**18);
    }

    function excludeFromLimits(address updAds, bool isEx) public onlyOwner{
        _isExcludedFromLimits[updAds] = isEx;
    }

    function updateSwapEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
    }

    function updateBaseFees(uint256 _treasuryFee, uint256 _liquidityFee, uint256 _burnFee, uint256 _buyingCompetitionsFee) external onlyOwner {
        treasuryFee = _treasuryFee;
        liquidityFee = _liquidityFee;
        burnFee = _burnFee;
        buyingCompetitionsFee = _buyingCompetitionsFee;
        totalBaseFee = treasuryFee.add(liquidityFee).add(burnFee).add(buyingCompetitionsFee);

        //resets buy / sell fees + buy bonus
        sellFee = totalBaseFee;
        buyFee = totalBaseFee;

        require(totalBaseFee <= 2000 && (totalBaseFee != burnFee || totalBaseFee == 0), "Invalid fees");
        if(liquidityFee == 0){
            autoLPEnabled = false;
        }
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        _isExcludedFromFees[account] = excluded;
    }

    function setAutomatedMarketMakerPair(address pair, bool value) public onlyOwner {
        require(pair != pancakeswapPair);
        _setAutomatedMarketMakerPair(pair, value);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        automatedMarketMakerPairs[pair] = value;
    }

    function updateTreasuryWallet(address newTreasuryWallet) external onlyOwner{
        treasury = newTreasuryWallet;
    }

    function isExcludedFromFees(address account) public view returns (bool) {
        return _isExcludedFromFees[account];
    }

    /*********************************************************
    ----------------------------------------------------------
    ----------------------- GETTERS --------------------------
    ----------------------------------------------------------
    ******************************************************** */
    function getUserRewardsData(address from) external view returns (uint256, uint256, uint256 ) {
        return (
            userRewardsData[from].firstBuyTimestamp, 
            userRewardsData[from].lastClaimedTimestamp, 
            userRewardsData[from].totalRewardsWon
        );
    }

    function isUserWinner(address from) external view returns(bool, bool){
        return(
            isBuyingCompetitionWinner[from],
            isSmallBuyingCompetitionWinner[from]
        );
    }

    function isUserwaitingForAPI3(address from) external view returns(bool) {
        return waitingForAPI3QRNG[from];
    }

    function getUserLootboxesWon(address from) external view returns(uint256, uint256, uint256, uint256, uint256, uint256){
        return(
            userLootboxesWon[from].firstTierWon,
            userLootboxesWon[from].secondTierWon,
            userLootboxesWon[from].thirdTierWon,
            userLootboxesWon[from].fourthTierWon,
            userLootboxesWon[from].fifthTierWon,
            userLootboxesWon[from].sixthTierWon
        );
    }


    receive() external payable {}
}