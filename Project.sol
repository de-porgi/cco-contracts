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

    modifier onlyOwner { require(msg.sender == address(Owner), "Project: Sender is not owner"); _; }
    modifier onlyHolder { require(balanceOf(msg.sender) > uint256(0), "Project: Sender is not holder"); _; }
    modifier onlyCurrentVoting { require(msg.sender == address(CurrentVoting()), "Project: Sender is not current voting"); _; }

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

    enum InnerProjectState {
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

    string public ProjectName;
    address public Owner;

    uint8 private ActiveSeason;
    Season[] private Seasons;

    Porgi private _Porgi;
    WETHGateway private _DepositManager;
    VotingSimpleFactory private _VotingFactory;

    constructor (InitProjectProperty memory property, Porgi porgi)
        MiniMeToken(
            porgi.TokenFactory(),
            MiniMeToken(address(0)) /* _parentToken */,
            0 /* _parentSnapShotBlock */,
            property.TokenName,
            property.TokenDecimal,
            property.TokenSymbol,
            true /* _transfersEnabled */) public {

        require(property.TokenDecimal >= 18, "Project: Decimal can't be lower than eth decimal");
        require(property.Presale.TokenPrice >= 1 ether, "Project: Price lower than ether");

        ActiveSeason = 0;
        ProjectName = property.ProjectName;
        Owner = tx.origin;
        _Porgi = porgi;
        _DepositManager = porgi.AaveWETHGateway();
        _VotingFactory = porgi.VotingFactory();
        // Anyone can't controll this units TODO: Do we need permissions to controll units by Porgi?
        changeController(address(this));

        for (uint8 i = 0; i < property.Seasons.length; ++i) {
            require(property.Presale.OwnerTokensPercent < 100);
            Season storage season = Seasons.push();
            season.Presale.OwnerPercent = property.Presale.OwnerTokensPercent;
            season.Presale.Price = property.Presale.TokenPrice;
            season.Presale.Duration = property.Presale.Duration;
            season.ActiveSeries = -1;

            uint8 totalPercent = 0;
            for (uint8 j = 0; j < property.Seasons[i].Series.length; ++j) {
                require(property.Seasons[i].Series[j].StakeUnlock <= 100, "Project: Stake unlock more 100");
                SeriesStruct storage series = Seasons[i].Series.push();
                series.Duration = property.Seasons[i].Series[j].Duration;
                series.StakeUnlock = property.Seasons[i].Series[j].StakeUnlock;
                // We don't need voting for the latest Series, because we have already unlocked all tokens for season=)
                if ((j + 1) != property.Seasons[i].Series.length) {
                    series.Vote = _VotingFactory.CreateVoting(this, property.Seasons[i].Series[j].Vote);
                }
                totalPercent += property.Seasons[i].Series[j].StakeUnlock;
            }
            require(totalPercent == 100, "Project: Total stake percent must be 100");
            season.StakePercentsLeft = 100;
        }
    }

    function StartPresale() external onlyOwner {
        require(State() == InnerProjectState.PresaleIsNotStarted);
        Seasons[ActiveSeason].Presale.Start = getTimestamp64();
        _Porgi.ChangeState(Porgi.ProjectState.Presale);
    }

    function FinishPresale() external onlyHolder {
        require(State() == InnerProjectState.PresaleFinishing);
        _makeDeposit(address(this).balance);
        _startNextSeries();
        _unlockUnitsForCurrentSeries();
        _Porgi.ChangeState(Porgi.ProjectState.InProgress);
    }

    function FinishSeries(Voting.VoteResult result) external onlyCurrentVoting {
        if (result == Voting.VoteResult.Negative) {
            // Cleanup future votings, because project is canceled
            for (uint j = ActiveSeason; j < Seasons.length; ++j) {
                for (uint8 i = uint8(Seasons[j].ActiveSeries + 1); i + 1 < Seasons[j].Series.length; ++i) {
                    Seasons[j].Series[i].Vote.Cancel();
                }
            }
            _Porgi.ChangeState(Porgi.ProjectState.Canceled);
        } else {
            _startNextSeries();
            _unlockUnitsForCurrentSeries();
        }
    }

    function StartNextSeason() external onlyOwner {
        require(State() == InnerProjectState.SeasonFinishing);
        ActiveSeason = ActiveSeason + 1;
    }

    function WithdrawETH() external onlyHolder {
        require(State() == InnerProjectState.ProjectCanceled, "Project: Is Not Canceled");
        uint256 totalEth = GetETHBalance();
        uint256 totalSupply = totalSupply();
        uint256 senderTokens = balanceOf(msg.sender);
        uint256 ETHToWithdraw =  totalEth.mul(senderTokens).div(totalSupply);
        _burn(msg.sender, senderTokens);
        _withdrawDeposit(ETHToWithdraw);
        _safeTransferETH(msg.sender, ETHToWithdraw);
    }

    function State() public view returns (InnerProjectState) {
        if (Seasons[ActiveSeason].ActiveSeries < 0) {
            if (Seasons[ActiveSeason].Presale.Start == 0) {
                return InnerProjectState.PresaleIsNotStarted;
            } else if (getTimestamp64() < Seasons[ActiveSeason].Presale.Start + Seasons[ActiveSeason].Presale.Duration) {
                return InnerProjectState.PresaleInProgress;
            } else {
                return InnerProjectState.PresaleFinishing;
            }
        } else {
            SeriesStruct storage series = Seasons[ActiveSeason].Series[uint8(Seasons[ActiveSeason].ActiveSeries)];

            if (getTimestamp64() < series.Start + series.Duration) {
                return InnerProjectState.SeriesInProgress;
            } else if (uint8(Seasons[ActiveSeason].ActiveSeries + 1) == Seasons[ActiveSeason].Series.length /* last series in season */) {
                if (ActiveSeason + 1 == Seasons.length /* last season */) {
                    return InnerProjectState.ProjectFinished;
                } else {
                    return InnerProjectState.SeasonFinishing;
                }
            } else {
                if (series.Vote.TimestampStart() == 0) {
                    return InnerProjectState.SeriesFinishing;
                } else if (series.Vote.IsOpen()) {
                    return InnerProjectState.NextSeriesVotingInProgress;
                } else {
                    Voting.VoteResult result = series.Vote.Result();

                    if (result == Voting.VoteResult.None) {
                        return InnerProjectState.NextSeriesVotingFinishing;
                    } else if (result == Voting.VoteResult.Negative) {
                        return InnerProjectState.ProjectCanceled;
                    } else {
                        return InnerProjectState.Unknown;
                    }
                }
            }
        }
    }

    function CurrentVoting() public view returns (Voting) {
        if (State() == InnerProjectState.SeriesFinishing
         || State() == InnerProjectState.NextSeriesVotingInProgress
         || State() == InnerProjectState.NextSeriesVotingFinishing) {
            return Seasons[ActiveSeason].Series[uint8(Seasons[ActiveSeason].ActiveSeries)].Vote;
        } else {
            return Voting(0);
        }
    }

    function GetSeasons() external view returns (Season[] memory) {
        return Seasons;
    }

    function GetSeason(uint8 season) external view returns (Season memory) {
        return Seasons[season];
    }

    function GetETHBalance() public view returns (uint256) {
        IERC20 aWETH = IERC20(_DepositManager.getAWETHAddress());
        return aWETH.balanceOf(address(this));
    }

    receive() external payable {
        if (msg.sender != address(_DepositManager)) {
            require(State() == InnerProjectState.PresaleInProgress, "Project: Presale not in progress");
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
        require(State() == InnerProjectState.SeriesInProgress);
        // We started latest series in project, so we can mark it as finished
        if (ActiveSeason + 1 == uint8(Seasons.length) && Seasons[ActiveSeason].ActiveSeries + 1 == int8(Seasons[ActiveSeason].Series.length)) {
            _Porgi.ChangeState(Porgi.ProjectState.Finished);
        }
    }

    function _unlockUnitsForCurrentSeries() private {
        uint256 balance = GetETHBalance();
        uint256 toUnlock = balance.mul(Seasons[ActiveSeason].Series[uint8(Seasons[ActiveSeason].ActiveSeries)].StakeUnlock).div(Seasons[ActiveSeason].StakePercentsLeft);
        _withdrawDeposit(toUnlock);
        _safeTransferETH(Owner, toUnlock);
        Seasons[ActiveSeason].StakePercentsLeft = Seasons[ActiveSeason].StakePercentsLeft - Seasons[ActiveSeason].Series[uint8(Seasons[ActiveSeason].ActiveSeries)].StakeUnlock;
    }

    function _makeDeposit(uint256 amount) private {
        require(address(this).balance >= amount, "Project: Not Enough ETH to Deposit");
        _DepositManager.depositETH{value: amount}(address(this), 0);
    }

    function _withdrawDeposit(uint256 amount) private {
        IERC20 aWETH = IERC20(_DepositManager.getAWETHAddress());
        // TODO: I think approve always returns tru, so this check is obvious
        require(aWETH.approve(address(_DepositManager), amount), "Project: Not Enough aWETH to Withdraw");
        _DepositManager.withdrawETH(amount, address(this));
    }

    function _safeTransferETH(address to, uint256 value) private {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success);
    }
}

/**
 * @title ProjectSimpleFactory
 */
contract ProjectSimpleFactory {
    function CreateProject(Project.InitProjectProperty memory property, Porgi porgi) external returns (Project) {
        return new Project(property, porgi);
    }
}