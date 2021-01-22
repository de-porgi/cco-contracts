// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import "./Project.sol";
import "./IProjectManager.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.3.0/contracts/introspection/ERC165.sol";

/**
 * @title Project
 */
contract Porgi is ERC165, IProjectManager {
    
    mapping(address => address[]) public Projects;

    /**
     */
    function AddProject(Project.ProjectProperty memory property) public returns (address newProject) {
        Project c = new Project(property, address(this));
        newProject = address(c);
        Projects[msg.sender].push(newProject);
    }
    
    function GetProjects(address owner) public view returns (address[] memory ownedProjects) {
        ownedProjects = Projects[owner];
    }
}