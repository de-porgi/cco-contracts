// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import "./Voting.sol";
import "./Porgi.sol";
import "./Time.sol";

import "https://github.com/aave/protocol-v2/blob/master/contracts/misc/WETHGateway.sol";
import "https://github.com/aave/protocol-v2/blob/master/contracts/dependencies/openzeppelin/contracts/SafeMath.sol";
import "https://github.com/de-porgi/minime/blob/master/contracts/MiniMeToken.sol";
import "https://github.com/aave/protocol-v2/blob/master/contracts/dependencies/openzeppelin/contracts/ERC20.sol";

/**
 * @title Project
 */
contract Project is MiniMeToken, Time {

    using SafeMath for uint256;

    modifier onlyOwner { require(msg.sender == address(Owner), "Project: sender is not owner"); _; }
    modifier onlyHolder { require(balanceOf(msg.sender) > 0, "Project: sender is not holder"); _; }
    modifier onlyCurrentVoting { require(msg.sender == address(CurrentVoting()), "Project: sender is not current voting"); _; }

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
        SeriesStruct[] Series;
        uint8 StakePercentsLeft;
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

    uint8 public ActiveSeason;
    Season[] public Seasons;

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

        require(property.TokenDecimal >= 18, "Project: decimal can't be lower than eth decimal");
        require(property.Presale.TokenPrice >= 10**18, "Project: price can't be lower than decimal");

        for (uint8 i = 0; i < property.Seasons.length; ++i) {
            _addSeason(property.Presale, property.Seasons[i]);
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

    function _unlockUnitsForCurrentSeries() private {
        Season storage curSeason = Seasons[ActiveSeason];
        _unlockETH(curSeason.Series[uint8(curSeason.ActiveSeries)].StakeUnlock, curSeason.StakePercentsLeft);
        Seasons[ActiveSeason].StakePercentsLeft -= curSeason.Series[uint8(curSeason.ActiveSeries)].StakeUnlock;
    }

    function FinishPresale() external onlyHolder {
        require(State() == ProjectState.PresaleFinishing);
        _makeDeposit(address(this).balance);
        _startNextSeries();
        _unlockUnitsForCurrentSeries();
    }

    function FinishSeries() external onlyCurrentVoting {
        Voting.VoteResult result = Seasons[ActiveSeason].Series[uint8(Seasons[ActiveSeason].ActiveSeries)].Vote.Result();
        require(result == Voting.VoteResult.Negative || result == Voting.VoteResult.Positive, "Project: Incorrect voting result");

        if (result == Voting.VoteResult.Negative) {
            // Cleanup future votings, because project is canceled
            for (uint j = ActiveSeason; j < Seasons.length; ++j) {
                for (uint8 i = uint8(Seasons[j].ActiveSeries + 1); i < Seasons[j].Series.length; ++i) {
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
        ++ActiveSeason;
    }

    function State() public view returns (ProjectState) {
        if (Seasons[ActiveSeason].ActiveSeries <= 0) {
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
        if (State() == ProjectState.SeasonFinishing) {
            return Seasons[ActiveSeason].Series[uint8(Seasons[ActiveSeason].ActiveSeries)].Vote;
        } else {
            return Voting(0);
        }
    }

  	receive() external payable {
        if (msg.sender != _DEPOSIT_ADDRESS) {
            require(State() == ProjectState.PresaleInProgress, "Presale Finished");
            uint256 investorTokens = Seasons[ActiveSeason].Presale.Price.mul(msg.value).div(1 ether);
            uint256 ownerTokens = investorTokens.mul(Seasons[ActiveSeason].Presale.OwnerPercent).div(100);
            _mint(msg.sender, investorTokens);
            _mint(Owner, ownerTokens);
        }
    }

    function _startNextSeries() private {
        ProjectState state = State();
        require(state == ProjectState.PresaleFinishing || state == ProjectState.NextSeriesVotingFinishing);
        ++Seasons[ActiveSeason].ActiveSeries;
        SeriesStruct storage series = Seasons[ActiveSeason].Series[uint8(Seasons[ActiveSeason].ActiveSeries)];
        series.Start = getTimestamp64();
        require(State() == ProjectState.SeriesInProgress);
    }

    function _makeDeposit(uint256 amount) private {
        require(address(this).balance >= amount, "Not Enough ETH to Deposit");
        _DepositManager.depositETH{value: amount}(address(this), 0);
    }

    function _withdrawDeposit(uint256 amount) private {
        ERC20 aWETH = ERC20(_DepositManager.getAWETHAddress());
        require(aWETH.approve(_DEPOSIT_ADDRESS, amount), "Not Enough aWETH to Withdraw");
        _DepositManager.withdrawETH(amount, address(this));
    }

    function _addSeason(InitPresale memory _presale, InitSeason memory _season) private {
        Season storage season = Seasons.push();
        season.Presale.OwnerPercent = _presale.OwnerTokensPercent;
        season.Presale.Price = _presale.TokenPrice;
        season.Presale.Duration = _presale.Duration;
        season.ActiveSeries = -1;

        uint8 totalPercent = 0;
        for (uint8 i = 0; i < _season.Series.length; ++i) {
            _addSeries(season, _season.Series[i], (i + 1) == _season.Series.length);
            require(_season.Series[i].StakeUnlock <= 100, "Project: stake unlock more than 100");
            totalPercent += _season.Series[i].StakeUnlock;
        }
        require(totalPercent == 100, "Project: total stake percent must be 100");
        season.StakePercentsLeft = 100;
    }

    function _addSeries(Season storage _season, InitSeries memory _series, bool last) private {
        SeriesStruct storage series = _season.Series.push();
        series.Duration = _series.Duration;
        series.StakeUnlock = _series.StakeUnlock;
        // We don't need voting for the latest Series, because we have already unlocked all tokens for season=)
        if (!last) {
            series.Vote = new Voting(this, _series.Vote);
        }
    }

	function GetETHBalance() public view returns (uint256) {
        ERC20 aWETH = ERC20(_DepositManager.getAWETHAddress());
        return aWETH.balanceOf(address(this));
    }

    function withdrawETH() public {
        require(State() == ProjectState.ProjectCanceled, "Project Is Not Canceled");
        uint256 totalEth = GetETHBalance();
        uint256 totalSupply = totalSupply();
        uint256 senderTokens = balanceOf(msg.sender);
        uint256 ETHToWithdraw =  totalEth.mul(senderTokens).div(totalSupply);
        _burn(msg.sender, senderTokens);
        _withdrawDeposit(ETHToWithdraw);
        _safeTransferETH(msg.sender, ETHToWithdraw);
    }

    function _safeTransferETH(address to, uint256 value) private {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');
    }

    function _unlockETH(uint8 numerator, uint8 denominator) private {
        uint256 balance = GetETHBalance();
        uint256 toUnlock = balance.mul(numerator).div(denominator);
        _withdrawDeposit(toUnlock);
        _safeTransferETH(Owner, toUnlock);
    }
}