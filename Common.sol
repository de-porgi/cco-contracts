pragma solidity >=0.6.0;

contract Common {
    struct VoteFilter {
        uint8 Schema;
        uint64 Value;
    }
    
    struct VoteProperty {
        uint64 Duration;
        
        VoteFilter[] Filters;
    }
    
    enum VoteType { NONE, NO, YES }
    
    enum VoteResult { None, Negative, Positive }
    
    struct InitSeries {
        uint64 Duration;
        
        // Percent of stake to unlock
        uint8 StakeUnlock;
        
        Common.VoteProperty Vote;
    }
    
    struct InitFirstSeason {
        InitFistPresale Presale;
        InitSeries[] Series;
    }

    struct InitNextSeason {
        InitSecondaryPresale Presale;
        InitSeries[] Series;
    }

    struct InitFistPresale {
        // How many tokens for one ether TODO: Maybe add in future support of different currencies
        uint256 TokenPrice;
        // Percent of tokens which will be created for owner of the project during mint process
        uint8 OwnerTokensPercent;
        uint64 Duration;
    }

    struct InitSecondaryPresale {
        uint256 TokensEmissionPercent;
        uint64 Emissions;
        uint8 OwnerTokensPercent;
        uint64 TimeBetweenEmissions;
    }

    struct InitProjectProperty {
        string ProjectName;
        string TokenName;
        string TokenSymbol;
        uint8 TokenDecimal;
        InitFirstSeason FirstSeason;
        InitNextSeason[] NextSeasons;
    }
}