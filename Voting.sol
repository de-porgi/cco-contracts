pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import "./Project.sol";
import "./Time.sol";
import "./Common.sol";
import "https://github.com/de-porgi/aave_v2/blob/main/contracts/dependencies/openzeppelin/contracts/SafeMath.sol";

/**
 * @title Voting
 */
contract Voting is Time {
    using SafeMath for uint256;
    
    modifier onlyProject { require(msg.sender == address(_Project), "Voting: Sender is not a Project"); _; }
    modifier onlyHolder { require(msg.sender == _Project.Owner() || _Project.balanceOf(msg.sender) > 0, "Voting: Sender is not a holder"); _; }
    modifier notFinished { require(Result == Common.VoteResult.None, "Voting: Already is finished"); _; }
    
    uint8 constant PercentAbsolute = 1;
    uint8 constant PercentParticipant = 2;
    uint8 constant DifferenceOfVotes = 4;
    
    struct VotingInfo {
        uint64 TimestampStart;
        uint256 BlockStart;
    
        uint256 TotalYes;
        uint256 TotalNo;
        uint256 TotalSupply;
        Common.VoteResult Result;
        Common.VoteProperty Property;
    }
    
    uint64 public TimestampStart;
    uint256 public BlockStart;
    
    uint256 public TotalYes;
    uint256 public TotalNo;
    uint256 public TotalSupply;
    Common.VoteResult public Result;
    
    mapping(address => Common.VoteType) public Votes;
    Project private _Project;
    Common.VoteProperty private _Property;
    
    constructor (Project prj, Common.VoteProperty memory property) public {
        _Project = prj;
        _Property.Duration = property.Duration;
        require(property.Filters.length > 0, "Voting: Zero filters");
        uint8 temp = 0;
        for (uint8 i = 0; i < property.Filters.length; ++i) {
            if (property.Filters[i].Schema == PercentAbsolute || property.Filters[i].Schema == PercentParticipant) {
                require(property.Filters[i].Value <= 100, "Voting: Percent more 100");
            }
            _Property.Filters.push(property.Filters[i]);
            temp ^= property.Filters[i].Schema;
            require((temp & property.Filters[i].Schema) != 0, "Voting: Duplicate filters");
        }
    }
    
    function Start() external onlyHolder notFinished {
        require(_Project.ActiveVoting() == this, "Voting: Is not current voting");
        require(BlockStart == 0, "Voting: Already started");
        TimestampStart = getTimestamp64();
        BlockStart = block.number;
        TotalSupply = _Project.totalSupplyAt(BlockStart);
    }
    
    function Cancel() external onlyProject notFinished {
        selfdestruct(address(_Project));
    }
    
    function Finish() external onlyHolder notFinished {
        require(TimestampStart != 0, "Voting: Is not started");
        require(!IsOpen());
        
        bool positive = true;
        for (uint i = 0; i < _Property.Filters.length; ++i) {
            if (_Property.Filters[i].Schema == PercentParticipant) {
                positive = positive && TotalYes.mul(100) > TotalYes.add(TotalNo).mul(_Property.Filters[i].Value);
            } else if (_Property.Filters[i].Schema == PercentAbsolute) {
                positive = positive && TotalYes.mul(100) > TotalSupply.mul(_Property.Filters[i].Value);
            } else if (_Property.Filters[i].Schema == DifferenceOfVotes) {
                positive = positive && TotalYes > TotalNo.add(_Property.Filters[i].Value);
            }
        }
        
        if (positive) {
            _Project.FinishVoting(Common.VoteResult.Positive);
            Result = Common.VoteResult.Positive;
        } else {
            _Project.FinishVoting(Common.VoteResult.Negative);
            Result = Common.VoteResult.Negative;
        }
    }
    
    function Vote(Common.VoteType t) external onlyHolder {
        require(IsOpen(), "Voting: Is not opened/started");
        require((t == Common.VoteType.NO) || (t == Common.VoteType.YES), "Voting: Unknown vote type");
        
        if (Votes[msg.sender] == Common.VoteType.NONE) {
            if (t == Common.VoteType.NO) {
                TotalNo = TotalNo.add(_Project.balanceOfAt(msg.sender, BlockStart));
            } else {
                TotalYes = TotalYes.add(_Project.balanceOfAt(msg.sender, BlockStart));
            }
        } else if (Votes[msg.sender] == Common.VoteType.NO && t == Common.VoteType.YES) {
            uint balance = _Project.balanceOfAt(msg.sender, BlockStart);
            TotalNo = TotalNo.sub(balance, "Voting: vote amount exceeds total no");
            TotalYes = TotalYes.add(balance);
        } else if (Votes[msg.sender] == Common.VoteType.YES && t == Common.VoteType.NO)  {
            uint balance = _Project.balanceOfAt(msg.sender, BlockStart);
            TotalNo = TotalNo.add(balance);
            TotalYes = TotalYes.sub(balance, "Voting: Vote amount exceeds total yes");
        }
        
        Votes[msg.sender] = t;
    }
    
    function IsOpen() public view returns (bool) {
        return Result == Common.VoteResult.None && getTimestamp64() < (TimestampStart + _Property.Duration) && TimestampStart != 0;
    }
    
    function GetProperty() public view returns (Common.VoteProperty memory) {
        return _Property;
    }
    
    function GetVotingInfo() external view returns (VotingInfo memory info) {
        info.TimestampStart = TimestampStart;
        info.BlockStart = BlockStart;
        info.TotalYes = TotalYes;
        info.TotalNo = TotalNo;
        info.TotalSupply = TotalSupply;
        info.Result = Result;
        info.Property = _Property;
    }
}


/**
 * @title VotingSimpleFactory
 */
contract VotingSimpleFactory {
    function CreateVoting(Project prj, Common.VoteProperty memory property) external returns (Voting) {
        return new Voting(prj, property);
    }
}