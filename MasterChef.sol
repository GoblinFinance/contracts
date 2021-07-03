// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "./libs/IReferral.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import "./GoblinToken.sol";

// MasterChef is the master of Goblin. He can make Goblin and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once GOB is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;         // How many LP tokens the user has provided.
        uint256 rewardDebt;     // Reward debt. See explanation below.
        uint256 rewardLockedUp;  // Reward locked up.
        //
        // We do some fancy math here. Basically, any point in time, the amount of GOBs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accGoblinPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accGoblinPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. GOBs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that GOBs distribution occurs.
        uint256 accGoblinPerShare;   // Accumulated GOBs per share, times 1e12. See below.
        uint16 depositFeeBP;      // Deposit fee in basis points
    }

    // The GOB TOKEN!
    GoblinToken public goblin;
    // Dev address.
    address public devAddress;
    // Deposit Fee address
    address public feeAddress;
    // GOB tokens created per block.
    uint256 public goblinPerBlock;
    // Bonus muliplier for early goblin makers.
    uint256 public constant BONUS_MULTIPLIER = 1;
    // Harvest time (how many block);
    uint256 public harvestTime; 
	// Start Block Harvest
    uint256 public startBlockHarvest; 
    // locked duration: 6 days ~ 172800 block;
    uint256 lockedDuration = 172800;
    // max locked duration: 14 days ~ 403200 block
    uint256 maxlockedDuration = 403200;
    // Initial harvest time: 1 day ~ 28800 blocks.
    uint256 public constant INITIAL_HARVEST_TIME = 28800;   

    // Initial emission rate: 50 GOB per block.
    uint256 public constant INITIAL_EMISSION_RATE = 50 ether;
    // Minimum emission rate: 0.1 GOB per block.
    uint256 public constant MINIMUM_EMISSION_RATE = 100 finney;
    // Reduce emission every 9,600 blocks ~ 8 hours.
    uint256 public constant EMISSION_REDUCTION_PERIOD_BLOCKS = 9600;
    // Emission reduction rate per period in basis points: 5%.
    uint256 public constant EMISSION_REDUCTION_RATE_PER_PERIOD = 500;
    // Last reduction period index
    uint256 public lastReductionPeriodIndex = 0;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when GOB mining starts.
    uint256 public startBlock;
    // Total locked up rewards
    uint256 public totalLockedUpRewards;

    // Goblin referral contract address.
    IReferral public referral;
    // Referral commission rate in basis points.
    uint16 public referralCommissionRate = 700;
    // Max referral commission rate: 10%.
    uint16 public constant MAXIMUM_REFERRAL_COMMISSION_RATE = 1000;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);
    event ReferralCommissionPaid(address indexed user, address indexed referrer, uint256 commissionAmount);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);
    event UpdateHarvestTime(address indexed caller, uint256 _oldHarvestTime, uint256 _newHarvestTime);
	event UpdateStartBlockHarvest(address indexed caller, uint256 _oldStartBlockHarvest, uint256 _newStartBlockHarvest);
    event UpdateLockupDuration(address indexed caller, uint256 _oldLockUpDuration, uint256 _newLockUpDuration);

    constructor(
        GoblinToken _goblin,
        uint256 _startBlock
    ) public {
        goblin = _goblin;
        startBlock = _startBlock;

        devAddress = msg.sender;
        feeAddress = msg.sender;
        goblinPerBlock = INITIAL_EMISSION_RATE;
        harvestTime = INITIAL_HARVEST_TIME;
        startBlock = _startBlock;
        startBlockHarvest = _startBlock + lockedDuration;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 400, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accGoblinPerShare: 0,
            depositFeeBP: _depositFeeBP
        }));
    }

    // Update the given pool's GOB allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 400, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending GOBs on frontend.
    function pendingGoblin(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accGoblinPerShare = pool.accGoblinPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 goblinReward = multiplier.mul(goblinPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accGoblinPerShare = accGoblinPerShare.add(goblinReward.mul(1e12).div(lpSupply));
        }
        uint256 pending = user.amount.mul(accGoblinPerShare).div(1e12).sub(user.rewardDebt);
        return pending.add(user.rewardLockedUp);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 goblinReward = multiplier.mul(goblinPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        goblin.mint(devAddress, goblinReward.div(10));
        goblin.mint(address(this), goblinReward);
        pool.accGoblinPerShare = pool.accGoblinPerShare.add(goblinReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for GOB allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referrer) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (_amount > 0 && address(referral) != address(0) && _referrer != address(0) && _referrer != msg.sender) {
            referral.recordReferral(msg.sender, _referrer);
        }
        payOrLockupPendingGoblin(_pid);
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (address(pool.lpToken) == address(goblin)) {
                uint256 transferTax = _amount.mul(goblin.transferTaxRate()).div(10000);
                _amount = _amount.sub(transferTax);
            }
            if (pool.depositFeeBP > 0) {
                uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000);
                pool.lpToken.safeTransfer(feeAddress, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accGoblinPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        payOrLockupPendingGoblin(_pid);
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accGoblinPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Reduce emission rate by 3% every 9,600 blocks ~ 8hours. This function can be called publicly.
    function updateEmissionRate() public {
        require(block.number > startBlock, "updateEmissionRate: Can only be called after mining starts");
        require(goblinPerBlock > MINIMUM_EMISSION_RATE, "updateEmissionRate: Emission rate has reached the minimum threshold");

        uint256 currentIndex = block.number.sub(startBlock).div(EMISSION_REDUCTION_PERIOD_BLOCKS);
        if (currentIndex <= lastReductionPeriodIndex) {
            return;
        }

        uint256 newEmissionRate = goblinPerBlock;
        for (uint256 index = lastReductionPeriodIndex; index < currentIndex; ++index) {
            newEmissionRate = newEmissionRate.mul(1e4 - EMISSION_REDUCTION_RATE_PER_PERIOD).div(1e4);
        }

        newEmissionRate = newEmissionRate < MINIMUM_EMISSION_RATE ? MINIMUM_EMISSION_RATE : newEmissionRate;
        if (newEmissionRate >= goblinPerBlock) {
            return;
        }

        massUpdatePools();
        lastReductionPeriodIndex = currentIndex;
        uint256 previousEmissionRate = goblinPerBlock;
        goblinPerBlock = newEmissionRate;
        emit EmissionRateUpdated(msg.sender, previousEmissionRate, newEmissionRate);
    }

    // updateHarvestTime, how many blocks
    function updateHarvestTime(uint256 _harvestTime) public onlyOwner {
        harvestTime = _harvestTime;
		emit UpdateHarvestTime(msg.sender, harvestTime, _harvestTime);
    }	

    // updateLockupDuration, how many blocks
    function updateLockupDuration(uint256 _lockedDuration) public onlyOwner {
        require(_lockedDuration <= maxlockedDuration, "Invalid lockup duration");
        lockedDuration = _lockedDuration;
		emit UpdateLockupDuration(msg.sender,lockedDuration,_lockedDuration);
    }	

    // updateStartBlockHarvest
    function updateStartBlockHarvest(uint256 _startBlockHarvest) public onlyOwner {
        startBlockHarvest = _startBlockHarvest;
		emit UpdateStartBlockHarvest(msg.sender, startBlockHarvest, _startBlockHarvest);
    }
	


  	// Pay or lockup pending GOBs.
    function payOrLockupPendingGoblin(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 pending = user.amount.mul(pool.accGoblinPerShare).div(1e12).sub(user.rewardDebt);
		uint256 totalRewards = pending.add(user.rewardLockedUp);
        uint256 lastBlockHarvest = startBlockHarvest.add(harvestTime);
        if (block.number >= startBlockHarvest && block.number >= lastBlockHarvest) {
            startBlockHarvest = lastBlockHarvest.add(lockedDuration);
            lastBlockHarvest = startBlockHarvest.add(harvestTime);
        }
        if (block.number >= startBlockHarvest && block.number <= lastBlockHarvest) {
            // within harvesting time
            if (pending > 0 || user.rewardLockedUp > 0) {        
                // reset lockup
                totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
                user.rewardLockedUp = 0;
                // send rewards
                safeGoblinTransfer(msg.sender, totalRewards);
                payReferralCommission(msg.sender, totalRewards);
            }
        } else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

    // Safe goblin transfer function, just in case if rounding error causes pool to not have enough GOBs.
    function safeGoblinTransfer(address _to, uint256 _amount) internal {
        uint256 goblinBal = goblin.balanceOf(address(this));
        if (_amount > goblinBal) {
            goblin.transfer(_to, goblinBal);
        } else {
            goblin.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function setDevAddress(address _devAddress) public {
        require(msg.sender == devAddress, "setDevAddress: FORBIDDEN");
        require(_devAddress != address(0), "setDevAddress: ZERO");
        devAddress = _devAddress;
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        require(_feeAddress != address(0), "setFeeAddress: ZERO");
        feeAddress = _feeAddress;
    }

    // Pancake has to add hidden dummy pools in order to alter the emission, here we make it simple and transparent to all.
    function updateEmissionRate(uint256 _goblinPerBlock) public onlyOwner {
        massUpdatePools();
        emit EmissionRateUpdated(msg.sender, goblinPerBlock, _goblinPerBlock);
        goblinPerBlock = _goblinPerBlock;
    }

    // Update the goblin referral contract address by the owner
    function setReferral(IReferral _referral) public onlyOwner {
        referral = _referral;
    }

    // Update referral commission rate by the owner
    function setReferralCommissionRate(uint16 _referralCommissionRate) public onlyOwner {
        require(_referralCommissionRate <= MAXIMUM_REFERRAL_COMMISSION_RATE, "setReferralCommissionRate: invalid referral commission rate basis points");
        referralCommissionRate = _referralCommissionRate;
    }

    // Pay referral commission to the referrer who referred this user.
    function payReferralCommission(address _user, uint256 _pending) internal {
        if (address(referral) != address(0) && referralCommissionRate > 0) {
            address referrer = referral.getReferrer(_user);
            uint256 commissionAmount = _pending.mul(referralCommissionRate).div(10000);

            if (referrer != address(0) && commissionAmount > 0) {
                goblin.mint(referrer, commissionAmount);
                referral.recordReferralCommission(referrer, commissionAmount);
                emit ReferralCommissionPaid(_user, referrer, commissionAmount);
            }
        }
    }
}



