// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0;

/**
 * @title Project
 */
contract Voting {
    enum VoteSchema { PercentAbsolute, PercentParticipant, DifferenceOfVotes }
    
    struct VoteFilter {
        VoteSchema Schema;
        uint64 Value;
    }
    
    struct VoteProperty {
        uint32 Duration;
        
        VoteFilter[] Filters;
    }
}