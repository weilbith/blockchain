pragma solidity ^0.5.8;

import "../lib/Ownable.sol";
import "./DepositLocker.sol";

contract ValidatorAuction is Ownable {
    // auction constants set on deployment
    uint public auctionDurationInDays;
    uint public startPrice;
    uint public minimalNumberOfParticipants;
    uint public maximalNumberOfParticipants;

    AuctionState public auctionState;
    DepositLocker public depositLocker;
    mapping(address => bool) public whitelist;
    mapping(address => uint) public bids;
    address[] public bidders;
    uint public startTime;
    uint public closeTime;
    uint public lowestSlotPrice;

    event BidSubmitted(
        address bidder,
        uint bidValue,
        uint slotPrice,
        uint timestamp
    );
    event AddressWhitelisted(address whitelistedAddress);
    event AuctionDeployed(
        uint startPrice,
        uint auctionDurationInDays,
        uint minimalNumberOfParticipants,
        uint maximalNumberOfParticipants
    );
    event AuctionStarted(uint startTime);
    event AuctionDepositPending(
        uint closeTime,
        uint lowestSlotPrice,
        uint totalParticipants
    );
    event AuctionEnded(
        uint closeTime,
        uint lowestSlotPrice,
        uint totalParticipants
    );
    event AuctionFailed(uint closeTime, uint numberOfBidders);

    enum AuctionState {
        Deployed,
        Started,
        DepositPending, /* all slots sold, someone needs to call depositBids */
        Ended,
        Failed
    }

    modifier stateIs(AuctionState state) {
        require(
            auctionState == state,
            "Auction is not in the proper state for desired action."
        );
        _;
    }

    constructor(
        uint _startPriceInWei,
        uint _auctionDurationInDays,
        uint _minimalNumberOfParticipants,
        uint _maximalNumberOfParticipants,
        DepositLocker _depositLocker
    ) public {
        require(
            _auctionDurationInDays > 0,
            "Duration of auction must be greater than 0"
        );
        require(
            _auctionDurationInDays < 100 * 365,
            "Duration of auction must be less than 100 years"
        );
        require(
            _minimalNumberOfParticipants > 0,
            "Minimal number of participants must be greater than 0"
        );
        require(
            _maximalNumberOfParticipants > 0,
            "Number of participants must be greater than 0"
        );
        require(
            _minimalNumberOfParticipants <= _maximalNumberOfParticipants,
            "The minimal number of participants must be smaller than the maximal number of participants."
        );
        require(
            // To prevent overflows
            _startPriceInWei < 10 ** 30,
            "The start price is too big."
        );

        startPrice = _startPriceInWei;
        auctionDurationInDays = _auctionDurationInDays;
        maximalNumberOfParticipants = _maximalNumberOfParticipants;
        minimalNumberOfParticipants = _minimalNumberOfParticipants;
        depositLocker = _depositLocker;

        lowestSlotPrice = ~uint(0);

        emit AuctionDeployed(
            startPrice,
            auctionDurationInDays,
            _minimalNumberOfParticipants,
            _maximalNumberOfParticipants
        );
        auctionState = AuctionState.Deployed;
    }

    function() external payable stateIs(AuctionState.Started) {
        bid();
    }

    function bid() public payable stateIs(AuctionState.Started) {
        require(now > startTime, "It is too early to bid.");
        require(
            now <= startTime + auctionDurationInDays * 1 days,
            "Auction has already ended."
        );
        uint slotPrice = currentPrice();
        require(
            msg.value >= slotPrice,
            "Not enough ether was provided for bidding."
        );
        require(whitelist[msg.sender], "The sender is not whitelisted.");
        require(!isSenderContract(), "The sender cannot be a contract.");
        require(
            bidders.length < maximalNumberOfParticipants,
            "The limit of participants has already been reached."
        );
        require(bids[msg.sender] == 0, "The sender has already bid.");

        bids[msg.sender] = msg.value;
        bidders.push(msg.sender);
        if (slotPrice < lowestSlotPrice) {
            lowestSlotPrice = slotPrice;
        }

        depositLocker.registerDepositor(msg.sender);
        emit BidSubmitted(msg.sender, msg.value, slotPrice, now);

        if (bidders.length == maximalNumberOfParticipants) {
            transitionToDepositPending();
        }
    }

    function startAuction() public onlyOwner stateIs(AuctionState.Deployed) {
        require(
            depositLocker.initialized(),
            "The deposit locker contract is not initialized"
        );

        auctionState = AuctionState.Started;
        startTime = now;

        emit AuctionStarted(now);
    }

    function depositBids() public stateIs(AuctionState.DepositPending) {
        auctionState = AuctionState.Ended;
        depositLocker.deposit.value(lowestSlotPrice * bidders.length)(
            lowestSlotPrice
        );
        emit AuctionEnded(closeTime, lowestSlotPrice, bidders.length);
    }

    function closeAuction() public stateIs(AuctionState.Started) {
        require(
            now > startTime + auctionDurationInDays * 1 days,
            "The auction cannot be closed this early."
        );
        assert(bidders.length < maximalNumberOfParticipants);

        if (bidders.length >= minimalNumberOfParticipants) {
            transitionToDepositPending();
        } else {
            transitionToAuctionFailed();
        }
    }

    function addToWhitelist(address[] memory addressesToWhitelist)
        public
        onlyOwner
        stateIs(AuctionState.Deployed)
    {
        for (uint32 i = 0; i < addressesToWhitelist.length; i++) {
            whitelist[addressesToWhitelist[i]] = true;
            emit AddressWhitelisted(addressesToWhitelist[i]);
        }
    }

    function withdraw() public {
        require(
            auctionState == AuctionState.Ended ||
                auctionState == AuctionState.Failed,
            "You cannot withdraw before the auction is ended or it failed."
        );

        if (auctionState == AuctionState.Ended) {
            withdrawAfterAuctionEnded();
        } else if (auctionState == AuctionState.Failed) {
            withdrawAfterAuctionFailed();
        } else {
            assert(false); // Should be unreachable
        }
    }

    function currentPrice()
        public
        view
        stateIs(AuctionState.Started)
        returns (uint)
    {
        assert(now >= startTime);
        uint secondsSinceStart = (now - startTime);
        return priceAtElapsedTime(secondsSinceStart);
    }

    function priceAtElapsedTime(uint secondsSinceStart)
        public
        view
        returns (uint)
    {
        // To prevent overflows
        require(
            secondsSinceStart < 100 * 365 days,
            "Times longer than 100 years are not supported."
        );
        uint msSinceStart = 1000 * secondsSinceStart;
        uint relativeAuctionTime = msSinceStart / auctionDurationInDays;
        uint decayDivisor = 746571428571;
        uint decay = relativeAuctionTime ** 3 / decayDivisor;
        uint price = startPrice *
            (1 + relativeAuctionTime) /
            (1 + relativeAuctionTime + decay);
        return price;
    }

    function withdrawAfterAuctionEnded() internal stateIs(AuctionState.Ended) {
        require(
            bids[msg.sender] > lowestSlotPrice,
            "The sender has nothing to withdraw."
        );

        uint valueToWithdraw = bids[msg.sender] - lowestSlotPrice;
        assert(valueToWithdraw <= bids[msg.sender]);

        bids[msg.sender] = lowestSlotPrice;

        msg.sender.transfer(valueToWithdraw);
    }

    function withdrawAfterAuctionFailed()
        internal
        stateIs(AuctionState.Failed)
    {
        require(bids[msg.sender] > 0, "The sender has nothing to withdraw.");

        uint valueToWithdraw = bids[msg.sender];

        bids[msg.sender] = 0;

        msg.sender.transfer(valueToWithdraw);
    }

    function transitionToDepositPending()
        internal
        stateIs(AuctionState.Started)
    {
        auctionState = AuctionState.DepositPending;
        closeTime = now;
        emit AuctionDepositPending(closeTime, lowestSlotPrice, bidders.length);
    }

    function transitionToAuctionFailed()
        internal
        stateIs(AuctionState.Started)
    {
        auctionState = AuctionState.Failed;
        closeTime = now;
        emit AuctionFailed(closeTime, bidders.length);
    }

    function isSenderContract() internal view returns (bool isContract) {
        uint32 size;
        address sender = msg.sender;
        // solium-disable-next-line security/no-inline-assembly
        assembly {
            size := extcodesize(sender)
        }
        return (size > 0);
    }
}
