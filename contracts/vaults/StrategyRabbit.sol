// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {SafeMathUpgradeable} from "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "./Interfaces.sol";

interface IVaultConfig {
    function getInterestRate(uint256 debt, uint256 floating) external view returns (uint256);

    function getReserveBps() external view returns (uint256);
}

interface IRabbitVault {

  function config() external view returns (address);

  struct TokenBank {
    address tokenAddr;
    address ibTokenAddr;
    bool isOpen;
    bool canDeposit;
    bool canWithdraw;
    uint256 totalVal;
    uint256 totalDebt;
    uint256 totalDebtShare;
    uint256 totalReserve;
    uint256 lastInterestTime;
  }

  function banks(address token) external view returns (TokenBank memory);

  /// @dev Return the total ERC20 entitled to the token holders. Be careful of unaccrued interests.
  function totalToken(address token) external view returns (uint256);

  /// @dev Add more ERC20 to the bank. Hope to get some good returns.
  function deposit(address token, uint256 amountToken) external payable;

  /// @dev Withdraw ERC20 from the bank by burning the share tokens.
  function withdraw(address token, uint256 share) external;
}

interface IFairLaunch {
  function poolLength() external view returns (uint256);

  function addPool(
    uint256 _allocPoint,
    address _stakeToken,
    bool _withUpdate
  ) external;

  function setPool(
    uint256 _pid,
    uint256 _allocPoint,
    bool _withUpdate
  ) external;

  function pendingRabbit(uint256 _pid, address _user) external view returns (uint256);

  function updatePool(uint256 _pid) external;

  function deposit(address _for, uint256 _pid, uint256 _amount) external;

  function withdraw(address _for, uint256 _pid, uint256 _amount) external;

  function withdrawAll(address _for, uint256 _pid) external;

  function harvest(uint256 _pid) external;

  function userInfo(uint256 _pid, address user) external view returns (uint256, uint256, uint256, address);
}

