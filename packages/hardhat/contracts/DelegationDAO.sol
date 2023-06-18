//SPDX-License-Identifier: GPL-3.0-only

pragma solidity >=0.8.0;

import "./StakingInterface.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

//ordered from most basic to most special contracts
contract DelegationDAO is AccessControl, Pausable {
    using SafeMath for uint256;

    bytes32 public constant MEMBER = keccak256("MEMBER");

    //collecting funds = openly accepting funds, but haven't yet reached the min requirement
    //staking = DAO is bonded to collator and is earning rewards
    //revoking = revoke request in progress, still bonded to collator but in waiting period for stake to fully revokes
    //revoked = dao memebers can finally withdraw funds and associate rewards
    enum daoState {COLLECTING, STAKING, REVOKING, REVOKED}

    daoState public currentState;

    //keep track of the memember stakes - no staking rewards.

    mapping(address => uint256) public memberStakes;

    //Total pool stake - no rewards.
    uint256 public totalStake;

    ParachainStaking public staking;

    address public constant stakingPrecompileAddress = 0x0000000000000000000000000000000000000800;
    
    //Minimum delegation amount
    uint256 public constant MinDelegatorStk = 5 ether;

    //The collator we want to delegate to
    address public target;

    //Event for member deposit
    event deposit(address indexed _from, uint _value);

    //Event for member withdrawal
    event withdrawal(address indexed _from, address indexed _to, uint _value);

    //Initalize a new DelegationDAo dedicated to delegating to the given collator target.
    constructor(address _target, address admin){
        target = _target;
        staking = ParachainStaking(stakingPrecompileAddress);
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setupRole(MEMBER, admin);
        currentState = daoState.COLLECTING;
    }

    //This is a test function to do proposals
    struct Propose {
    address proposedTarget;
    uint256 votesFor;
    uint256 votesAgainst;
    }

    mapping(uint256 => Propose) public proposals;
    uint256 public proposalCount;

    
    function createProposal(address _proposedTarget) public onlyRole(MEMBER) {
        proposals[proposalCount] = Propose(_proposedTarget, 0, 0);
        proposalCount++;
    }

    //members can vote for or against
    function vote(uint256 proposalId, bool support) public onlyRole(MEMBER) {
        if (support) {
            proposals[proposalId].votesFor++;
        } else {
            proposals[proposalId].votesAgainst++;
        }
    }

    function executeProposal(uint256 proposalId) public onlyRole(DEFAULT_ADMIN_ROLE) {
        Propose storage proposal = proposals[proposalId];
        require(proposal.votesFor > proposal.votesAgainst, "Not enough support for the proposal.");
        target = proposal.proposedTarget;
    }


    //Grants user role of admin
    function grant_admin(address newAdmin) public 
        onlyRole(DEFAULT_ADMIN_ROLE)
        onlyRole(MEMBER)
        {
            grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
            grantRole(MEMBER, newAdmin);
        }

    //Grants user membership
    function grant_member(address newMember) public 
        onlyRole(DEFAULT_ADMIN_ROLE)
        {
            grantRole(MEMBER, newMember);
        }
        
    //Revoke a user membership
    function remove_member(address payable exMember) public 
        onlyRole(DEFAULT_ADMIN_ROLE)
        {
            revokeRole(MEMBER, exMember);
        }

    //Pause the function in case of emergencies
    function pause() public onlyRole(DEFAULT_ADMIN_ROLE)   {
        _pause();
    }

    function unpause() public onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function check_free_balance() public view onlyRole(MEMBER) returns(uint256){
        return address(this).balance;
    }

    function change_target(address newCollator) public onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(currentState == daoState.REVOKED || currentState == daoState.COLLECTING,
        "DAO not in the correct state to change staking target");
        target = newCollator;
    }

    function reset_dao() public onlyRole(DEFAULT_ADMIN_ROLE){
        currentState = daoState.COLLECTING;
    }

    function add_stake() external payable onlyRole(MEMBER){
        if(currentState == daoState.STAKING){
            //sanity check
            if(!staking.isDelegator(address(this))){
                revert("THIS DAO IS IN AN INCONCISIS STATE");
            }
            memberStakes[msg.sender] = memberStakes[msg.sender].add(msg.value);
            totalStake = totalStake.add(msg.value);
            emit deposit(msg.sender, msg.value);
            staking.delegatorBondMore(target, msg.value);
        }
        else if (currentState == daoState.COLLECTING){
            memberStakes[msg.sender] = memberStakes[msg.sender].add(msg.value);
            totalStake = totalStake.add(msg.value);
            emit deposit(msg.sender, msg.value);
            if(totalStake < MinDelegatorStk){
                return;
            }
            else{
                staking.delegate(target, address(this).balance, staking.candidateDelegationCount(target), staking.delegatorDelegationCount(address(this)));
            }
        }
        else{
            revert("THE DAO IS NOT ACCEPTING NEW STAKES RN");
        }
    }
    
    function schedule_revoke() public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(currentState == daoState.STAKING, "The DAO is in staking state,");
        staking.scheduleRevokeDelegation(target);
        currentState = daoState.REVOKING;
    }

    function execute_revoke() internal onlyRole(MEMBER) returns(bool){
        require(currentState == daoState.REVOKING, "The DAO is in a incorrect state. :(");
        staking.executeDelegationRequest(address(this), target);
        if(staking.isDelegator(address(this))){
            return false;
        } else {
            currentState = daoState.REVOKED;
            return true;
        }

    }

    function withdraw(address payable account) public onlyRole(MEMBER) {
        require(currentState != daoState.STAKING, "The DAO is not in the correct state to withdraw");

        if (currentState == daoState.REVOKING) {
            bool result = execute_revoke();
            require(result, "Exit delay period hasn't finished yet.");
        }

        if (currentState == daoState.REVOKED || currentState == daoState.COLLECTING) {
            //allow user to withdraw funds

            //first sanity check
            if(staking.isDelegator(address(this))){
                revert("The DAO is in an inconsistent state");
            }
            require(totalStake != 0, "Cannot divide by 0");

            //Calculate the amount the user is owed
            uint amount = address(this).balance.mul(memberStakes[msg.sender]).div(totalStake);
            //do we have balance?
            require(check_free_balance() >= amount, "Not enough free balance!");
            //Send payment
            Address.sendValue(account, amount);


            totalStake = totalStake.sub(memberStakes[msg.sender]);
            memberStakes[msg.sender] = 0;
            emit withdrawal(msg.sender, account, amount);

        }


    }
    
    //if they want to reinvest instead of getting the rewards, we should create an easier way to do it
    // function reinvest() public onlyRole(DEFAULT_ADMIN_ROLE){
    //     require(currentState == daoState.STAKING, "DAO is not staking.");
    //     uint reward = address(this).balance.mul(memberStakes[msg.sender]).div(totalStake);
    //     staking.claimRewards();
    //     staking.delegatorBondMore(target, reward);
    // }

    //Admin emergency withdraw without requiring to be in STAKING state.
    function emergencyWithdraw(address payable account, uint256 amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount <= address(this).balance, "Not enough balance!");
        Address.sendValue(account, amount);
    }



}