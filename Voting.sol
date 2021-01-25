// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import "./Project.sol";
import "./Time.sol";
import "https://github.com/aave/protocol-v2/blob/master/contracts/dependencies/openzeppelin/contracts/SafeMath.sol";

/**
 * @title Voting
 */
contract Voting is Time {
    using SafeMath for uint256;
    
    modifier onlyProject { require(msg.sender == address(_Project), "Voring: sender is not Project"); _; }
    modifier onlyHolder { require(_Project.balanceOf(msg.sender) > 0, "Project: sender is not holder"); _; }
    
    uint8 constant PercentAbsolute = 1;
    uint8 constant PercentParticipant = 2;
    uint8 constant DifferenceOfVotes = 4;
    
    struct VoteFilter {
        uint8 Schema;
        uint64 Value;
    }
    
    struct VoteProperty {
        uint64 Duration;
        
        VoteFilter[] Filters;
    }
    
    enum VoteType { NONE, NO, YES }
    
    enum VoteResult { None, Positive, Negative }
    
    uint64 public TimestampStart;
    uint256 public BlockStart;
    VoteProperty public Property;
    
    uint256 public TotalYes;
    uint256 public TotalNo;
    uint256 public TotalSupply;
    VoteResult public Result;
    
    mapping(address => VoteType) public Votes;
    Project private _Project;
    
    constructor (Project _prj, VoteProperty memory property) public {
        _Project = _prj;
        Property.Duration = property.Duration;
        uint8 temp = 0;
        for (uint8 i = 0; i < property.Filters.length; ++i) {
            Property.Filters.push(property.Filters[i]);
            temp ^= property.Filters[i].Schema;
            require((temp & property.Filters[i].Schema) == 0, "Voring: duplicate filters");
        }
    }
    
    function Start() external onlyHolder {
        require(_Project.CurrentVoting() == this, "Voting: Is not current voting");
        require(BlockStart == 0, "Voting: Already started");
        require(Result == VoteResult.None, "Voting: Already has result");
        TimestampStart = getTimestamp64();
        BlockStart = block.number;
        TotalSupply = _Project.totalSupplyAt(BlockStart);
    }
    
    function Cancel() external onlyProject {
        require(Result == VoteResult.None, "Voting: Already has result");
        selfdestruct(address(_Project));
    }
    
    function Finish() external onlyHolder {
        require(Result == VoteResult.None, "Voting: Already has result");
        require(TimestampStart != 0, "Voting: Is not started");
        require(!IsOpen(), "Voting: In progress");
        
        bool positive = true;
        for (uint i = 0; i < Property.Filters.length; ++i) {
            if (Property.Filters[i].Schema == PercentParticipant) {
                positive = positive && TotalYes.mul(100) > TotalYes.add(TotalNo).mul(Property.Filters[i].Value);
            } else if (Property.Filters[i].Schema == PercentAbsolute) {
                positive = positive && TotalYes.mul(100) > TotalSupply.mul(Property.Filters[i].Value);
            } else if (Property.Filters[i].Schema == DifferenceOfVotes) {
                positive = positive && TotalYes > TotalNo.add(Property.Filters[i].Value);
            }
        }
        
        if (positive) {
            Result = VoteResult.Positive;
        } else {
            Result = VoteResult.Negative;
        }
        
        _Project.FinishSeries();
    }
    
    function Vote(VoteType t) external onlyHolder {
        require(IsOpen(), "Voting: In progress");
        require(t == VoteType.NO || t == VoteType.YES, "Voting: unknown vote type");
        
        if (Votes[msg.sender] == VoteType.NONE) {
            if (t == VoteType.NO) {
                TotalNo = TotalNo.add(_Project.balanceOfAt(msg.sender, BlockStart));
            } else {
                TotalYes = TotalYes.add(_Project.balanceOfAt(msg.sender, BlockStart));
            }
        } else if (Votes[msg.sender] == VoteType.NO && t == VoteType.YES) {
            uint balance = _Project.balanceOfAt(msg.sender, BlockStart);
            TotalNo = TotalNo.sub(balance, "Voting: vote amount exceeds total no");
            TotalYes = TotalYes.add(balance);
        } else if (Votes[msg.sender] == VoteType.YES && t == VoteType.NO)  {
            uint balance = _Project.balanceOfAt(msg.sender, BlockStart);
            TotalNo = TotalNo.add(balance);
            TotalYes = TotalYes.sub(balance, "Voting: vote amount exceeds total yes");
        }
        
        Votes[msg.sender] = t;
    }
    
    function IsOpen() public view returns (bool) {
        return Result == VoteResult.None && getTimestamp64() < (TimestampStart + Property.Duration) && TimestampStart != 0;
    }
}