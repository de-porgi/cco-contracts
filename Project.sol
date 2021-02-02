pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

import "./Voting.sol";
import "./Porgi.sol";
import "./Time.sol";

import "https://github.com/de-porgi/aave_v2/blob/main/contracts/misc/WETHGateway.sol";
import "https://github.com/de-porgi/aave_v2/blob/main/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import "https://github.com/de-porgi/aave_v2/blob/main/contracts/dependencies/openzeppelin/contracts/SafeMath.sol";
import "https://github.com/de-porgi/minime/blob/master/contracts/MiniMeToken.sol";

/**
 * @title Project
 */
contract Project is MiniMeToken, Time {

    using SafeMath for uint256;

    modifier onlyOwner { require(msg.sender == address(Owner), "Project: Sender is not owner"); _; }
    modifier onlyHolder { require(msg.sender == Owner || balanceOf(msg.sender) > uint256(0), "Project: Sender is not a holder"); _; }
    modifier onlyActiveVoting { require(msg.sender == address(ActiveVoting()), "Project: Sender is not active voting"); _; }

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

    uint8 private ActiveSeason;
    Season[] private Seasons;

    Porgi private _Porgi;
    IWETHGateway private _DepositManager;
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

        require(property.TokenDecimal >= 18, "Project: ETH decimal(>=18)");
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
            _addSeason(property.Presale, property.Seasons[i]);
        }
    }
    
    function StartPresale() external onlyOwner {
        require(State() == _ProjectState.PresaleIsNotStarted);
        Seasons[ActiveSeason].Presale.Start = getTimestamp64();
        _Porgi.ChangeState(Porgi.ProjectState.Presale);
    }

    function FinishPresale() external onlyHolder {
        require(State() == _ProjectState.PresaleFinishing);
        _makeDeposit(address(this).balance);
        _startNextSeries();
        _unlockUnitsForCurrentSeries();
        _Porgi.ChangeState(Porgi.ProjectState.InProgress);
    }

    function FinishSeries(Voting.VoteResult result) external onlyActiveVoting {
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
        require(State() == _ProjectState.SeasonFinishing);
        ActiveSeason = ActiveSeason + 1;
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
        if (Seasons[ActiveSeason].ActiveSeries < 0) {
            if (Seasons[ActiveSeason].Presale.Start == 0) {
                return _ProjectState.PresaleIsNotStarted;
            } else if (getTimestamp64() < Seasons[ActiveSeason].Presale.Start + Seasons[ActiveSeason].Presale.Duration) {
                return _ProjectState.PresaleInProgress;
            } else {
                return _ProjectState.PresaleFinishing;
            }
        } else {
            SeriesStruct storage series = Seasons[ActiveSeason].Series[uint8(Seasons[ActiveSeason].ActiveSeries)];

            if (getTimestamp64() < series.Start + series.Duration) {
                return _ProjectState.SeriesInProgress;
            } else if (uint8(Seasons[ActiveSeason].ActiveSeries + 1) == Seasons[ActiveSeason].Series.length /* last series in season */) {
                if (ActiveSeason + 1 == Seasons.length /* last season */) {
                    return _ProjectState.ProjectFinished;
                } else {
                    return _ProjectState.SeasonFinishing;
                }
            } else {
                if (series.Vote.TimestampStart() == 0) {
                    return _ProjectState.SeriesFinishing;
                } else if (series.Vote.IsOpen()) {
                    return _ProjectState.NextSeriesVotingInProgress;
                } else {
                    Voting.VoteResult result = series.Vote.Result();

                    if (result == Voting.VoteResult.None) {
                        return _ProjectState.NextSeriesVotingFinishing;
                    } else if (result == Voting.VoteResult.Negative) {
                        return _ProjectState.ProjectCanceled;
                    } else {
                        return _ProjectState.Unknown;
                    }
                }
            }
        }
    }

    function ActiveVoting() public view returns (Voting) {
        if (State() == _ProjectState.SeriesFinishing 
         || State() == _ProjectState.NextSeriesVotingInProgress 
         || State() == _ProjectState.NextSeriesVotingFinishing) {
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
            require(State() == _ProjectState.PresaleInProgress, "Project: Presale not in progress");
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
        require(State() == _ProjectState.SeriesInProgress);
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
        aWETH.approve(address(_DepositManager), amount);
        _DepositManager.withdrawETH(amount, address(this));
    }

    function _safeTransferETH(address to, uint256 value) private {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success);
    }
    
    function _addSeason(InitPresale memory _presale, InitSeason memory _season) private {
        require(_presale.OwnerTokensPercent < 100);		
        Season storage season = Seasons.push();		
        season.Presale.OwnerPercent = _presale.OwnerTokensPercent;		
        season.Presale.Price = _presale.TokenPrice;		
        season.Presale.Duration = _presale.Duration;		
        season.ActiveSeries = -1;		
        
        uint8 totalPercent = 0;		
        for (uint8 i = 0; i < _season.Series.length; ++i) {		
            _addSeries(season, _season.Series[i], (i + 1) == _season.Series.length);	
            totalPercent += _season.Series[i].StakeUnlock;		
        }		
        require(totalPercent == 100, "Project: total stake percent must be 100");		
        season.StakePercentsLeft = 100;
    }		

    function _addSeries(Season storage _season, InitSeries memory _series, bool last) private {		
        require(_series.StakeUnlock <= 100, "Project: Stake unlock more 100");
        SeriesStruct storage series = _season.Series.push();		
        series.Duration = _series.Duration;		
        series.StakeUnlock = _series.StakeUnlock;		
        // We don't need voting for the latest Series, because we have already unlocked all tokens for season	
        if (!last) {		
            series.Vote = _VotingFactory.CreateVoting(this, _series.Vote);		
        }		
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