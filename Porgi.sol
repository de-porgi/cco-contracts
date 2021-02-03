pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import "./Voting.sol";
import "./Project.sol";
import "https://github.com/de-porgi/minime/blob/master/contracts/MiniMeToken.sol";

/**
 * @title Porgi
 */
contract Porgi {
    
    enum ProjectState { None, New, Presale, InProgress, Finished, Canceled }
    
    modifier onlyChildProject { require(_ProjectStatistic[Project(msg.sender)].State != ProjectState.None, "Porgi: Not child project"); _; }
    
    struct Statistic {
        ProjectState State;
        uint32 Index;
    }
    
    mapping(address => Project[]) private _Projects;
    address[] private _ProjectsOwners;
    mapping(ProjectState => Project[]) private _IndexedProjectsByState;
    mapping(Project => Statistic) private _ProjectStatistic;
    
    MiniMeTokenFactory public TokenFactory;
    VotingSimpleFactory public VotingFactory;
    ProjectSimpleFactory public ProjectFactory;
    
    // AaveGateWay in Kovan testnet 0xf8aC10E65F2073460aAD5f28E1EABE807DC287CF;
    // AaveGateWay in Main net 0xdcd33426ba191383f1c9b431a342498fdac73488;
    IWETHGateway public AaveWETHGateway;
    // 1inch exchange in Main net 0x111111125434b319222cdbf8c261674adb56f3ae;
    IOneInchExchange public LinchExchange;
    
    constructor(MiniMeTokenFactory token, VotingSimpleFactory voting, ProjectSimpleFactory project, IWETHGateway gateway, IOneInchExchange exchange) public {
        TokenFactory = token;
        VotingFactory = voting;
        ProjectFactory = project;
        AaveWETHGateway = gateway;
        LinchExchange = exchange;
    }

    function AddProject(Common.InitProjectProperty memory property) external returns (Project newProject) {
        newProject = ProjectFactory.CreateProject(this);
        newProject.Init(property);
        _Projects[msg.sender].push(newProject);
        if (_Projects[msg.sender].length == 1) {
            _ProjectsOwners.push(msg.sender);
        }
        _ProjectStatistic[newProject].State = ProjectState.New;
        _ProjectStatistic[newProject].Index = uint32(_IndexedProjectsByState[ProjectState.New].length);
        _IndexedProjectsByState[ProjectState.New].push(newProject);
    }
    
    function ChangeState(ProjectState state) external onlyChildProject {
        _changeState(Project(msg.sender), state);
    }
    
    function GetProjectsOwners() external view returns (address[] memory) {
        return _ProjectsOwners;
    }
    
    function GetProjectsOf(address owner) external view returns (Project[] memory) {
        return _Projects[owner];
    }
    
    function GetProjectsBy(ProjectState state) external view returns (Project[] memory) {
        return _IndexedProjectsByState[state];
    }
    
    function GetProjectStatistic(Project project) external view returns (Statistic memory) {
        return _ProjectStatistic[project];
    }
    
    function _changeState(Project project, ProjectState newState) private {
        Statistic storage stat = _ProjectStatistic[project];
        require(stat.State != newState, "Porgi: state didn't change");
        require(_IndexedProjectsByState[stat.State][stat.Index] == project, "Porgi: project index mismatch");
        
        if ((stat.Index + 1) != uint32(_IndexedProjectsByState[stat.State].length)) {
            // If the `project` is not last, let's swap it with last project.
            Project lastProject = _IndexedProjectsByState[stat.State][_IndexedProjectsByState[stat.State].length - 1];
            _IndexedProjectsByState[stat.State][stat.Index] = lastProject;
            _ProjectStatistic[lastProject].Index = stat.Index;
        }
        
        _IndexedProjectsByState[stat.State].pop();
        stat.State = newState;
        stat.Index = uint32(_IndexedProjectsByState[newState].length);
        _IndexedProjectsByState[newState].push(project);
    }
}