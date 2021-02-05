pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import "./Common.sol";
import "./Voting.sol";
import "./Porgi.sol";
import "./Time.sol";

import "https://github.com/de-porgi/aave_v2/blob/main/contracts/misc/interfaces/IWETHGateway.sol";
import "https://github.com/de-porgi/aave_v2/blob/main/contracts/dependencies/openzeppelin/contracts/SafeMath.sol";
import "https://github.com/de-porgi/aave_v2/blob/main/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import "https://github.com/de-porgi/minime/blob/master/contracts/MiniMeToken.sol";
import "https://github.com/de-porgi/1inch/blob/main/contracts/IOneInchExchange.sol";

/**
 * @title Project
 */
contract Project is MiniMeToken, Time {

    using SafeMath for uint256;

    modifier onlyOwner { require(msg.sender == address(Owner), "Project: Sender is not owner"); _; }
    modifier onlyPorgi { require(msg.sender == address(_Porgi), "Project: Sender is not Porgi"); _; }
    modifier onlyHolder { require(msg.sender == Owner || balanceOf(msg.sender) > uint256(0), "Project: Sender is not a holder"); _; }
    modifier onlyActiveVoting { require(msg.sender == address(ActiveVoting()), "Project: Sender is not active voting"); _; }

    struct SeriesStruct {
        uint64 Start;
        uint64 Duration;
        uint8 StakeUnlock;
        Voting Vote;
    }

    struct TokenFirstPresale {
        uint8 OwnerPercent;
        uint256 Price;
        uint64 Start;
        uint64 Duration;
        uint256 TotalGenerated;
    }

    struct TokenSecondaryPresale {
        uint256 TokensEmissionPercent;
        uint64 Emissions;
        uint8 OwnerPercent;
        uint64 TimeBetweenEmissions;
        uint64 TimeLastEmission;
        uint64 EmissionsMade;
        uint64 Start;
		uint256 TokensAtStart;
    }

    struct FirstSeason {
        TokenFirstPresale Presale;
        int8 ActiveSeries;
        uint8 StakePercentsLeft;
        SeriesStruct[] Series;
    }

    struct NextSeason {
        TokenSecondaryPresale Presale;
        int8 ActiveSeries;
        uint8 StakePercentsLeft;
        SeriesStruct[] Series;
    }

    enum _ProjectState {
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

    int8 private ActiveSeason;
    FirstSeason private FSeason;
    NextSeason[] private NextSeasons;

    Porgi private _Porgi;
    IWETHGateway private _DepositManager;
    IOneInchExchange private _ExchangeManager;
    VotingSimpleFactory private _VotingFactory;
    
    constructor (Porgi porgi)
        MiniMeToken(
            porgi.TokenFactory(),
            MiniMeToken(address(0)) /* _parentToken */,
            0 /* _parentSnapShotBlock */,
            "" /* empty name */,
            0 /* zero decimal */,
            "" /* empty symbol */,
            true /* _transfersEnabled */) public {
        _Porgi = porgi;
        _DepositManager = porgi.AaveWETHGateway();
        _ExchangeManager = porgi.LinchExchange();
        _VotingFactory = porgi.VotingFactory();
        changeController(address(this));
    }
    
    function Init(Common.InitProjectProperty memory property) external onlyPorgi {
        require(property.TokenDecimal >= 18, "Project: ETH decimal(>=18)");
        require(property.FirstSeason.Presale.TokenPrice >= 1 ether, "Project: Price lower than ether");
        
        name = property.TokenName;
        decimals = property.TokenDecimal;
        symbol = property.TokenSymbol;
        ActiveSeason = -1;
        ProjectName = property.ProjectName;
        Owner = tx.origin;
        _addFirstSeason(property.FirstSeason, property.NextSeasons.length == 0);
        for (uint8 i = 0; i < property.NextSeasons.length; ++i) {
            _addNextSeason(property.NextSeasons[i], i + 1 == property.NextSeasons.length);
        }
    }
    
    function GetProjectBaseInfo() public view returns (address, string memory, string memory, string memory, uint8, int8, Porgi.Statistic memory) {
        return (Owner, ProjectName, name, symbol, decimals, ActiveSeason, _Porgi.GetProjectStatistic(this));
    }

    function StartPresale() external onlyOwner {
        require(State() == _ProjectState.PresaleIsNotStarted);
        if (ActiveSeason == -1) {
            FSeason.Presale.Start = getTimestamp64();
        } else {
            NextSeasons[uint8(ActiveSeason)].Presale.Start = getTimestamp64();
        }
        _Porgi.ChangeState(Porgi.ProjectState.Presale);
    }

    function FinishPresale() external onlyHolder {
        require(State() == _ProjectState.PresaleFinishing);
        if (address(this).balance > 0) {
            _makeDeposit(address(this).balance);
        }
        _startNextSeries();
        _unlockUnitsForCurrentSeries();
        _Porgi.ChangeState(Porgi.ProjectState.InProgress);
    }

    function FinishSeries(Common.VoteResult result) external onlyActiveVoting {
        if (result == Common.VoteResult.Negative) {
            // Cleanup future votings, because project is canceled
            if (ActiveSeason == -1) {
                for (uint8 i = uint8(FSeason.ActiveSeries + 1); i + 1 < FSeason.Series.length; ++i) {
                    FSeason.Series[i].Vote.Cancel();
                }
            }
            else {
                for (uint8 i = uint8(NextSeasons[uint8(ActiveSeason)].ActiveSeries + 1); i + 1 < NextSeasons[uint8(ActiveSeason)].Series.length; ++i) {
                    NextSeasons[uint8(ActiveSeason)].Series[i].Vote.Cancel();
                }
            }
            for (uint j = uint8(ActiveSeason + 1); j < NextSeasons.length; ++j) {
                for (uint8 i = uint8(NextSeasons[j].ActiveSeries + 1); i + 1 < NextSeasons[j].Series.length; ++i) {
                    NextSeasons[j].Series[i].Vote.Cancel();
                }
            }
            _Porgi.ChangeState(Porgi.ProjectState.Canceled);
        } else if (uint8(_getActiveSeries() + 1) < _getActiveSeasonSeriesLength()){
            _startNextSeries();
            _unlockUnitsForCurrentSeries();
        }
        else {
            _startNextSeason();
        }
    }

    function _startNextSeason() private {
        ActiveSeason = ActiveSeason + 1;
        NextSeasons[uint8(ActiveSeason)].Presale.TokensAtStart = totalSupply();
    }

    function WithdrawETH() external onlyHolder {
        require(State() == _ProjectState.ProjectCanceled, "Project: Is Not Canceled");
        uint256 totalEth = GetETHBalance();
        uint256 totalSupply = totalSupply();
        uint256 senderTokens = balanceOf(msg.sender);
        require(senderTokens > 0, "Project: Zero balance");
        uint256 ETHToWithdraw =  totalEth.mul(senderTokens).div(totalSupply);
        _burn(msg.sender, senderTokens);
        _withdrawDeposit(ETHToWithdraw);
        _safeTransferETH(msg.sender, ETHToWithdraw);
    }

    function State() public view returns (_ProjectState) {
        if (_getActiveSeries() < 0) {
            if (ActiveSeason == -1) {
                if (FSeason.Presale.Start == 0) {
                    return _ProjectState.PresaleIsNotStarted;
                } else if (getTimestamp64() < FSeason.Presale.Start + FSeason.Presale.Duration) {
                    return _ProjectState.PresaleInProgress;
                } else {
                    return _ProjectState.PresaleFinishing;
                }
            } else {
                if (NextSeasons[uint8(ActiveSeason)].Presale.Start == 0) {
                    return _ProjectState.PresaleIsNotStarted;
                } else if (NextSeasons[uint8(ActiveSeason)].Presale.EmissionsMade < NextSeasons[uint8(ActiveSeason)].Presale.Emissions) {
                    return _ProjectState.PresaleInProgress;
                } else {
                    return _ProjectState.PresaleFinishing;
                }
            }
        } else {
            SeriesStruct storage series;
            if (ActiveSeason == -1) {
                series = FSeason.Series[uint8(FSeason.ActiveSeries)];
            } else {
                series = NextSeasons[uint8(ActiveSeason)].Series[uint8(NextSeasons[uint8(ActiveSeason)].ActiveSeries)];
            }

            if (getTimestamp64() < series.Start + series.Duration) {
                return _ProjectState.SeriesInProgress;
            } else if (uint8(_getActiveSeries() + 1) == _getActiveSeasonSeriesLength() /* last series in season */ && uint8(ActiveSeason + 1) == NextSeasons.length) {
                return _ProjectState.ProjectFinished;
            } else {
                if (series.Vote.TimestampStart() == 0) {
                    return _ProjectState.SeriesFinishing;
                } else if (series.Vote.IsOpen()) {
                    return _ProjectState.NextSeriesVotingInProgress;
                } else {
                    Common.VoteResult result = series.Vote.Result();
                    if (result == Common.VoteResult.None) {
                        return _ProjectState.NextSeriesVotingFinishing;
                    } else if (result == Common.VoteResult.Negative) {
                        return _ProjectState.ProjectCanceled;
                    } else {
                        return _ProjectState.Unknown;
                    }
                }
            }
        }
    }

    function _getActiveSeries() private view returns (int8){
        if (ActiveSeason == -1) {
            return FSeason.ActiveSeries;
        } else {
            return NextSeasons[uint8(ActiveSeason)].ActiveSeries;
        }
    }

    function _getActiveSeasonSeriesLength() private view returns (uint256) {
        if (ActiveSeason == -1) {
            return FSeason.Series.length;
        } else {
            return NextSeasons[uint8(ActiveSeason)].Series.length;
        }
    }

    function ActiveVoting() public view returns (Voting) {
        if (State() == _ProjectState.SeriesFinishing
         || State() == _ProjectState.NextSeriesVotingInProgress
         || State() == _ProjectState.NextSeriesVotingFinishing) {
             if (ActiveSeason == -1) {
                 return FSeason.Series[uint8(FSeason.ActiveSeries)].Vote;
             } else {
                 return NextSeasons[uint8(ActiveSeason)].Series[uint8(NextSeasons[uint8(ActiveSeason)].ActiveSeries)].Vote;
             }
        } else {
            return Voting(0);
        }
    }

    function GetFirstSeason() external view returns (FirstSeason memory) {
        return FSeason;
    }

    function GetNextSeasons() external view returns (NextSeason[] memory) {
        return NextSeasons;
    }

    function GetNextSeason(uint8 season) external view returns (NextSeason memory) {
        return NextSeasons[season];
    }

    function GetETHBalance() public view returns (uint256) {
        IERC20 aWETH = IERC20(_DepositManager.getAWETHAddress());
        return aWETH.balanceOf(address(this));
    }

    receive() external payable {
        if (msg.sender != address(_DepositManager)) {
            _makeDeposit(msg.value);
        }
    }

    function _mint(address _owner, uint _amount) internal override {
        if (ActiveSeason == -1) {
            FSeason.Presale.TotalGenerated = FSeason.Presale.TotalGenerated.add(_amount);
        }
        super._mint(_owner, _amount);
    }

    function _startNextSeries() private {
        SeriesStruct storage series;
        if (ActiveSeason == -1) {
            FSeason.ActiveSeries = FSeason.ActiveSeries + 1;
            series = FSeason.Series[uint8(FSeason.ActiveSeries)];
        } else {
            NextSeasons[uint8(ActiveSeason)].ActiveSeries = NextSeasons[uint8(ActiveSeason)].ActiveSeries + 1;
            series = NextSeasons[uint8(ActiveSeason)].Series[uint8(NextSeasons[uint8(ActiveSeason)].ActiveSeries)];
        }
        series.Start = getTimestamp64();
        require(State() == _ProjectState.SeriesInProgress);
        // We started latest series in project, so we can mark it as finished
        if ((uint8(ActiveSeason + 1) == uint8(NextSeasons.length)) && (uint8(_getActiveSeries() + 1) == _getActiveSeasonSeriesLength())) {
            _Porgi.ChangeState(Porgi.ProjectState.Finished);
        }
    }

    function _unlockUnitsForCurrentSeries() private {
        uint256 balance = GetETHBalance();
        uint256 toUnlock;
        if (ActiveSeason == -1) {
            toUnlock = balance.mul(FSeason.Series[uint8(FSeason.ActiveSeries)].StakeUnlock).div(FSeason.StakePercentsLeft);
            FSeason.StakePercentsLeft = FSeason.StakePercentsLeft - FSeason.Series[uint8(FSeason.ActiveSeries)].StakeUnlock;
        }
        else {
            toUnlock = balance.mul(NextSeasons[uint8(ActiveSeason)].Series[uint8(NextSeasons[uint8(ActiveSeason)].ActiveSeries)].StakeUnlock).div(NextSeasons[uint8(ActiveSeason)].StakePercentsLeft);
            NextSeasons[uint8(ActiveSeason)].StakePercentsLeft = NextSeasons[uint8(ActiveSeason)].StakePercentsLeft - NextSeasons[uint8(ActiveSeason)].Series[uint8(NextSeasons[uint8(ActiveSeason)].ActiveSeries)].StakeUnlock;
        }
        _withdrawDeposit(toUnlock);
        _safeTransferETH(Owner, toUnlock);
    }

    function _makeDeposit(uint256 amount) private {
        require(address(this).balance >= amount, "Project: Not Enough ETH to Deposit");
        _DepositManager.depositETH{value: amount}(address(this), 0);
    }

    function _withdrawDeposit(uint256 amount) private {
        IERC20 aWETH = IERC20(_DepositManager.getAWETHAddress());
        aWETH.approve(address(_DepositManager), amount);
        _DepositManager.withdrawETH(amount, address(this));
    }

    function _safeTransferETH(address to, uint256 value) private {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success);
    }

    function SellTokens(bytes calldata oneInchCallData) public payable {
        require(State() == _ProjectState.PresaleInProgress && ActiveSeason >= 0, "Project: Presale not in progress");
		uint64 time = getTimestamp64();
		TokenSecondaryPresale storage presale = NextSeasons[uint8(ActiveSeason)].Presale;
		require(presale.EmissionsMade == 0 || presale.TimeLastEmission + presale.TimeBetweenEmissions < time);
		presale.TimeLastEmission = time;
		presale.EmissionsMade += 1;
		uint256 tokensToMint = presale.TokensAtStart.mul(presale.TokensEmissionPercent).div(100).div(presale.Emissions);
        if (oneInchCallData.length > 0) {
            (IOneInchCaller caller, IOneInchExchange.SwapDescription memory desc, IOneInchCaller.CallDescription[] memory calls) = abi
      .decode(oneInchCallData[4:], (IOneInchCaller, IOneInchExchange.SwapDescription, IOneInchCaller.CallDescription[]));
            require(desc.srcReceiver == address(this));
            require(desc.dstReceiver == address(this));
            require(address(desc.srcToken) == address(this));
            require(address(desc.dstToken) == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
            require(desc.amount == 0);
			_mint(address(this), tokensToMint);
			_approve(address(this), address(_ExchangeManager), tokensToMint);
            _ExchangeManager.swap(caller, desc, calls);
        }
        else {
            _invest(msg.sender, msg.value, tokensToMint);
        }
    }

    function Invest() public payable {
        require(State() == _ProjectState.PresaleInProgress && ActiveSeason == -1, "Project: Presale not in progress");
        _invest(msg.sender, msg.value, 0);
    }

    function _invest(address investor, uint256 amount, uint256 needTokens) private {
        uint256 rate = FSeason.Presale.Price.div(uint8(ActiveSeason + 2));
        uint256 investorTokens = rate.mul(amount).div(1 ether);
        uint256 ownerPercent;
		if (needTokens > 0) {
			require(investorTokens > needTokens);
			if (investorTokens > needTokens) {
				investorTokens = needTokens;
			}
		}
        if (ActiveSeason == -1) {
            ownerPercent = FSeason.Presale.OwnerPercent;
        } else {
            ownerPercent = NextSeasons[uint8(ActiveSeason)].Presale.OwnerPercent;
        }
        uint256 ownerTokens = investorTokens.mul(ownerPercent).div(100 - ownerPercent);
        _mint(investor, investorTokens);
        _mint(Owner, ownerTokens);
    }

    function _addFirstSeason(Common.InitFirstSeason memory _season, bool lastSeason) private {
        Common.InitFirstPresale memory Presale = _season.Presale;
        require(Presale.OwnerTokensPercent < 100);
        FirstSeason storage season = FSeason;
        season.Presale.OwnerPercent = Presale.OwnerTokensPercent;
        season.Presale.Price = Presale.TokenPrice;
        season.Presale.Duration = Presale.Duration;
        season.ActiveSeries = -1;

        _addSeasonSeries(FSeason.Series, _season.Series, lastSeason);
        season.StakePercentsLeft = 100;
    }

    function _addNextSeason(Common.InitNextSeason memory _season, bool lastSeason) private {
        Common.InitSecondaryPresale memory Presale = _season.Presale;
        require(Presale.OwnerTokensPercent < 100);
        NextSeason storage season = NextSeasons.push();
        season.Presale.OwnerPercent = _season.Presale.OwnerTokensPercent;
        season.Presale.TimeBetweenEmissions = Presale.TimeBetweenEmissions;
        season.Presale.Emissions = Presale.Emissions;
        season.Presale.TimeLastEmission = 0;
        season.Presale.TokensEmissionPercent = Presale.TokensEmissionPercent;
        season.Presale.EmissionsMade = 0;
        season.ActiveSeries = -1;
        season.StakePercentsLeft = 100;
        _addSeasonSeries(season.Series, _season.Series, lastSeason);
    }

    function _addSeasonSeries(SeriesStruct[] storage seriesArray, Common.InitSeries[] memory initSeriesArray, bool lastSeason) private {
        uint8 totalPercent = 0;
        for (uint8 j = 0; j < initSeriesArray.length; ++j) {
            require(initSeriesArray[j].StakeUnlock <= 100, "Project: Stake unlock more 100");
            SeriesStruct storage series = seriesArray.push();
            series.Duration = initSeriesArray[j].Duration;
            series.StakeUnlock = initSeriesArray[j].StakeUnlock;
            if ((j + 1) != initSeriesArray.length || !lastSeason) {
                series.Vote = _VotingFactory.CreateVoting(this, initSeriesArray[j].Vote);
            }
            totalPercent += initSeriesArray[j].StakeUnlock;
        }
        require(totalPercent == 100);
    }
}

/**
 * @title ProjectSimpleFactory
 */
contract ProjectSimpleFactory {
    function CreateProject(Porgi porgi) external returns (Project) {
        return new Project(porgi);
    }
}