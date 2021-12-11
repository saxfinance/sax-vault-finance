// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "./Interfaces.sol";

interface IBeltVault is IERC20{
    function deposit(uint256 _amount, uint256 _minShares) external;
    function depositBNB(uint256 _minShares) external payable;
    function withdraw(uint256 _shares, uint256 _minAmount) external;
    function withdrawBNB(uint256 _shares, uint256 _minAmount) external;
    function sharesToAmount(uint256 _shares) external view returns (uint256);
    function amountToShares(uint256 _amount) external view returns (uint256);
}

interface IMasterBelt {
    function owner() external view returns (address);
    function BELT() external returns (address);
    function burnAddress() external returns (address);
    function ownerBELTReward() external returns (uint256);
    function BELTPerBlock() external returns (uint256);
    function startBlock() external returns (uint256);
    function poolInfo(uint256) external returns (
        address want,
        uint256 allocPoint,
        uint256 lastRewardBlock,
        uint256 accBELTPerShare,
        address strat
    );
    function userInfo(uint256, address) external returns (
        uint256 shares,
        uint256 rewardDebt
    );
    function totalAllocPoint() external returns (uint256);
    function poolLength() external view returns (uint256);
    function add(uint256 _allocPoint, address _want, bool _withUpdate, address _strat) external;
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external;
    function getMultiplier(uint256 _from, uint256 _to) external view returns (uint256);
    function pendingBELT(uint256 _pid, address _user) external view returns (uint256);
    function stakedWantTokens(uint256 _pid, address _user) external view returns (uint256);
    function massUpdatePools() external;
    function updatePool(uint256 _pid) external;
    function deposit(uint256 _pid, uint256 _wantAmt) external;
    function withdraw(uint256 _pid, uint256 _wantAmt) external;
    function withdrawAll(uint256 _pid) external;
    function emergencyWithdraw(uint256 _pid) external;
    function inCaseTokensGetStuck(address _token, uint256 _amount) external;
}

