// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BaseGovernanceDAO
 * @dev Advanced governance DAO for Base blockchain ecosystem
 * @notice Comprehensive governance system with treasury management,
 *         proposal execution, and Base Builder Rewards integration
 * @author davidsebil
 */
contract BaseGovernanceDAO is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    ReentrancyGuard,
    Ownable
{
    using SafeERC20 for IERC20;

    // =============================================================================
    // CONSTANTS
    // =============================================================================

    uint256 public constant MAX_PROPOSAL_THRESHOLD = 1000; // 10%
    uint256 public constant MIN_VOTING_DELAY = 1 days;
    uint256 public constant MAX_VOTING_DELAY = 7 days;
    uint256 public constant MIN_VOTING_PERIOD = 3 days;
    uint256 public constant MAX_VOTING_PERIOD = 14 days;
    uint256 public constant BASE_CHAIN_ID = 8453;

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    uint256 public treasuryBalance;
    uint256 public totalProposals;
    uint256 public executedProposals;
    uint256 public builderRewardsPool;
    address public builderRewardsContract;

    // =============================================================================
    // STRUCTS
    // =============================================================================

    struct ProposalMetadata {
        string title;
        string description;
        string category;
        uint256 requestedAmount;
        address beneficiary;
        uint256 createdAt;
        uint256 executedAt;
        bool isExecuted;
        ProposalType proposalType;
    }

    struct TreasuryAllocation {
        string purpose;
        uint256 amount;
        address recipient;
        uint256 releaseTime;
        bool isReleased;
        uint256 votingPower;
    }

    struct BuilderReward {
        address builder;
        uint256 amount;
        string contribution;
        uint256 timestamp;
        bool isClaimed;
        uint256 multiplier;
    }

    enum ProposalType {
        TREASURY_ALLOCATION,
        PARAMETER_CHANGE,
        BUILDER_REWARDS,
        PROTOCOL_UPGRADE,
        EMERGENCY_ACTION
    }

    enum VotingPowerType {
        TOKEN_BASED,
        CONTRIBUTION_BASED,
        HYBRID
    }

    // =============================================================================
    // MAPPINGS
    // =============================================================================

    mapping(uint256 => ProposalMetadata) public proposalMetadata;
    mapping(uint256 => TreasuryAllocation) public treasuryAllocations;
    mapping(address => BuilderReward[]) public builderRewards;
    mapping(address => uint256) public contributionScores;
    mapping(address => bool) public authorizedProposers;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => uint256) public delegatedVotes;

    // =============================================================================
    // ARRAYS
    // =============================================================================

    address[] public activeProposers;
    uint256[] public activeProposals;
    address[] public treasuryTokens;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event ProposalCreatedWithMetadata(
        uint256 indexed proposalId,
        address indexed proposer,
        string title,
        ProposalType proposalType
    );
    event TreasuryAllocationExecuted(
        uint256 indexed proposalId,
        address indexed recipient,
        uint256 amount
    );
    event BuilderRewardDistributed(
        address indexed builder,
        uint256 amount,
        string contribution
    );
    event ContributionScoreUpdated(
        address indexed builder,
        uint256 oldScore,
        uint256 newScore
    );
    event EmergencyActionExecuted(
        uint256 indexed proposalId,
        address indexed executor,
        string reason
    );

    // =============================================================================
    // MODIFIERS
    // =============================================================================

    modifier onlyAuthorizedProposer() {
        require(
            authorizedProposers[msg.sender] || 
            getVotes(msg.sender, block.number - 1) >= proposalThreshold(),
            "Not authorized to propose"
        );
        _;
    }

    modifier validProposal(uint256 proposalId) {
        require(proposalMetadata[proposalId].createdAt > 0, "Proposal does not exist");
        _;
    }

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    constructor(
        IVotes _token,
        TimelockController _timelock,
        uint256 _votingDelay,
        uint256 _votingPeriod,
        uint256 _proposalThreshold,
        uint256 _quorumPercentage
    )
        Governor("BaseGovernanceDAO")
        GovernorSettings(_votingDelay, _votingPeriod, _proposalThreshold)
        GovernorVotes(_token)
        GovernorVotesQuorumFraction(_quorumPercentage)
        GovernorTimelockControl(_timelock)
    {
        require(_votingDelay >= MIN_VOTING_DELAY && _votingDelay <= MAX_VOTING_DELAY, "Invalid voting delay");
        require(_votingPeriod >= MIN_VOTING_PERIOD && _votingPeriod <= MAX_VOTING_PERIOD, "Invalid voting period");
        require(_proposalThreshold <= MAX_PROPOSAL_THRESHOLD, "Proposal threshold too high");
        require(_quorumPercentage > 0 && _quorumPercentage <= 100, "Invalid quorum percentage");
    }

    // =============================================================================
    // PROPOSAL CREATION
    // =============================================================================

    function proposeWithMetadata(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        string memory title,
        string memory category,
        ProposalType proposalType,
        uint256 requestedAmount,
        address beneficiary
    ) public onlyAuthorizedProposer returns (uint256) {
        require(bytes(title).length > 0, "Title cannot be empty");
        require(bytes(description).length > 0, "Description cannot be empty");
        
        uint256 proposalId = propose(targets, values, calldatas, description);
        
        proposalMetadata[proposalId] = ProposalMetadata({
            title: title,
            description: description,
            category: category,
            requestedAmount: requestedAmount,
            beneficiary: beneficiary,
            createdAt: block.timestamp,
            executedAt: 0,
            isExecuted: false,
            proposalType: proposalType
        });
        
        totalProposals++;
        activeProposals.push(proposalId);
        
        emit ProposalCreatedWithMetadata(proposalId, msg.sender, title, proposalType);
        
        return proposalId;
    }

    function proposeTreasuryAllocation(
        address recipient,
        uint256 amount,
        string memory purpose,
        uint256 releaseTime
    ) external onlyAuthorizedProposer returns (uint256) {
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");
        require(amount <= treasuryBalance, "Insufficient treasury balance");
        require(releaseTime > block.timestamp, "Release time must be in future");
        
        address[] memory targets = new address[](1);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        
        targets[0] = address(this);
        values[0] = 0;
        calldatas[0] = abi.encodeWithSignature(
            "executeTreasuryAllocation(address,uint256,string)",
            recipient,
            amount,
            purpose
        );
        
        string memory description = string(abi.encodePacked(
            "Treasury Allocation: ",
            purpose,
            " - Amount: ",
            Strings.toString(amount)
        ));
        
        return proposeWithMetadata(
            targets,
            values,
            calldatas,
            description,
            string(abi.encodePacked("Treasury Allocation: ", purpose)),
            "Treasury",
            ProposalType.TREASURY_ALLOCATION,
            amount,
            recipient
        );
    }

    // =============================================================================
    // VOTING FUNCTIONS
    // =============================================================================

    function castVoteWithContribution(
        uint256 proposalId,
        uint8 support,
        string memory reason,
        uint256 contributionScore
    ) public validProposal(proposalId) returns (uint256) {
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        
        // Update contribution score if provided
        if (contributionScore > 0) {
            _updateContributionScore(msg.sender, contributionScore);
        }
        
        hasVoted[proposalId][msg.sender] = true;
        
        return castVoteWithReason(proposalId, support, reason);
    }

    function castVotesBatch(
        uint256[] memory proposalIds,
        uint8[] memory supports,
        string[] memory reasons
    ) external {
        require(
            proposalIds.length == supports.length && 
            supports.length == reasons.length,
            "Array length mismatch"
        );
        
        for (uint256 i = 0; i < proposalIds.length; i++) {
            if (!hasVoted[proposalIds[i]][msg.sender]) {
                castVoteWithReason(proposalIds[i], supports[i], reasons[i]);
                hasVoted[proposalIds[i]][msg.sender] = true;
            }
        }
    }

    // =============================================================================
    // EXECUTION FUNCTIONS
    // =============================================================================

    function executeProposal(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) public payable override(Governor, GovernorTimelockControl) {
        uint256 proposalId = hashProposal(targets, values, calldatas, descriptionHash);
        
        super.execute(targets, values, calldatas, descriptionHash);
        
        proposalMetadata[proposalId].isExecuted = true;
        proposalMetadata[proposalId].executedAt = block.timestamp;
        executedProposals++;
        
        // Remove from active proposals
        _removeFromActiveProposals(proposalId);
    }

    function executeTreasuryAllocation(
        address recipient,
        uint256 amount,
        string memory purpose
    ) external {
        require(msg.sender == address(this), "Only callable by governance");
        require(amount <= treasuryBalance, "Insufficient treasury balance");
        
        treasuryBalance -= amount;
        
        // Transfer tokens (assuming ETH for simplicity)
        payable(recipient).transfer(amount);
        
        emit TreasuryAllocationExecuted(0, recipient, amount);
    }

    // =============================================================================
    // BUILDER REWARDS FUNCTIONS
    // =============================================================================

    function distributeBuilderRewards(
        address[] memory builders,
        uint256[] memory amounts,
        string[] memory contributions
    ) external onlyOwner {
        require(
            builders.length == amounts.length && 
            amounts.length == contributions.length,
            "Array length mismatch"
        );
        
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            totalAmount += amounts[i];
        }
        
        require(totalAmount <= builderRewardsPool, "Insufficient rewards pool");
        
        for (uint256 i = 0; i < builders.length; i++) {
            BuilderReward memory reward = BuilderReward({
                builder: builders[i],
                amount: amounts[i],
                contribution: contributions[i],
                timestamp: block.timestamp,
                isClaimed: false,
                multiplier: _calculateRewardMultiplier(builders[i])
            });
            
            builderRewards[builders[i]].push(reward);
            builderRewardsPool -= amounts[i];
            
            emit BuilderRewardDistributed(builders[i], amounts[i], contributions[i]);
        }
    }

    function claimBuilderReward(uint256 rewardIndex) external nonReentrant {
        require(rewardIndex < builderRewards[msg.sender].length, "Invalid reward index");
        
        BuilderReward storage reward = builderRewards[msg.sender][rewardIndex];
        require(!reward.isClaimed, "Reward already claimed");
        require(reward.builder == msg.sender, "Not your reward");
        
        reward.isClaimed = true;
        
        uint256 finalAmount = (reward.amount * reward.multiplier) / 100;
        payable(msg.sender).transfer(finalAmount);
    }

    // =============================================================================
    // INTERNAL FUNCTIONS
    // =============================================================================

    function _updateContributionScore(address builder, uint256 newScore) internal {
        uint256 oldScore = contributionScores[builder];
        contributionScores[builder] = newScore;
        
        emit ContributionScoreUpdated(builder, oldScore, newScore);
    }

    function _calculateRewardMultiplier(address builder) internal view returns (uint256) {
        uint256 score = contributionScores[builder];
        
        if (score >= 10000) return 200; // 2x multiplier
        if (score >= 5000) return 150;  // 1.5x multiplier
        if (score >= 1000) return 125;  // 1.25x multiplier
        
        return 100; // 1x multiplier
    }

    function _removeFromActiveProposals(uint256 proposalId) internal {
        for (uint256 i = 0; i < activeProposals.length; i++) {
            if (activeProposals[i] == proposalId) {
                activeProposals[i] = activeProposals[activeProposals.length - 1];
                activeProposals.pop();
                break;
            }
        }
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    function getProposalMetadata(uint256 proposalId)
        external
        view
        returns (
            string memory title,
            string memory description,
            string memory category,
            uint256 requestedAmount,
            address beneficiary,
            bool isExecuted
        )
    {
        ProposalMetadata memory metadata = proposalMetadata[proposalId];
        return (
            metadata.title,
            metadata.description,
            metadata.category,
            metadata.requestedAmount,
            metadata.beneficiary,
            metadata.isExecuted
        );
    }

    function getBuilderRewards(address builder)
        external
        view
        returns (BuilderReward[] memory)
    {
        return builderRewards[builder];
    }

    function getActiveProposals() external view returns (uint256[] memory) {
        return activeProposals;
    }

    function getTreasuryInfo()
        external
        view
        returns (
            uint256 balance,
            uint256 rewardsPool,
            uint256 totalProposalsCount,
            uint256 executedProposalsCount
        )
    {
        return (treasuryBalance, builderRewardsPool, totalProposals, executedProposals);
    }

    // =============================================================================
    // ADMIN FUNCTIONS
    // =============================================================================

    function addAuthorizedProposer(address proposer) external onlyOwner {
        require(proposer != address(0), "Invalid proposer");
        authorizedProposers[proposer] = true;
        activeProposers.push(proposer);
    }

    function removeAuthorizedProposer(address proposer) external onlyOwner {
        authorizedProposers[proposer] = false;
        
        for (uint256 i = 0; i < activeProposers.length; i++) {
            if (activeProposers[i] == proposer) {
                activeProposers[i] = activeProposers[activeProposers.length - 1];
                activeProposers.pop();
                break;
            }
        }
    }

    function updateBuilderRewardsContract(address newContract) external onlyOwner {
        require(newContract != address(0), "Invalid contract address");
        builderRewardsContract = newContract;
    }

    function depositToTreasury() external payable {
        treasuryBalance += msg.value;
    }

    function depositToRewardsPool() external payable {
        builderRewardsPool += msg.value;
    }

    // =============================================================================
    // OVERRIDE FUNCTIONS
    // =============================================================================

    function votingDelay()
        public
        view
        override(IGovernor, GovernorSettings)
        returns (uint256)
    {
        return super.votingDelay();
    }

    function votingPeriod()
        public
        view
        override(IGovernor, GovernorSettings)
        returns (uint256)
    {
        return super.votingPeriod();
    }

    function quorum(uint256 blockNumber)
        public
        view
        override(IGovernor, GovernorVotesQuorumFraction)
        returns (uint256)
    {
        return super.quorum(blockNumber);
    }

    function proposalThreshold()
        public
        view
        override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function _execute(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._execute(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // =============================================================================
    // RECEIVE FUNCTION
    // =============================================================================

    receive() external payable {
        treasuryBalance += msg.value;
    }
}
