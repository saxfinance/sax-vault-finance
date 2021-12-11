// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.6.0;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Interfaces.sol";

contract BnbHelper{
    using SafeERC20 for IERC20;
    address public wbnbAddress;
    
    constructor() public{
        wbnbAddress = address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    }
    
    function deposit() public payable {
        uint256 bnbBal = msg.value;
        if (bnbBal > 0) {
            IWBNB(wbnbAddress).deposit{value: bnbBal}();
        }
        
        IERC20(wbnbAddress).safeTransfer(
            address(msg.sender),
            bnbBal
        );
    }

    function unwrapBNB(uint256 wbnbAmount) public {
        IERC20(wbnbAddress).safeTransferFrom(
            address(msg.sender),
            address(this),
            wbnbAmount
        );
        IWBNB(wbnbAddress).withdraw(wbnbAmount);
        
        (bool success, ) = msg.sender.call{value:wbnbAmount}(new bytes(0));
        require(success, "!safeTransferBNB");
    }
    
    fallback() external payable {}
    receive() external payable {}
}