contract StrategyBelt is OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, ISimpleStrategy {

    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMathUpgradeable for uint256;
    using SafeERC20 for IBeltVault;

    bool public wantIsWBNB;
    bool public isMasterBelt;
    IERC20 public wantToken;
    address public uniRouterAddress;

    address public wbnbAddress;
    address public bnbHelper;

    IMasterBelt public masterBelt;
    IERC20 public beltToken;
    IBeltVault public beltVault;

    uint256 public lastHarvestBlock;

    address[] public beltToWantPath;

    uint256 public poolId;

    address public vault;

    mapping (address => bool) public keepers;

    event KeepersSet(address[] keepers, bool[] states);

    /*
     * Parameters on BSC:
     * poolId: 
     * _masterBeltAddress: 0xD4BbC80b9B102b77B21A06cb77E954049605E6c1
     * _beltToken: 0xE0e514c71282b6f4e823703a39374Cf58dc3eA4f
     * beltVault(MultiStrategyToken): 0x55E1B1e49B969C018F2722445Cd2dD9818dDCC25
     * wantAddress: 0x55d398326f99059fF775485246999027B3197955
     * uniRouterAddress: 0x10ED43C718714eb63d5aA57B78B54704E256024E
     */
    function initialize(
        uint256 _poolId,
        address _masterBeltAddress,
        address _beltToken,
        address _beltVault,
        address _wantAddress,
        address _bnbHelper,
        address _uniRouterAddress,
        address _vault,
        bool _isMasterBelt
    )
    external
    initializer
    {
        __Ownable_init();
        __Pausable_init();

        poolId = _poolId;
        masterBelt = IMasterBelt(_masterBeltAddress);
        beltToken = IERC20(_beltToken);
        beltVault = IBeltVault(_beltVault);
        lastHarvestBlock = 0;
        isMasterBelt = _isMasterBelt;

        wantToken = IERC20(_wantAddress);
        wbnbAddress = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
        bnbHelper = _bnbHelper;
        
        if (_wantAddress == wbnbAddress) {
            wantIsWBNB = true;
            beltToWantPath = [_beltToken, wbnbAddress];
        } else {
            beltToWantPath = [_beltToken, wbnbAddress, _wantAddress];
        }

        uniRouterAddress = _uniRouterAddress;

        wantToken.safeApprove(_beltVault, uint256(-1));
        beltVault.safeApprove(_masterBeltAddress, uint256(-1));
        beltToken.safeApprove(uniRouterAddress, uint256(-1));
        vault = _vault;
    }

    modifier onlyVault() {
        require (msg.sender == vault, "Must from vault");
        _;
    }

    modifier onlyVaultOrKeeper() {
        require (msg.sender == vault || keepers[msg.sender], "Must from vault/keeper");
        _;
    }

    function deposit(uint256 _wantAmt)
    external
    override
    onlyVault
    nonReentrant
    {
        wantToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );
        if (wantIsWBNB){
            _unwrapBNB();
            beltVault.depositBNB{value: address(this).balance}(0);
        }else{
            beltVault.deposit(_wantAmt, 0);
        }
        if (isMasterBelt){
            masterBelt.deposit(poolId, beltVault.balanceOf(address(this)));
        }
    }
    
    function withdraw(uint256 _wantAmt)
    external
    override
    onlyVault
    nonReentrant
    {
        uint256 ibAmt = beltVault.amountToShares(_wantAmt);
        if (isMasterBelt){
            masterBelt.withdraw(poolId, ibAmt);
        }
        if (wantIsWBNB){
            beltVault.withdrawBNB(ibAmt, 0);
            _wrapBNB();
        }else{
            beltVault.withdraw(ibAmt, 0);
        }

        uint256 actualWantAmount = wantToken.balanceOf(address(this));
        wantToken.safeTransfer(
            address(msg.sender),
            actualWantAmount
        );
    }

    function _harvest(uint256 priceMin) internal {
        if (lastHarvestBlock == block.number) {
            return;
        }

        // Do not harvest if no token is deposited (otherwise, fairLaunch will fail)
        if (totalBalance() == 0) {
            return;
        }

        // Collect beltToken
        masterBelt.withdraw(poolId, 0);

        uint256 earnedBeltBalance = beltToken.balanceOf(address(this));
        if (earnedBeltBalance == 0) {
            return;
        }

        if (beltToken != wantToken) {
            IPancakeRouter02(uniRouterAddress).swapExactTokensForTokens(
                earnedBeltBalance,
                earnedBeltBalance.mul(priceMin).div(1e18),
                beltToWantPath,
                address(this),
                now.add(600)
            );
        }

        beltVault.deposit(wantToken.balanceOf(address(this)), 0);
        masterBelt.deposit(poolId, beltVault.balanceOf(address(this)));

        lastHarvestBlock = block.number;
    }

    function harvest(uint256 minPrice) external override onlyVaultOrKeeper nonReentrant {
        require(isMasterBelt, "isMasterBelt is false");
        _harvest(minPrice);
    }
    
    function totalBalance() public override view returns (uint256) {
        uint256 localAmount = lockedInHere();
        if (isMasterBelt){
            uint256 ibAmt = masterBelt.stakedWantTokens(poolId, address(this));
            return localAmount.add(beltVault.sharesToAmount(ibAmt));
        }else{
            return localAmount.add(beltVault.sharesToAmount(beltVault.balanceOf(address(this))));   
        }
    }

    function lockedInHere() public view returns (uint256) {
        uint256 wantBal = wantToken.balanceOf(address(this));
        return wantBal;
    }


    function _wrapBNB() internal {
        uint256 bnbBal = address(this).balance;
        if (bnbBal > 0) {
            IWBNB(bnbHelper).deposit{value: bnbBal}();
        }
    }

    function _unwrapBNB() internal {
        uint256 wbnbBal = IERC20(wbnbAddress).balanceOf(address(this));
        if (wbnbBal > 0) {
            IERC20(wbnbAddress).safeApprove(bnbHelper, wbnbBal);
            IWBNB(bnbHelper).unwrapBNB(wbnbBal);
        }
    }
    
    function wrapBNB() public onlyOwner{
        require(wantIsWBNB, "!isWBNB");
        _wrapBNB();
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() external onlyOwner {
        _pause();

        beltToken.safeApprove(uniRouterAddress, 0);
        wantToken.safeApprove(uniRouterAddress, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        beltToken.safeApprove(uniRouterAddress, uint256(-1));
        wantToken.safeApprove(uniRouterAddress, uint256(-1));
    }

    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }
    
    function setBNBHelper(address _helper) public onlyOwner {
        require(_helper != address(0));

        bnbHelper = _helper;
    }


    function setKeepers(address[] calldata _keepers, bool[] calldata _states) external onlyOwner {
        uint256 n = _keepers.length;
        for(uint256 i = 0; i < n; i++) {
            keepers[_keepers[i]] = _states[i];
        }
        emit KeepersSet(_keepers, _states);
    }
    
    fallback() external payable {}
    receive() external payable {}
}