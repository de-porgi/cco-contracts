// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.3.0/contracts/token/ERC20/ERC20.sol";
import "./Voting.sol";

/**
 * @title Project
 */
contract Project is ERC20 {
    
    struct Serie {
        uint32 Duration;
        
        // Percent of stake to unlock
        uint8 StakeUnlock;
        
        Voting.VoteProperty Vote;
    }
    
    struct Season {
        uint32 Duration;
        Serie[] Series;
    }
    
    struct ProjectProperty {
        string ProjectName;
        string TokenName;
        string TokenSymbol;
        uint32 Decimal;
        // How many tokens for one ether TODO: Maybe add in future support of different currencies
        uint256 TokenPrice;
        // Percent of tokens which will be created for owner of the project during mint process
        uint8 OwnerTokensPercent;
        
        Season[] Seasons;
    }
    
    constructor (ProjectProperty memory property) ERC20(property.TokenName, property.TokenSymbol) public {
    }

    /**
     */
    function store(uint256 amount) payable public {
        msg.sender.transfer(amount);
    }
}