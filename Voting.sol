// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import "./Project.sol";

library Uint256Helpers {
    uint256 private constant MAX_UINT64 = uint64(-1);

    string private constant ERROR_NUMBER_TOO_BIG = "UINT64_NUMBER_TOO_BIG";

    function toUint64(uint256 a) internal pure returns (uint64) {
        require(a <= MAX_UINT64, ERROR_NUMBER_TOO_BIG);
        return uint64(a);
    }
}

/**
 * @title Voting
 */
contract Voting {
    using Uint256Helpers for uint256;
    
    modifier onlyProject { require(msg.sender == address(_Project), "Voring: modifier is not Project"); _; }
    
    uint8 constant PercentAbsolute = 1;
    uint8 constant PercentParticipant = 2;
    uint8 constant DifferenceOfVotes = 4;
    
    struct VoteFilter {
        uint8 Schema;
        uint64 Value;
    }
    
    struct VoteProperty {
        uint32 Duration;
        
        VoteFilter[] Filters;
    }
    
    enum VoteType { NONE, NO, YES }
    
    enum VoteResult { None, Positive, Negative, Canceled }
    
    uint64 public Start;
    VoteProperty public Property;
    
    VoteResult public Result;
    uint256 public TotalYes;
    uint256 public TotalNo;
    uint256 public TotalSupply;
    
    mapping(address => VoteType) public Votes;
    Project private _Project;
    uint256 private _BlockStart;
    
    constructor (Project _prj, VoteProperty memory property) public {
        _Project = _prj;
        Start = getTimestamp64();
        Property.Duration = property.Duration;
        uint8 temp = 0;
        for (uint8 i = 0; i < property.Filters.length; ++i) {
            Property.Filters.push(property.Filters[i]);
            temp ^= property.Filters[i].Schema;
            require((temp & property.Filters[i].Schema) == 0, "Voring: duplicate filters");
        }
        _BlockStart = block.number;
        TotalSupply = _Project.totalSupplyAt(_BlockStart);
    }
    
    function Vote(VoteType t) public virtual {
        require(IsOpen(), "Voting: In progress");
        require(t == VoteType.NO || t == VoteType.YES, "Voting: unknown vote type");
        
        if (Votes[msg.sender] == VoteType.NONE) {
            if (t == VoteType.NO) {
                TotalNo += _Project.balanceOfAt(msg.sender, _BlockStart);
            } else {
                TotalYes += _Project.balanceOfAt(msg.sender, _BlockStart);
            }
        } else if (Votes[msg.sender] == VoteType.NO && t == VoteType.YES) {
            uint balance = _Project.balanceOfAt(msg.sender, _BlockStart);
            TotalNo -= balance;
            TotalYes += balance;
        } else if (Votes[msg.sender] == VoteType.YES && t == VoteType.NO)  {
            uint balance = _Project.balanceOfAt(msg.sender, _BlockStart);
            TotalNo += balance;
            TotalYes -= balance;
        }
        
        Votes[msg.sender] = t;
    }
    
    function Cancel() public virtual onlyProject {
        require(Result == VoteResult.None, "Voting: Already has result");
        Result = VoteResult.Canceled;
    }
    
    function Finish() public virtual {
        require(Result == VoteResult.None, "Voting: Already has result");
        require(!IsOpen(), "Voting: In progress");
        
        bool positive = true;
        for (uint i = 0; i < Property.Filters.length; ++i) {
            if (Property.Filters[i].Schema == PercentParticipant) {
                positive = positive && ((TotalYes * 100) > ((TotalYes + TotalNo) * Property.Filters[i].Value));
            } else if (Property.Filters[i].Schema == PercentAbsolute) {
                positive = positive && ((TotalYes * 100) > (TotalSupply * Property.Filters[i].Value));
            } else if (Property.Filters[i].Schema == DifferenceOfVotes) {
                positive = positive && (TotalYes > (Property.Filters[i].Value + TotalNo));
            }
        }
        
        if (positive) {
            Result = VoteResult.Positive;
        } else {
            Result = VoteResult.Negative;
        }
    }

    /**
    * @dev Returns the current timestamp.
    *      Using a function rather than `block.timestamp` allows us to easily mock it in
    *      tests.
    */
    function getTimestamp() internal view returns (uint256) {
        return block.timestamp; // solium-disable-line security/no-block-members
    }

    /**
    * @dev Returns the current timestamp, converted to uint64.
    *      Using a function rather than `block.timestamp` allows us to easily mock it in
    *      tests.
    */
    function getTimestamp64() internal view returns (uint64) {
        return getTimestamp().toUint64();
    }
    
    function IsOpen() public virtual view returns (bool) {
        return Result == VoteResult.None && getTimestamp64() < (Start + Property.Duration);
    }
}