// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import "./Project.sol";
import "https://github.com/de-porgi/minime/blob/master/contracts/MiniMeToken.sol";

/**
 * @title Porgi
 */
contract Porgi {
    
    mapping(address => Project[]) public Projects;
    
    MiniMeTokenFactory private _Factory;
    
    constructor() public {
        _Factory = new MiniMeTokenFactory();
    }

    /**
     */
    function AddProject(Project.InitProjectProperty memory property) external returns (Project newProject) {
        newProject = new Project(property, this, _Factory);
        Projects[msg.sender].push(newProject);
    }
    
    function GetProjectsBy(address owner) external view returns (Project[] memory ownedProjects) {
        ownedProjects = Projects[owner];
    }
}