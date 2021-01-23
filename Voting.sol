// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v3.3.0/contracts/token/ERC20/ERC20.sol";


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
contract Voting is ERC20 {
    using Uint256Helpers for uint256;
    
    enum VoteSchema { PercentAbsolute, PercentParticipant, DifferenceOfVotes }
    
    struct VoteFilter {
        VoteSchema Schema;
        uint64 Value;
    }
    
    struct VoteProperty {
        uint32 Duration;
        
        VoteFilter[] Filters;
    }
    
    enum VoteType { NO, YES }
    
    struct Vote {
        uint256 Weight;
        VoteType Type;
    }
    
    enum PollResult { None, Positive, Negative }
    
    struct Poll {
        uint64 Start;
        uint64 Duration;
        
        PollResult Result;
        uint256 TotalYes;
        uint256 TotalNo;
        uint256 TotalSupply;
    }
    
    mapping(address => Vote) private votes;
    
    Poll public CurrentPoll;
    Poll[] public PollHistory;
    
    constructor (string memory name, string memory symbol) ERC20(name, symbol) public {}
    
    function SendVote(VoteType t, uint256 amount) public {
        require(amount != 0, "Voting: Vote amount is zero");
        require(t == VoteType.YES || t == VoteType.NO, "Voting: Vote type is unknown");
        // During vote we can udpate type of vote
        Vote memory oldVote = votes[msg.sender];
        // Decrease total yes or no
        _unlock(msg.sender, oldVote.Weight);
        // Updates a new vote type. Now weight is zero
        votes[msg.sender].Type = t;
        // trasfer tokens to contract and update weight
        _transfer(msg.sender, address(this), amount);
        // Return back unlocked(in begin of this function) tokens
        _lock(msg.sender, oldVote.Weight);
    }
    
    function Withdraw(uint256 amount) public {
        // It will transfer money from name of contract
        this.transfer(msg.sender, amount);
    }
    
    function _startPoll(VoteProperty storage property) internal virtual {
        require(CurrentPoll.Start == 0, "Voting: Previous poll is not finished");
        CurrentPoll.Start = getTimestamp64();
        CurrentPoll.Duration = property.Duration;
    }
    
    function _finishPoll(VoteProperty storage property) internal virtual {
        require(_pollIsWaitingFinish(), "Voting: Poll is not reade for finish");
        
        bool positive = true;
        for (uint i = 0; i < property.Filters.length; ++i) {
            if (property.Filters[i].Schema == VoteSchema.PercentParticipant) {
                positive = positive && ((CurrentPoll.TotalYes / property.Filters[i].Value) > ((CurrentPoll.TotalYes + CurrentPoll.TotalNo) / 100));
            } else if (property.Filters[i].Schema == VoteSchema.PercentAbsolute) {
                positive = positive && ((CurrentPoll.TotalYes / property.Filters[i].Value) > (totalSupply() / 100));
            } else if (property.Filters[i].Schema == VoteSchema.DifferenceOfVotes) {
                positive = positive && ((CurrentPoll.TotalYes - CurrentPoll.TotalNo) > property.Filters[i].Value);
            }
        }
        
        if (positive) {
            CurrentPoll.Result = PollResult.Positive;
        } else {
            CurrentPoll.Result = PollResult.Negative;
        }
        CurrentPoll.TotalSupply = totalSupply();
        
        PollHistory.push() = CurrentPoll;
        CurrentPoll.Start = 0;
        CurrentPoll.Duration = 0;
        CurrentPoll.TotalSupply = 0;
        CurrentPoll.Result = PollResult.None;
    }
    
    function _transfer(address sender, address recipient, uint256 amount) internal override virtual {
        if (recipient == address(this)) {
            require(_canModifyVotes(), "Voting: Modify votes during poll finalization");
            _lock(sender, amount);
        } else if (sender == address(this)) {
            require(_canModifyVotes(), "Voting: Modify votes during poll finalization");
            _unlock(sender, amount);
        }
        super._transfer(sender, recipient, amount);
    }
    
    function _lock(address sender, uint256 amount) internal {
        votes[sender].Weight = votes[sender].Weight.add(amount);
        if (votes[sender].Type == VoteType.YES) {
            CurrentPoll.TotalYes = CurrentPoll.TotalYes.add(amount);
        } else {
            CurrentPoll.TotalNo = CurrentPoll.TotalNo.add(amount);
        }
    }
    
    function _unlock(address sender, uint256 amount) internal {
        votes[sender].Weight = votes[sender].Weight.sub(amount, "Voting: unlock amount exceeds balance");
        if (votes[sender].Type == VoteType.YES) {
            CurrentPoll.TotalYes = CurrentPoll.TotalYes.sub(amount, "Voting: unlock amount exceeds total yes");
        } else {
            CurrentPoll.TotalNo = CurrentPoll.TotalNo.sub(amount, "Voting: unlock amount exceeds total no");
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
    
    function _pollIsOpen() internal view returns (bool) {
        return CurrentPoll.Start != 0 && getTimestamp64() < (CurrentPoll.Start + CurrentPoll.Duration);
    }
    
    function _pollIsWaitingFinish() internal view returns (bool) {
        return CurrentPoll.Start != 0 && getTimestamp64() >= (CurrentPoll.Start + CurrentPoll.Duration);
    }
    
    function _canModifyVotes() internal view returns (bool) {
        return CurrentPoll.Start == 0 || getTimestamp64() < (CurrentPoll.Start + CurrentPoll.Duration);
    }
}