contract StrategyRabbit is OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, ISimpleStrategy {

    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMathUpgradeable for uint256;

    bool public wantIsWBNB;
    IERC20 public wantToken;
    address public uniRouterAddress;

    address public wbnbAddress;

    IFairLaunch public fairLaunch;
    IERC20 public rabbitToken;
    IERC20 public rabbitVaultToken;
    IERC20 public rabbitVaultIbToken;
    IRabbitVault public rabbitVault;

    uint256 public lastHarvestBlock;

    address[] public rabbitToWantPath;

    uint256 public poolId;

    address public vault;

    mapping (address => bool) public keepers;

    event KeepersSet(address[] keepers, bool[] states);

    /*
     * usdt:
     * Parameters on BSC:
     * poolId:
     * fairLaunchAddress:
     * rabbitToken:
     * rabbitVault:
     * wantAddress:
     * bnbAddress:
     * uniRouterAddress:
     */
    function initialize(
        uint256 _poolId,
        address _fairLaunchAddress,
        address _rabbitToken,
        address _rabbitVault,
        address _rabbitVaultToken,
        address _wantAddress,
        address _wbnbAddress,
        address _uniRouterAddress,
        address _vault,
        bool _wantIsWBNB
    )
        external
        initializer
    {
        __Ownable_init();
        __Pausable_init();

        poolId = _poolId;
        fairLaunch = IFairLaunch(_fairLaunchAddress);
        rabbitToken = IERC20(_rabbitToken);
        rabbitVault = IRabbitVault(_rabbitVault);
        lastHarvestBlock = 0;
        wantIsWBNB = _wantIsWBNB;

        wantToken = IERC20(_wantAddress);
        wbnbAddress = _wbnbAddress;

        if (_wantAddress == wbnbAddress) {
            wantIsWBNB = true;
            rabbitToWantPath = [_rabbitToken, wbnbAddress];
        } else {
            rabbitToWantPath = [_rabbitToken, wbnbAddress, _wantAddress];
        }

        uniRouterAddress = _uniRouterAddress;

        vault = _vault;
        rabbitVaultToken = IERC20(_rabbitVaultToken);
        IRabbitVault.TokenBank memory bank = rabbitVault.banks(address(rabbitVaultToken));
        rabbitVaultIbToken = IERC20(bank.ibTokenAddr);
        
        wantToken.safeApprove(_rabbitVault, uint256(-1));
        rabbitVaultIbToken.safeApprove(_fairLaunchAddress, uint256(-1));
        rabbitToken.safeApprove(uniRouterAddress, uint256(-1));
    }

    modifier onlyVault() {
        require (msg.sender == vault, "Must from vault");
        _;
    }

    modifier onlyVaultOrKeeper() {
        require (msg.sender == vault || keepers[msg.sender], "Must from vault/keeper");
        _;
    }

    function rabbitVaultTotalToken() public view returns (uint256) {
        IRabbitVault.TokenBank memory bank = rabbitVault.banks(address(rabbitVaultToken));

        uint256 reservePool = bank.totalReserve;
        uint256 vaultDebtVal = bank.totalDebt;
        if (now > bank.lastInterestTime) {
            uint256 timePast = now.sub(bank.lastInterestTime);
            uint256 totalBalance = rabbitVault.totalToken(address(rabbitVaultToken));
            uint256 ratePerSec = IVaultConfig(rabbitVault.config()).getInterestRate(vaultDebtVal, totalBalance);
            uint256 interest = ratePerSec.mul(timePast).mul(vaultDebtVal).div(1e18);
            
            uint256 toReserve = interest.mul(IVaultConfig(rabbitVault.config()).getReserveBps()).div(10000);
            
            reservePool = bank.totalReserve.add(toReserve);
            vaultDebtVal = bank.totalDebt.add(interest);
        }
        return wantToken.balanceOf(address(rabbitVault)).add(vaultDebtVal).sub(reservePool);
    }
    
    function _ibDeposited() internal view returns (uint256) {
        (uint256 ibBal,,,) = fairLaunch.userInfo(poolId, address(this));
        return ibBal;
    }

    function totalBalance() external override view returns (uint256) {
        uint256 ibBal = _ibDeposited();
        return rabbitVaultTotalToken().mul(ibBal).div(rabbitVaultIbToken.totalSupply());
    }

    function wantAmtToIbAmount(uint256 _wantAmt) public view returns (uint256) {
        return _wantAmt.mul(rabbitVaultIbToken.totalSupply()).div(rabbitVaultTotalToken());
    }

    function deposit(uint256 _wantAmt)
        external
        override
        onlyVault
        nonReentrant
    {
        IERC20(wantToken).safeTransferFrom(
            address(msg.sender),
            address(this),
            _wantAmt
        );

        rabbitVault.deposit(address(rabbitVaultToken), _wantAmt);
        fairLaunch.deposit(address(this), poolId, rabbitVaultIbToken.balanceOf(address(this)));
    }

    function withdraw(uint256 _wantAmt)
        external
        override
        onlyVault
        nonReentrant
    {
        uint256 ibAmt = wantAmtToIbAmount(_wantAmt);
        fairLaunch.withdraw(address(this), poolId, ibAmt);
        rabbitVault.withdraw(address(rabbitVaultToken), rabbitVaultIbToken.balanceOf(address(this)));

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
        if (_ibDeposited() == 0) {
            return;
        }

        // Collect rabbitToken
        fairLaunch.harvest(poolId);

        uint256 earnedAlpacaBalance = rabbitToken.balanceOf(address(this));
        if (earnedAlpacaBalance == 0) {
            return;
        }

        if (rabbitToken != wantToken) {
            IPancakeRouter02(uniRouterAddress).swapExactTokensForTokens(
                earnedAlpacaBalance,
                earnedAlpacaBalance.mul(priceMin).div(1e18),
                rabbitToWantPath,
                address(this),
                now.add(600)
            );
        }

        rabbitVault.deposit(address(rabbitVaultToken), IERC20(wantToken).balanceOf(address(this)));
        fairLaunch.deposit(address(this), poolId, rabbitVaultIbToken.balanceOf(address(this)));

        lastHarvestBlock = block.number;
    }

    function harvest(uint256 minPrice) external override onlyVaultOrKeeper nonReentrant {
        _harvest(minPrice);
    }

    /**
     * @dev Pauses the strat.
     */
    function pause() external onlyOwner {
        _pause();

        rabbitToken.safeApprove(uniRouterAddress, 0);
        wantToken.safeApprove(uniRouterAddress, 0);
    }

    /**
     * @dev Unpauses the strat.
     */
    function unpause() external onlyOwner {
        _unpause();

        rabbitToken.safeApprove(uniRouterAddress, uint256(-1));
        wantToken.safeApprove(uniRouterAddress, uint256(-1));
    }

    function setVault(address _vault) external onlyOwner {
        vault = _vault;
    }

    function setKeepers(address[] calldata _keepers, bool[] calldata _states) external onlyOwner {
        uint256 n = _keepers.length;
        for(uint256 i = 0; i < n; i++) {
            keepers[_keepers[i]] = _states[i];
        }
        emit KeepersSet(_keepers, _states);
    }

    receive() external payable {}
}