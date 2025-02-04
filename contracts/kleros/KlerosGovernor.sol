/**
 *  @authors: [@unknownunknown1]
 *  @reviewers: [@ferittuncer*, @clesaege]
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

/* solium-disable security/no-block-members */
/* solium-disable max-len*/

pragma solidity ^0.4.24;

import "@kleros/kleros-interaction/contracts/standard/arbitration/Arbitrable.sol";
import "@kleros/kleros-interaction/contracts/libraries/CappedMath.sol";

/** @title KlerosGovernor
 *  Note that this contract trusts that the Arbitrator is honest and will not re-enter or modify its costs during a call.
 *  Also note that tx.origin should not matter in contracts called by the governor.
 */
contract KlerosGovernor is Arbitrable{
    using CappedMath for uint;

    /* *** Contract variables *** */
    enum Status {NoDispute, DisputeCreated, Resolved}

    struct Session {
        Round[] rounds; // Tracks each appeal round of a dispute.
        uint ruling; // The ruling that was given in this session.
        uint disputeID; // ID given to the dispute of the session.
        uint[] submittedLists; // Tracks all lists that were submitted in a session. submittedLists[submissionID].
        uint sumDeposit; // Sum of all submission deposits in a session (minus arbitration fees). Is needed for calculating a reward.
        Status status; // Status of a session.
        mapping(bytes32 => bool) alreadySubmitted; // Indicates whether or not the transaction list was already submitted in order to catch duplicates. alreadySubmitted[listHash].
    }

    struct Transaction {
        address target; // The address to call.
        uint value; // Value paid by governor contract that will be used as msg.value in the execution.
        bytes data; // Calldata of the transaction.
        bool executed; // Whether the transaction was already executed or not.
    }
    struct Submission {
        address submitter; // The one who submits the list.
        uint deposit; // Value of a deposit paid upon submission of the list.
        Transaction[] txs; // Transactions stored in the list. txs[_transactionIndex].
        bytes32 listHash; // A hash chain of all transactions stored in the list. Is used for catching duplicates.
        uint submissionTime; // Time the list was submitted.
        bool approved; // Whether the list was approved for execution or not.
    }

    struct Round {
        mapping (uint => uint) paidFees; // Tracks the fees paid by each side in this round. paidFees[submissionID].
        mapping (uint => bool) hasPaid; // True when the side has fully paid its fees, false otherwise. hasPaid[submissionID].
        uint feeRewards; // Sum of reimbursable fees and stake rewards available to the parties that made contributions to the side that ultimately wins a dispute.
        mapping(address => mapping (uint => uint)) contributions; // Maps contributors to their contributions for each side. contributions[address][submissionID].
        uint successfullyPaid; // Sum of all successfully paid fees paid by all sides.
    }

    uint constant NO_SHADOW_WINNER = uint(-1); // The value that indicates that no one has successfully paid appeal fees in a current round. It's -1 and not 0, because 0 can be a valid submission index.

    address public deployer; // The address of the deployer of the contract.

    uint public reservedETH; // Sum of contract's submission deposits and appeal fees. These funds are not to be used in the execution of transactions.

    uint public submissionDeposit; // Value in wei that needs to be paid in order to submit the list. Note that this value should be higher than arbitration cost.
    uint public submissionTimeout; // Time in seconds allowed for submitting the lists. Once it's passed the contract enters the approval period.
    uint public withdrawTimeout; // Time in seconds allowed to withdraw a submitted list.
    uint public sharedMultiplier; // Multiplier for calculating the appeal fee that must be paid by each side in the case where there is no winner/loser (e.g. when the arbitrator ruled "refuse to arbitrate").
    uint public winnerMultiplier; // Multiplier for calculating the appeal fee of the party that won the previous round.
    uint public loserMultiplier; // Multiplier for calculating the appeal fee of the party that lost the previous round.
    uint public constant MULTIPLIER_DIVISOR = 10000; // Divisor parameter for multipliers.

    uint public lastApprovalTime; // The time of the last approval of a transaction list.
    uint public shadowWinner; // Submission index of the first list that paid appeal fees. If it stays the only list that paid appeal fees, it will win regardless of the final ruling.

    Submission[] public submissions; // Stores all created transaction lists. submissions[_listID].
    Session[] public sessions; // Stores all submitting sessions. sessions[_session].

    /* *** Modifiers *** */
    modifier duringSubmissionPeriod() {require(now - lastApprovalTime <= submissionTimeout, "Submission time has ended."); _;}
    modifier duringApprovalPeriod() {require(now - lastApprovalTime > submissionTimeout, "Approval time has not started yet."); _;}
    modifier onlyByGovernor() {require(address(this) == msg.sender, "Only the governor can execute this."); _;}

    /* *** Events *** */
    /** @dev Emitted when a new list is submitted.
     *  @param _listID The index of the transaction list in the array of lists.
     *  @param _submitter The one who submitted the list.
     *  @param _session The number of the current session.
     *  @param _description The string in CSV format that contains labels of list's transactions.
     *  Note that the submitter may give bad descriptions of correct actions, but this is to be seen as UI enhancement, not a critical feature and that would play against him in case of dispute.
     */
    event ListSubmitted(uint indexed _listID, address indexed _submitter, uint _session, string _description);

    /** @dev Constructor.
     *  @param _arbitrator The arbitrator of the contract. It should support appealPeriod.
     *  @param _extraData Extra data for the arbitrator.
     *  @param _submissionDeposit The deposit required for submission.
     *  @param _submissionTimeout Time in seconds allocated for submitting transaction list.
     *  @param _withdrawTimeout Time in seconds after submission that allows to withdraw submitted list.
     *  @param _sharedMultiplier Multiplier of the appeal cost that submitters has to pay for a round when there is no winner/loser in the previous round. In basis points.
     *  @param _winnerMultiplier Multiplier of the appeal cost that the winner has to pay for a round. In basis points.
     *  @param _loserMultiplier Multiplier of the appeal cost that the loser has to pay for a round. In basis points.
     */
    constructor (
        Arbitrator _arbitrator,
        bytes _extraData,
        uint _submissionDeposit,
        uint _submissionTimeout,
        uint _withdrawTimeout,
        uint _sharedMultiplier,
        uint _winnerMultiplier,
        uint _loserMultiplier
    ) public Arbitrable(_arbitrator, _extraData){
        lastApprovalTime = now;
        submissionDeposit = _submissionDeposit;
        submissionTimeout = _submissionTimeout;
        withdrawTimeout = _withdrawTimeout;
        sharedMultiplier = _sharedMultiplier;
        winnerMultiplier = _winnerMultiplier;
        loserMultiplier = _loserMultiplier;
        shadowWinner = NO_SHADOW_WINNER;
        sessions.length++;
        deployer = msg.sender;
    }

    /** @dev Sets the meta evidence. Can only be called once.
     *  @param _metaEvidence The URI of the meta evidence file.
     */
    function setMetaEvidence(string _metaEvidence) external {
        require(msg.sender == deployer, "Can only be called once by the deployer of the contract.");
        deployer = address(0);
        emit MetaEvidence(0, _metaEvidence);
    }

    /** @dev Changes the value of the deposit required for submitting a list.
     *  @param _submissionDeposit The new value of a required deposit. In wei.
     */
    function changeSubmissionDeposit(uint _submissionDeposit) public onlyByGovernor {
        submissionDeposit = _submissionDeposit;
    }

    /** @dev Changes the time allocated for submission.
     *  @param _submissionTimeout The new duration of submission time. In seconds.
     */
    function changeSubmissionTimeout(uint _submissionTimeout) public onlyByGovernor duringSubmissionPeriod {
        submissionTimeout = _submissionTimeout;
    }

    /** @dev Changes the time allowed for list withdrawal.
     *  @param _withdrawTimeout The new duration of withdraw timeout. In seconds.
     */
    function changeWithdrawTimeout(uint _withdrawTimeout) public onlyByGovernor {
        withdrawTimeout = _withdrawTimeout;
    }

    /** @dev Changes the proportion of appeal fees that must be added to appeal cost when there is no winner or loser.
     *  @param _sharedMultiplier The new shared multiplier value in basis points.
     */
    function changeSharedMultiplier(uint _sharedMultiplier) public onlyByGovernor {
        sharedMultiplier = _sharedMultiplier;
    }

    /** @dev Changes the proportion of appeal fees that must be added to appeal cost for the winning party.
     *  @param _winnerMultiplier The new winner multiplier value in basis points.
     */
    function changeWinnerMultiplier(uint _winnerMultiplier) public onlyByGovernor {
        winnerMultiplier = _winnerMultiplier;
    }

    /** @dev Changes the proportion of appeal fees that must be added to appeal cost for the losing party.
     *  @param _loserMultiplier The new loser multiplier value in basis points.
     */
    function changeLoserMultiplier(uint _loserMultiplier) public onlyByGovernor {
        loserMultiplier = _loserMultiplier;
    }

    /** @dev Changes the arbitrator of the contract.
     *  @param _arbitrator The new trusted arbitrator.
     *  @param _arbitratorExtraData The extra data used by the new arbitrator.
     */
    function changeArbitrator(Arbitrator _arbitrator, bytes _arbitratorExtraData) public onlyByGovernor duringSubmissionPeriod {
        arbitrator = _arbitrator;
        arbitratorExtraData = _arbitratorExtraData;
    }

    /** @dev Creates transaction list based on input parameters and submits it for potential approval and execution.
     *  Transactions must be ordered by their hash.
     *  @param _target List of addresses to call.
     *  @param _value List of values required for respective addresses.
     *  @param _data Concatenated calldata of all transactions of this list.
     *  @param _dataSize List of lengths in bytes required to split calldata for its respective targets.
     *  @param _description String in CSV format that describes list's transactions.
     */
    function submitList(address[] _target, uint[] _value, bytes _data, uint[] _dataSize, string _description) public payable duringSubmissionPeriod {
        require(_target.length == _value.length, "Incorrect input. Target and value arrays must be of the same length.");
        require(_target.length == _dataSize.length, "Incorrect input. Target and datasize arrays must be of the same length.");
        require(msg.value == submissionDeposit, "Submission deposit must be paid in exact amount.");
        Session storage session = sessions[sessions.length - 1];
        Submission storage submission = submissions[submissions.length++];
        submission.submitter = msg.sender;
        submission.deposit = submissionDeposit;
        bytes32 listHash;
        bytes32 prevTxHash;
        bytes32 currentTxHash;
        uint readingPosition;
        for (uint i = 0; i < _target.length; i++){
            bytes memory readData = new bytes(_dataSize[i]);
            Transaction storage transaction = submission.txs[submission.txs.length++];
            transaction.target = _target[i];
            transaction.value = _value[i];
            for (uint j = 0; j < _dataSize[i]; j++){
                readData[j] = _data[readingPosition + j];
            }
            transaction.data = readData;
            readingPosition += _dataSize[i];
            currentTxHash = keccak256(abi.encodePacked(transaction.target, transaction.value, transaction.data));
            require(uint(currentTxHash) >= uint(prevTxHash), "The transactions are in incorrect order.");
            listHash = keccak256(abi.encodePacked(currentTxHash, listHash));
            prevTxHash = currentTxHash;
        }
        require(!session.alreadySubmitted[listHash], "The same list was already submitted earlier.");
        session.alreadySubmitted[listHash] = true;
        submission.listHash = listHash;
        submission.submissionTime = now;
        session.sumDeposit += submissionDeposit;
        session.submittedLists.push(submissions.length - 1);
        emit ListSubmitted(submissions.length - 1, msg.sender, sessions.length - 1, _description);

        reservedETH += submissionDeposit;
    }

    /** @dev Withdraws submitted transaction list. Reimburses submission deposit.
     *  Withdrawal is only possible during the first half of the submission period and during withdrawPeriod seconds after the submission is made.
     *  @param _submissionID Submission's index in the array of submitted lists of the current sesssion.
     *  @param _listHash Hash of a withdrawing list.
     */
    function withdrawTransactionList(uint _submissionID, bytes32 _listHash) public {
        Session storage session = sessions[sessions.length - 1];
        Submission storage submission = submissions[session.submittedLists[_submissionID]];
        require(now - lastApprovalTime <= submissionTimeout / 2, "Lists can be withdrawn only in the first half of the submission period.");
        // This require statement is an extra check to prevent _submissionID linking to the wrong list because of index swap during withdrawal.
        require(submission.listHash == _listHash, "Provided hash doesn't correspond with submission ID.");
        require(submission.submitter == msg.sender, "Can't withdraw the list created by someone else.");
        require(now - submission.submissionTime <= withdrawTimeout, "Withdrawing time has passed.");
        session.submittedLists[_submissionID] = session.submittedLists[session.submittedLists.length - 1];
        session.alreadySubmitted[_listHash] = false;
        session.submittedLists.length--;
        session.sumDeposit = session.sumDeposit.subCap(submission.deposit);
        msg.sender.transfer(submission.deposit);

        reservedETH = reservedETH.subCap(submission.deposit);
    }

    /** @dev Approves a transaction list or creates a dispute if more than one list was submitted. TRUSTED.
     *  If nothing was submitted changes session.
     */
    function executeSubmissions() public duringApprovalPeriod {
        Session storage session = sessions[sessions.length - 1];
        require(session.status == Status.NoDispute, "Can't approve transaction list while dispute is active.");
        if (session.submittedLists.length == 0){
            lastApprovalTime = now;
            session.status = Status.Resolved;
            sessions.length++;
        } else if (session.submittedLists.length == 1){
            Submission storage submission = submissions[session.submittedLists[0]];
            submission.approved = true;
            uint sumDeposit = session.sumDeposit;
            session.sumDeposit = 0;
            submission.submitter.send(sumDeposit);
            lastApprovalTime = now;
            session.status = Status.Resolved;
            sessions.length++;

            reservedETH = reservedETH.subCap(sumDeposit);
        } else {
            session.status = Status.DisputeCreated;
            uint arbitrationCost = arbitrator.arbitrationCost(arbitratorExtraData);
            session.disputeID = arbitrator.createDispute.value(arbitrationCost)(session.submittedLists.length, arbitratorExtraData);
            session.rounds.length++;
            session.sumDeposit = session.sumDeposit.subCap(arbitrationCost);

            reservedETH = reservedETH.subCap(arbitrationCost);
            emit Dispute(arbitrator, session.disputeID, 0, sessions.length - 1);
        }
    }

    /** @dev Takes up to the total amount required to fund a side of an appeal. Reimburses the rest. Creates an appeal if at least two lists are funded. TRUSTED.
     *  @param _submissionID Submission's index in the array of submitted lists of the current sesssion. Note that submissionID can be swapped with an ID of a withdrawn list in submission period.
     */
    function fundAppeal(uint _submissionID) public payable {
        Session storage session = sessions[sessions.length - 1];
        require(_submissionID <= session.submittedLists.length - 1, "SubmissionID is out of bounds.");
        require(session.status == Status.DisputeCreated, "No dispute to appeal.");
        require(arbitrator.disputeStatus(session.disputeID) == Arbitrator.DisputeStatus.Appealable, "Dispute is not appealable.");
        (uint appealPeriodStart, uint appealPeriodEnd) = arbitrator.appealPeriod(session.disputeID);
        require(
            now >= appealPeriodStart && now < appealPeriodEnd,
            "Appeal fees must be paid within the appeal period."
        );

        uint winner = arbitrator.currentRuling(session.disputeID);
        uint multiplier;
        // Unlike in submittedLists, in arbitrator "0" is reserved for "refuse to arbitrate" option. So we need to add 1 to map submission IDs with choices correctly.
        if (winner == _submissionID + 1){
            multiplier = winnerMultiplier;
        } else if (winner == 0){
            multiplier = sharedMultiplier;
        } else {
            require(now - appealPeriodStart < (appealPeriodEnd - appealPeriodStart)/2, "The loser must pay during the first half of the appeal period.");
            multiplier = loserMultiplier;
        }

        Round storage round = session.rounds[session.rounds.length - 1];
        require(!round.hasPaid[_submissionID], "Appeal fee has already been paid.");
        uint appealCost = arbitrator.appealCost(session.disputeID, arbitratorExtraData);
        uint totalCost = appealCost.addCap((appealCost.mulCap(multiplier)) / MULTIPLIER_DIVISOR);

        // Take up to the amount necessary to fund the current round at the current costs.
        uint contribution; // Amount contributed.
        uint remainingETH; // Remaining ETH to send back.
        (contribution, remainingETH) = calculateContribution(msg.value, totalCost.subCap(round.paidFees[_submissionID]));
        round.contributions[msg.sender][_submissionID] += contribution;
        round.paidFees[_submissionID] += contribution;
        // Add contribution to reward when the fee funding is successful, otherwise it can be withdrawn later.
        if (round.paidFees[_submissionID] >= totalCost){
            round.hasPaid[_submissionID] = true;
            if (shadowWinner == NO_SHADOW_WINNER)
                shadowWinner = _submissionID;

            round.feeRewards += round.paidFees[_submissionID];
            round.successfullyPaid += round.paidFees[_submissionID];
        }

        // Reimburse leftover ETH.
        msg.sender.send(remainingETH);
        reservedETH += contribution;

        if (shadowWinner != NO_SHADOW_WINNER && shadowWinner != _submissionID && round.hasPaid[_submissionID]){
            shadowWinner = NO_SHADOW_WINNER;
            arbitrator.appeal.value(appealCost)(session.disputeID, arbitratorExtraData);
            session.rounds.length++;
            round.feeRewards = round.feeRewards.subCap(appealCost);
            reservedETH = reservedETH.subCap(appealCost);
        }
    }

    /** @dev Returns the contribution value and remainder from available ETH and required amount.
     *  @param _available The amount of ETH available for the contribution.
     *  @param _requiredAmount The amount of ETH required for the contribution.
     *  @return taken The amount of ETH taken.
     *  @return remainder The amount of ETH left from the contribution.
     */
    function calculateContribution(uint _available, uint _requiredAmount)
        internal
        pure
        returns(uint taken, uint remainder)
    {
        if (_requiredAmount > _available)
            taken = _available;
        else {
            taken = _requiredAmount;
            remainder = _available - _requiredAmount;
        }
    }

    /** @dev Sends the fee stake rewards and reimbursements proportional to the contributions made to the winner of a dispute. Reimburses contributions if there is no winner.
     *  @param _beneficiary The address that made contributions to a request.
     *  @param _session The session from which to withdraw.
     *  @param _round The round from which to withdraw.
     *  @param _submissionID Submission's index in the array of submitted lists of the session which the beneficiary contributed to.
     */
    function withdrawFeesAndRewards(address _beneficiary, uint _session, uint _round, uint _submissionID) public {
        Session storage session = sessions[_session];
        Round storage round = session.rounds[_round];
        require(session.status == Status.Resolved, "Session has an ongoing dispute.");
        uint reward;
        // Allow to reimburse if funding of the round was unsuccessful.
        if (!round.hasPaid[_submissionID]) {
            reward = round.contributions[_beneficiary][_submissionID];
        } else if (session.ruling == 0 || !round.hasPaid[session.ruling - 1]) {
            // Reimburse unspent fees proportionally if there is no winner and loser. Also applies to the situation where the ultimate winner didn't pay appeal fees fully.
            reward = round.successfullyPaid > 0
                ? (round.contributions[_beneficiary][_submissionID] * round.feeRewards) / round.successfullyPaid
                : 0;
        } else if (session.ruling - 1 == _submissionID) {
            // Reward the winner. Subtract 1 from ruling to sync submissionID with arbitrator's choice.
            reward = round.paidFees[_submissionID] > 0
                ? (round.contributions[_beneficiary][_submissionID] * round.feeRewards) / round.paidFees[_submissionID]
                : 0;
        }
        round.contributions[_beneficiary][_submissionID] = 0;

        _beneficiary.send(reward); // It is the user responsibility to accept ETH.
        reservedETH = reservedETH.subCap(reward);
    }

    /** @dev Gives a ruling for a dispute. Must be called by the arbitrator.
     *  The purpose of this function is to ensure that the address calling it has the right to rule on the contract.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refuse to arbitrate".
     */
    function rule(uint _disputeID, uint _ruling) public {
        Session storage session = sessions[sessions.length - 1];
        require(msg.sender == address(arbitrator), "Must be called by the arbitrator.");
        require(session.status == Status.DisputeCreated, "The dispute has already been resolved.");
        require(_ruling <= session.submittedLists.length, "Ruling is out of bounds.");

        if (shadowWinner != NO_SHADOW_WINNER)
            executeRuling(_disputeID, shadowWinner + 1);
        else
            executeRuling(_disputeID, _ruling);
    }

    /** @dev Executes a ruling of a dispute.
     *  @param _disputeID ID of the dispute in the Arbitrator contract.
     *  @param _ruling Ruling given by the arbitrator. Note that 0 is reserved for "Refuse to arbitrate".
     *  If the final ruling is "0" nothing is approved and deposits will stay locked in the contract.
     */
    function executeRuling(uint _disputeID, uint _ruling) internal {
        Session storage session = sessions[sessions.length - 1];
        if (_ruling != 0){
            Submission storage submission = submissions[session.submittedLists[_ruling - 1]];
            submission.approved = true;
            submission.submitter.send(session.sumDeposit);
        }
        // If the ruiling is "0" the reserved funds of this session become expendable.
        reservedETH = reservedETH.subCap(session.sumDeposit);

        session.sumDeposit = 0;
        shadowWinner = NO_SHADOW_WINNER;
        lastApprovalTime = now;
        session.status = Status.Resolved;
        session.ruling = _ruling;
        sessions.length++;
    }

    /** @dev Executes selected transactions of the list. UNTRUSTED.
     *  @param _listID The index of the transaction list in the array of lists.
     *  @param _cursor Index of the transaction from which to start executing.
     *  @param _count Number of transactions to execute. Executes until the end if set to "0" or number higher than number of transactions in the list.
     */
    function executeTransactionList(uint _listID, uint _cursor, uint _count) public {
        Submission storage submission = submissions[_listID];
        require(submission.approved, "Can't execute list that wasn't approved.");
        for (uint i = _cursor; i < submission.txs.length && (_count == 0 || i < _cursor + _count); i++){
            Transaction storage transaction = submission.txs[i];
            uint expendableFunds = getExpendableFunds();
            if (!transaction.executed && transaction.value <= expendableFunds){
                bool callResult = transaction.target.call.value(transaction.value)(transaction.data); // solium-disable-line security/no-call-value
                // An extra check to prevent re-entrancy through target call.
                if (callResult == true) {
                    require(!transaction.executed, "This transaction has already been executed.");
                    transaction.executed = true;
                }
            }
        }
    }

    /** @dev Fallback function to receive funds for the execution of transactions.
     */
    function () public payable {}

    /** @dev Gets the sum of contract funds that are used for the execution of transactions.
     *  @return Contract balance without reserved ETH.
     */
    function getExpendableFunds() public view returns (uint) {
        return address(this).balance.subCap(reservedETH);
    }

    /** @dev Gets the info of the specified transaction in the specified list.
     *  @param _listID The index of the transaction list in the array of lists.
     *  @param _transactionIndex The index of the transaction.
     *  @return The transaction info.
     */
    function getTransactionInfo(uint _listID, uint _transactionIndex)
        public
        view
        returns (
            address target,
            uint value,
            bytes data,
            bool executed
        )
    {
        Submission storage submission = submissions[_listID];
        Transaction storage transaction = submission.txs[_transactionIndex];
        return (
            transaction.target,
            transaction.value,
            transaction.data,
            transaction.executed
        );
    }

    /** @dev Gets the contributions made by a party for a given round of a session.
     *  Note that this function is O(n), where n is the number of submissions in the session. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @param _session The ID of the session.
     *  @param _round The position of the round.
     *  @param _contributor The address of the contributor.
     *  @return The contributions.
     */
    function getContributions(
        uint _session,
        uint _round,
        address _contributor
    ) public view returns(uint[] contributions) {
        Session storage session = sessions[_session];
        Round storage round = session.rounds[_round];

        contributions = new uint[](session.submittedLists.length);
        for (uint i = 0; i < contributions.length; i++) {
            contributions[i] = round.contributions[_contributor][i];
        }
    }

    /** @dev Gets the information on a round of a session.
     *  Note that this function is O(n), where n is the number of submissions in the session. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @param _session The ID of the session.
     *  @param _round The round to be queried.
     *  @return The round information.
     */
    function getRoundInfo(uint _session, uint _round)
        public
        view
        returns (
            uint[] paidFees,
            bool[] hasPaid,
            uint feeRewards,
            uint successfullyPaid
        )
    {
        Session storage session = sessions[_session];
        Round storage round = session.rounds[_round];
        paidFees = new uint[](session.submittedLists.length);
        hasPaid = new bool[](session.submittedLists.length);

        for (uint i = 0; i < session.submittedLists.length; i++) {
            paidFees[i] = round.paidFees[i];
            hasPaid[i] = round.hasPaid[i];
        }

        feeRewards = round.feeRewards;
        successfullyPaid = round.successfullyPaid;
    }

    /** @dev Gets the array of submitted lists in the session.
     *  Note that this function is O(n), where n is the number of submissions in the session. This could exceed the gas limit, therefore this function should only be used for interface display and not by other contracts.
     *  @param _session The ID of the session.
     *  @return submittedLists Indexes of lists that were submitted during the session.
     */
    function getSubmittedLists(uint _session) public view returns (uint[] submittedLists) {
        Session storage session = sessions[_session];
        submittedLists = session.submittedLists;
    }

    /** @dev Gets the number of transactions in the list.
     *  @param _listID The index of the transaction list in the array of lists.
     *  @return txCount The number of transactions in the list.
     */
    function getNumberOfTransactions(uint _listID) public view returns (uint txCount){
        Submission storage submission = submissions[_listID];
        return submission.txs.length;
    }

    /** @dev Gets the number of lists created in contract's lifetime.
     *  @return The number of created lists.
     */
    function getNumberOfCreatedLists() public view returns (uint){
        return submissions.length;
    }

    /** @dev Gets the number of ongoing session.
     *  @return The number of ongoing session.
     */
    function getCurrentSessionNumber() public view returns (uint){
        return sessions.length - 1;
    }

    /** @dev Gets the number rounds in ongoing session.
     *  @return The number of rounds in session.
     */
    function getSessionRoundsNumber(uint _session) public view returns (uint){
        Session storage session = sessions[_session];
        return session.rounds.length;
    }
}
