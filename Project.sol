// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import "./Voting.sol";
import "./Porgi.sol";
import "./Time.sol";

import "https://github.com/aave/protocol-v2/blob/master/contracts/misc/WETHGateway.sol";
import "https://github.com/aave/protocol-v2/blob/master/contracts/dependencies/openzeppelin/contracts/SafeMath.sol";
import "https://github.com/aave/protocol-v2/blob/master/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import "https://github.com/de-porgi/minime/blob/master/contracts/MiniMeToken.sol";

/**
 * @title Project
 */
contract Project is MiniMeToken, Time {

    using SafeMath for uint256;

    // Sender is not owner
    modifier onlyOwner { require(msg.sender == address(Owner)); _; }
    // Sender is not holder
    modifier onlyHolder { require(balanceOf(msg.sender) > uint256(0)); _; }
    // Sender is not current voting
    modifier onlyCurrentVoting { require(msg.sender == address(CurrentVoting())); _; }

    struct InitSeries {
        uint64 Duration;
        
        // Percent of stake to unlock
        uint8 StakeUnlock;
        
        Voting.VoteProperty Vote;
    }
    
    struct InitSeason {
        InitSeries[] Series;
    }

    struct InitPresale {
        // How many tokens for one ether TODO: Maybe add in future support of different currencies
        uint256 TokenPrice;
        // Percent of tokens which will be created for owner of the project during mint process
        uint8 OwnerTokensPercent;
        uint64 Duration;
    }
    
    struct InitProjectProperty {
        string ProjectName;
        string TokenName;
        string TokenSymbol;
        uint8 TokenDecimal;
        InitPresale Presale;
        
        InitSeason[] Seasons;
    }

    struct SeriesStruct {
        uint64 Start;
        uint64 Duration;
        uint8 StakeUnlock;
        Voting Vote;
    }

    struct TokenPresale {
        uint8 OwnerPercent;
        uint256 Price;
        uint64 Start;
        uint64 Duration;
        uint256 TotalGenerated;
    }

    struct Season {
        TokenPresale Presale;
        int8 ActiveSeries;
        uint8 StakePercentsLeft;
        SeriesStruct[] Series;
    }

    enum ProjectState {
        Unknown,
        PresaleIsNotStarted,
        PresaleInProgress,
        PresaleFinishing,
        SeriesInProgress,
        SeriesFinishing,
        NextSeriesVotingInProgress,
        NextSeriesVotingFinishing,
        SeasonFinishing,
        ProjectFinished,
        ProjectCanceled
    }
    
    // It is address in Kovan testnet.
    address payable private constant _DEPOSIT_ADDRESS = 0xf8aC10E65F2073460aAD5f28E1EABE807DC287CF;
    
    string public ProjectName;
    address public Owner;

    uint8 private ActiveSeason;
    Season[] private Seasons;

    Porgi private _Porgi;
    WETHGateway private _DepositManager;
    
    constructor (InitProjectProperty memory property, Porgi porgi, MiniMeTokenFactory factory)
        MiniMeToken(
            factory,
            MiniMeToken(address(0)) /* _parentToken */,
            0 /* _parentSnapShotBlock */,
            property.TokenName,
            property.TokenDecimal,
            property.TokenSymbol,
            true /* _transfersEnabled */) public {

        // Decimal can't be lower than eth decimal
        require(property.TokenDecimal >= 18);
        // Price lower than ether
        require(property.Presale.TokenPrice >= 1 ether);

        for (uint8 i = 0; i < property.Seasons.length; ++i) {
            require(property.Presale.OwnerTokensPercent < 100);
            Season storage season = Seasons.push();
            season.Presale.OwnerPercent = property.Presale.OwnerTokensPercent;
            season.Presale.Price = property.Presale.TokenPrice;
            season.Presale.Duration = property.Presale.Duration;
            season.ActiveSeries = -1;
    
            uint8 totalPercent = 0;
            for (uint8 j = 0; j < property.Seasons[i].Series.length; ++j) {
                // Stake unlock more 100
                require(property.Seasons[i].Series[j].StakeUnlock <= 100);
                SeriesStruct storage series = Seasons[i].Series.push();
                series.Duration = property.Seasons[i].Series[j].Duration;
                series.StakeUnlock = property.Seasons[i].Series[j].StakeUnlock;
                // We don't need voting for the latest Series, because we have already unlocked all tokens for season=)
                if ((j + 1) != property.Seasons[i].Series.length) {
                    series.Vote = new Voting(this, property.Seasons[i].Series[j].Vote);
                }
                totalPercent += property.Seasons[i].Series[j].StakeUnlock;
            }
            // Total stake percent must be 100
            require(totalPercent == 100);
            season.StakePercentsLeft = 100;
        }
        ActiveSeason = 0;

        ProjectName = property.ProjectName;
        Owner = tx.origin;
        _Porgi = porgi;
        _DepositManager = WETHGateway(_DEPOSIT_ADDRESS);
        // Anyone can't controll this units TODO: Do we need permissions to controll units by Porgi?
        changeController(address(this));
    }
    
    function StartPresale() external onlyOwner {
        require(State() == ProjectState.PresaleIsNotStarted);
        Seasons[ActiveSeason].Presale.Start = getTimestamp64();
    }

    function FinishPresale() external onlyHolder {
        require(State() == ProjectState.PresaleFinishing);
        _makeDeposit(address(this).balance);
        _startNextSeries();
        _unlockUnitsForCurrentSeries();
    }

    function FinishSeries(Voting.VoteResult result) external onlyCurrentVoting {
        if (result == Voting.VoteResult.Negative) {
            // Cleanup future votings, because project is canceled
            for (uint j = ActiveSeason; j < Seasons.length; ++j) {
                for (uint8 i = uint8(Seasons[j].ActiveSeries + 1); i + 1 < Seasons[j].Series.length; ++i) {
                    Seasons[j].Series[i].Vote.Cancel();
                }
            }
        } else {
            _startNextSeries();
            _unlockUnitsForCurrentSeries();
        }
    }

    function StartNextSeason() external onlyOwner {
        require(State() == ProjectState.SeasonFinishing);
        ActiveSeason = ActiveSeason + 1;
    }

    function WithdrawETH() external onlyHolder {
        // Project Is Not Canceled
        require(State() == ProjectState.ProjectCanceled);
        uint256 totalEth = GetETHBalance();
        uint256 totalSupply = totalSupply();
        uint256 senderTokens = balanceOf(msg.sender);
        uint256 ETHToWithdraw =  totalEth.mul(senderTokens).div(totalSupply);
        _burn(msg.sender, senderTokens);
        _withdrawDeposit(ETHToWithdraw);
        _safeTransferETH(msg.sender, ETHToWithdraw);
    }

    function State() public view returns (ProjectState) {
        if (Seasons[ActiveSeason].ActiveSeries < 0) {
            if (Seasons[ActiveSeason].Presale.Start == 0) {
                return ProjectState.PresaleIsNotStarted;
            } else if (getTimestamp64() < Seasons[ActiveSeason].Presale.Start + Seasons[ActiveSeason].Presale.Duration) {
                return ProjectState.PresaleInProgress;
            } else {
                return ProjectState.PresaleFinishing;
            }
        } else {
            SeriesStruct storage series = Seasons[ActiveSeason].Series[uint8(Seasons[ActiveSeason].ActiveSeries)];

            if (getTimestamp64() < series.Start + series.Duration) {
                return ProjectState.SeriesInProgress;
            } else if (uint8(Seasons[ActiveSeason].ActiveSeries + 1) == Seasons[ActiveSeason].Series.length /* last series in season */) {
                if (ActiveSeason + 1 == Seasons.length /* last season */) {
                    return ProjectState.ProjectFinished;
                } else {
                    return ProjectState.SeasonFinishing;
                }
            } else {
                if (series.Vote.TimestampStart() == 0) {
                    return ProjectState.SeriesFinishing;
                } else if (series.Vote.IsOpen()) {
                    return ProjectState.NextSeriesVotingInProgress;
                } else {
                    Voting.VoteResult result = series.Vote.Result();

                    if (result == Voting.VoteResult.None) {
                        return ProjectState.NextSeriesVotingFinishing;
                    } else if (result == Voting.VoteResult.Negative) {
                        return ProjectState.ProjectCanceled;
                    } else {
                        return ProjectState.Unknown;
                    }
                }
            }
        }
    }

    function CurrentVoting() public view returns (Voting) {
        if (State() == ProjectState.SeriesFinishing || State() == ProjectState.NextSeriesVotingInProgress || State() == ProjectState.NextSeriesVotingFinishing) {
            return Seasons[ActiveSeason].Series[uint8(Seasons[ActiveSeason].ActiveSeries)].Vote;
        } else {
            return Voting(0);
        }
    }

    function GetSeason(uint8 season) external view returns (Season memory) {
        return Seasons[season];
    }

	function GetETHBalance() public view returns (uint256) {
        IERC20 aWETH = IERC20(_DepositManager.getAWETHAddress());
        return aWETH.balanceOf(address(this));
    }

  	receive() external payable {
        if (msg.sender != _DEPOSIT_ADDRESS) {
            // Presale Finished
            require(State() == ProjectState.PresaleInProgress);
            uint256 investorTokens = Seasons[ActiveSeason].Presale.Price.mul(msg.value).div(1 ether);
            uint256 ownerPercent = Seasons[ActiveSeason].Presale.OwnerPercent;
            uint256 ownerTokens = investorTokens.mul(ownerPercent).div(100 - ownerPercent);
            _mint(msg.sender, investorTokens);
            _mint(Owner, ownerTokens);
        }
    }

    function _mint(address _owner, uint _amount) internal override {
        Seasons[ActiveSeason].Presale.TotalGenerated = Seasons[ActiveSeason].Presale.TotalGenerated.add(_amount);
        super._mint(_owner, _amount);
    }

    function _startNextSeries() private {
        Seasons[ActiveSeason].ActiveSeries = Seasons[ActiveSeason].ActiveSeries + 1;
        SeriesStruct storage series = Seasons[ActiveSeason].Series[uint8(Seasons[ActiveSeason].ActiveSeries)];
        series.Start = getTimestamp64();
        require(State() == ProjectState.SeriesInProgress);
    }

    function _unlockUnitsForCurrentSeries() private {
        uint256 balance = GetETHBalance();
        uint256 toUnlock = balance.mul(Seasons[ActiveSeason].Series[uint8(Seasons[ActiveSeason].ActiveSeries)].StakeUnlock).div(Seasons[ActiveSeason].StakePercentsLeft);
        _withdrawDeposit(toUnlock);
        _safeTransferETH(Owner, toUnlock);
        Seasons[ActiveSeason].StakePercentsLeft = Seasons[ActiveSeason].StakePercentsLeft - Seasons[ActiveSeason].Series[uint8(Seasons[ActiveSeason].ActiveSeries)].StakeUnlock;
    }

    function _makeDeposit(uint256 amount) private {
        // Not Enough ETH to Deposit
        require(address(this).balance >= amount);
        _DepositManager.depositETH{value: amount}(address(this), 0);
    }

    function _withdrawDeposit(uint256 amount) private {
        IERC20 aWETH = IERC20(_DepositManager.getAWETHAddress());
        // Not Enough aWETH to Withdraw
        require(aWETH.approve(_DEPOSIT_ADDRESS, amount));
        _DepositManager.withdrawETH(amount, address(this));
    }

    function _safeTransferETH(address to, uint256 value) private {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success);
    }
}