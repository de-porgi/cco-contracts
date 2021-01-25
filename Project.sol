// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import "./Voting.sol";
import "./Porgi.sol";

import "https://github.com/aave/protocol-v2/blob/master/contracts/misc/WETHGateway.sol";
import "https://github.com/aave/protocol-v2/blob/master/contracts/dependencies/openzeppelin/contracts/SafeMath.sol";
import "https://github.com/de-porgi/minime/blob/master/contracts/MiniMeToken.sol";
import "https://github.com/aave/protocol-v2/blob/master/contracts/dependencies/openzeppelin/contracts/ERC20.sol";

/**
 * @title Project
 */
contract Project is MiniMeToken {

    using SafeMath for uint256;
    
    struct Serie {
        uint32 Duration;
        
        // Percent of stake to unlock
        uint8 StakeUnlock;
        
        Voting.VoteProperty Vote;
    }
    
    struct Season {
        Serie[] Series;
    }
    
    struct ProjectProperty {
        string ProjectName;
        string TokenName;
        string TokenSymbol;
        uint8 TokenDecimal;
        // How many tokens for one ether TODO: Maybe add in future support of different currencies
        uint256 TokenPrice;
        // Percent of tokens which will be created for owner of the project during mint process
        uint8 OwnerTokensPercent;
        uint64 PresaleDuration;
        
        Season[] Seasons;
    }
    
    address payable private constant _DEPOSIT_ADDRESS = 0xf8aC10E65F2073460aAD5f28E1EABE807DC287CF;
    
    address public Owner;
    Porgi private _Porgi;
    WETHGateway private _DepositManager;
    
    constructor (ProjectProperty memory property, Porgi porgi, MiniMeTokenFactory factory) 
        MiniMeToken(
            factory,
            MiniMeToken(address(0)),
            0 /* _parentSnapShotBlock */,
            property.TokenName,
            property.TokenDecimal,
            property.TokenSymbol,
            true /* _transfersEnabled */) public {
        
        Owner = tx.origin;
        _Porgi = porgi;
        _DepositManager = WETHGateway(_DEPOSIT_ADDRESS);
        // Anyone can't controll this units TODO: Do we need permissions to controll units by Porgi?
        changeController(address(this));
    }
    
    receive() external payable {}
    
    function _makeDeposit(uint256 amount) private {
        require(address(this).balance >= amount, "Not Enough ETH to Deposit");
        _DepositManager.depositETH{value: amount}(address(this), 0);
    }
    
    function _withdrawDeposit(uint256 amount) private {
        ERC20 aWETH = ERC20(_DepositManager.getAWETHAddress());
        require(aWETH.approve(_DEPOSIT_ADDRESS, amount), "Not Enough aWETH to Withdraw");
        _DepositManager.withdrawETH(amount, address(this));
    }
	
	function GetETHBalance() public view returns (uint256) {
        ERC20 aWETH = ERC20(_DepositManager.getAWETHAddress());
        return aWETH.balanceOf(address(this));
    }
    
    function withdrawETH() public payable {
        // project is closed TODO Add corresponding variable
        require(false, "Project Is Not Closed");
        uint256 totalEth = GetETHBalance();
        uint256 totalSupply = totalSupply();
        uint256 senderTokens = balanceOf(msg.sender);
        uint256 ETHToWithdraw =  totalEth.mul(senderTokens).div(totalSupply);
        destroyTokens(msg.sender, senderTokens);
        _safeTransferETH(msg.sender, ETHToWithdraw);
    }
    
    function _safeTransferETH(address to, uint256 value) private {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');
    }
    
    function _unlockETH(uint8 numerator, uint8 denominator) private {
        uint256 balance = GetETHBalance();
        uint256 toUnlock = balance.mul(numerator).div(denominator);
        _withdrawDeposit(toUnlock);
        _safeTransferETH(msg.sender, toUnlock);
    }
}