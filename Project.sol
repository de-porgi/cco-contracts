// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import "./Voting.sol";
import "./IProjectManager.sol";

/**
 * @title Project
 */
contract Project is Voting {
    
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
        uint32 Decimal;
        // How many tokens for one ether TODO: Maybe add in future support of different currencies
        uint256 TokenPrice;
        // Percent of tokens which will be created for owner of the project during mint process
        uint8 OwnerTokensPercent;
        
        Season[] Seasons;
    }
    
    /* 
     * TODO:
     * bytes4(keccak256('supportsInterface(bytes4)')) == 0x01ffc9a7
     */
    bytes4 private constant _INTERFACE_ID_PROJECT_MANAGER = 0x01ffc9a7;
    
    address public Owner;
    address public ProjectManager;
    
    constructor (ProjectProperty memory property, address projectManager) Voting(property.TokenName, property.TokenSymbol) public {
        Owner = tx.origin;
        ProjectManager = projectManager;
        IProjectManager(projectManager).supportsInterface(_INTERFACE_ID_PROJECT_MANAGER);
    }
}