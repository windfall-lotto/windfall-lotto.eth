// SPDX-License-Identifier: MIT
// Obligation : The contract owner must be registered as a perpetual shareholder.
pragma solidity ^0.8.24;

/*
  Windfall Lotto - Production-safe (Remix) - Chainlink VRF v2.5

  Key properties:
  - No OpenZeppelin Ownable (avoids OwnershipTransferred conflict with Chainlink owner)
  - ERC721 tickets (transferable)
  - Fixed price: 1 TOKEN per ticket
  - Host fee on buys: 10%
  - Donation: adds to jackpot, no fee
  - Royalty on winnings: 10% to minter if transferred
  - Windfall tier selection: 5 -> else 4 -> else 3 -> else rollover
  - Scalable: permissionless batch processing to count winners (max batch size)
  - Safe payout math: payoutPerWinner locked at finalize; remainder rolls to next draw
*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Chainlink VRF v2.5
import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

import {WindfallTicket} from "./WindfallTicket.sol";
import {WindfallDrawNFT} from "./WindfallDrawNFT.sol";

interface IWindfallFeeShare {
    function registerDonation(address donor, uint256 amount) external;
    function distributeFee(uint256 amount) external;
}

interface ISupraRouterContract {
    // With custom client seed
    function generateRequest(
        string memory _functionSig,
        uint8 _rngCount,
        uint256 _numConfirmations,
        uint256 _clientSeed,
        address _clientWalletAddress
    ) external returns (uint256);

    // Without custom client seed
    function generateRequest(
        string memory _functionSig,
        uint8 _rngCount,
        uint256 _numConfirmations,
        address _clientWalletAddress
    ) external returns (uint256);
}

/**
 * @title WINDFALL-LOTTO
 * @author windfall-lotto.eth
 * @notice this contract is the the core windfall-lotto logic.
 */
contract WindfallLotto is VRFConsumerBaseV2Plus, IERC721Receiver, ReentrancyGuard {

    using SafeERC20 for IERC20;

    // ===== Errors =====
    error ZeroToken();
    error ZeroTreasury();
    error ZeroTicket();
    error ZeroDrawNFT();
    error ZeroFeeShare();
    error SmallDuration();
    error BadDrawState();
    error CloseTooEarly();
    error DrawNotOpen();
    error DrawEnded();
    error DonationAmountZero();
    error ReqNotWaiting();
    error ReqMismatch();
    error ReqUknown();
    error NoCount();
	error AlrMinted();
    error NotRevealed();
	error NoTickets();
	error AllProcessed();
    error NotFullProcessed();
    error AlrClaimed();
	error NotOwner();
	error NotReady();
	error NoActiveTier();
	error NoWinners();
	error ZeroPayout();
	error NoWinningTier();
	error OverPay();
	error NotAutorize();
	error TooLow();
	error TooHigh();
	error BadConfirmation();
    error InvalidTicketCount();
    error ZeroSupraRouter();
    error ZeroSupraWallet();
    error BadSupraRngCount();
    error BadSupraNonce();
    error NumSup99();

    // ===== Token / Pricing =====
    IERC20 public immutable TOKEN; //Use Stable USD Coin or change USD symbol for NFT in WindfallDrawNFT before deploy
    WindfallTicket public immutable WINDFALL_TICKET;

    uint256 public constant DRAW_NFTS_PER_DRAW = 2;
    uint256 public constant MAX_TICKETS_PER_BUY = 50;

    WindfallDrawNFT public immutable WINDFALL_DRAWNFT;
    IWindfallFeeShare public immutable WINDFALL_FEESHARE;

    mapping(uint32 => uint256) public drawIdToHostNftId;
    mapping(uint32 => uint256) public drawIdToContractNftId;
    mapping(uint32 => bool) public drawNftsMinted;

    uint256 public constant TICKET_PRICE = 1e18; // 1 TOKEN (18 decimals)
    uint16  public constant BPS = 10000;
    uint16 public constant TIER5_SHARE_BPS = 8000;  // 80% 
    uint16 public constant TIER4_SHARE_BPS = 2000;  // 20%
    uint16 public constant TIER3_SHARE_BPS = 500;   // 05%
    uint256 public constant WINDFALL_TRIGGER = 1e27; // 1B TOKEN (18 decimals) All Tiers become Tier5 (80%) winners
    uint16  public constant HOST_FEE_BPS = 1000;       // 10% on ticket buy
    uint16  public constant MINTER_ROYALTY_BPS = 1000; // 10% of winnings if transferred

    // ===== Supra dVRF config =====
    ISupraRouterContract public immutable SUPRA_ROUTER;
    address public immutable SUPRA_CLIENT_WALLET;
    uint8   public constant SUPRA_RNG_COUNT = 1;
    uint256 public supraConfirmations;

    // ===== Fallback timings =====
    uint64 public constant CHAINLINK_TIMEOUT = 1 hours;
    uint64 public constant SUPRA_TIMEOUT = 2 hours;
    uint64 public constant BLOCKHASH_DELAY = 7; // blocks after activation
    uint256 public blockConfirmations;

    address public immutable hostTreasury;

    // ===== VRF config (fixed for decentralization) =====
    uint256 public immutable VRF_SUB_ID;
    bytes32 public immutable VRF_KEY_HASH;
    uint32  public vrfCallbackGasLimit;
    uint16  public vrfRequestConfirmations;

    // requestId/nonce -> drawId
    mapping(uint256 => uint32) public chainlinkRequestToDrawId;
    mapping(uint256 => uint32) public supraNonceToDrawId;

    // ===== Anti-gas-grief for counting =====
    uint256 public constant MAX_PROCESS_BATCH = 500;

    enum DrawState { OPEN, CHAINLINK_REQUESTED, SUPRA_REQUESTED, BLOCKHASH_PENDING, REVEALED, COUNTING_DONE }
    enum RandomSource { NONE, CHAINLINK, SUPRA, BLOCKHASH }

    struct Draw {
        uint64 endTime;
        uint128 jackpot;         // accounting jackpot for this draw (in TOKEN units)
        uint128 hostfee;         // accumulate hostfee for one distribution in draw opening
        bool hostfeeSent;
        DrawState state;

        // Random result
        uint8[5] winning;
        uint256 chainlinkRequestId;
        uint256 supraNonce;
        uint64 revealedAt;

        RandomSource randomSource;
        // Fallback timing
        uint64 randomRequestedAt;
        uint64 fallbackBlockNumber; // only used for final blockhash fallback

        // Tickets id range for draw
        uint256 firstTicketId;
        uint256 lastTicketId;

        // Batch processing cursor
        uint256 processedUpTo;

        // Winner counts by tier
        uint32 tier5;
        uint32 tier4;
        uint32 tier3;

        // Finalized tier and payout
        uint8  activeTier;       // 5,4,3 or 0 if rollover
        uint32 activeWinners;    // number of winners in activeTierdraws

        uint256 payoutPerWinner; // locked at finalize
        uint256 remainder;       // jackpot - payoutPerWinner*activeWinners
        uint32  paidWinners;     // count of paid winning tickets
    }

    uint32 public currentDrawId = 1;
    mapping(uint32 => Draw) public draws;
    mapping(uint256 => bool) public claimed;

    // ===== Events =====
    event TicketBought(uint32 indexed drawId, uint256 indexed ticketId, address indexed buyer, uint8[5] numbers);
    event TicketsBought(address indexed buyer, uint32 indexed drawId, uint256 count, uint256 totalPrice);
    event JackpotDonated(uint32 indexed drawId, address indexed donor, uint256 amount);
    event DrawVRFRequested(uint32 indexed drawId, uint256 requestId);
    event DrawSupraRequested(uint32 indexed drawId, uint256 nonce);
    event DrawBlockhashArmed(uint32 indexed drawId, uint64 targetBlock);
    event RandomnessUsed(uint32 indexed drawId, uint8 indexed source, uint256 randomWord);
    event DrawRevealed(uint32 indexed drawId, uint8[5] winning);
    event TicketsProcessed(uint32 indexed drawId, uint256 fromId, uint256 toId);
    event TierFinalized(uint32 indexed drawId, uint8 activeTier, uint32 winners, uint256 payoutPerWinner, uint256 remainder);
    event Claimed(uint256 indexed ticketId, address indexed claimer, address indexed minter, uint256 claimerAmt, uint256 minterAmt);
    event NextDrawOpened(uint32 indexed drawId, uint64 endTime, uint128 startingJackpot);
    event DrawNFTMinted(uint32 indexed drawId, uint256 hostTokenId, uint256 contractTokenId);

    constructor(
        address theToken,
        address vrfCoordinator,
        uint256 subId,
        bytes32 keyHash,
        address _hostTreasury,
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        address supraRouterAddress,
        address supraWalletAddress,
        uint256 supraNumConfirmations,
        uint256 blockNumConfirmations,
        address ticketAddress,
        address drawNFTAddress,
        address feeShareAddress
    )
        VRFConsumerBaseV2Plus(vrfCoordinator)
    {
        
        if (theToken == address(0)) revert ZeroToken();
        if (_hostTreasury == address(0)) revert ZeroTreasury();
        if (ticketAddress == address(0)) revert ZeroTicket();
        if (drawNFTAddress == address(0)) revert ZeroDrawNFT();
        if (feeShareAddress == address(0)) revert ZeroFeeShare();
        if (supraRouterAddress == address(0)) revert ZeroSupraRouter();
        if (supraWalletAddress == address(0)) revert ZeroSupraWallet();
        if (requestConfirmations < 12) revert BadConfirmation();
        if (requestConfirmations > 200) revert BadConfirmation();
        if (supraNumConfirmations < 12) revert BadConfirmation();
        if (supraNumConfirmations > 20) revert BadConfirmation();
        if (blockNumConfirmations < 12) revert BadConfirmation();
        if (blockNumConfirmations > 50) revert BadConfirmation();

        TOKEN = IERC20(theToken);
        hostTreasury = _hostTreasury;

        VRF_SUB_ID = subId;
        VRF_KEY_HASH = keyHash;
        vrfCallbackGasLimit = callbackGasLimit;
        vrfRequestConfirmations = requestConfirmations;

        SUPRA_ROUTER = ISupraRouterContract(supraRouterAddress);
        SUPRA_CLIENT_WALLET = supraWalletAddress;
        supraConfirmations = supraNumConfirmations;

        blockConfirmations = blockNumConfirmations;

        WINDFALL_TICKET = WindfallTicket(ticketAddress);
        WINDFALL_DRAWNFT = WindfallDrawNFT(drawNFTAddress);
        WINDFALL_FEESHARE = IWindfallFeeShare(feeShareAddress);


        _openNewDraw(0);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ===== Buy ticket (1 TOKEN) =====
    function buyTicket(uint8[5] calldata nums) external nonReentrant {
        Draw storage d = draws[currentDrawId];

        if (d.state != DrawState.OPEN) revert DrawNotOpen();
        if (block.timestamp >= d.endTime) revert DrawEnded();

        uint8[5] memory n = nums;
        _validateNums(n);

        TOKEN.safeTransferFrom(msg.sender, address(this), TICKET_PRICE);

        uint256 hostFee = (TICKET_PRICE * HOST_FEE_BPS) / BPS; // 0.1
        uint256 toJackpot = TICKET_PRICE - hostFee;            // 0.9

        d.hostfee += uint128(hostFee);
        d.jackpot += uint128(toJackpot);

        bytes32 packed = _pack(n);
        uint256 id = WINDFALL_TICKET.mint(msg.sender, currentDrawId, d.endTime, msg.sender, packed);

        if (d.firstTicketId == 0) d.firstTicketId = id;
        d.lastTicketId = id;

        emit TicketBought(currentDrawId, id, msg.sender, n);
    }

    function buyTickets(uint8[5][] calldata numsList) external nonReentrant {
        Draw storage d = draws[currentDrawId];

        if (d.state != DrawState.OPEN) revert DrawNotOpen();
        if (block.timestamp >= d.endTime) revert DrawEnded();

        uint256 count = numsList.length;
        if (count == 0 || count > MAX_TICKETS_PER_BUY) revert InvalidTicketCount();

        uint256 totalPrice = TICKET_PRICE * count;
        uint256 hostFee = (totalPrice * HOST_FEE_BPS) / BPS;
        uint256 toJackpot = totalPrice - hostFee;

        TOKEN.safeTransferFrom(msg.sender, address(this), totalPrice);

        d.hostfee += uint128(hostFee);
        d.jackpot += uint128(toJackpot);

        uint256 id;
        for (uint256 i = 0; i < count; ) {
            uint8[5] memory n = numsList[i];
            _validateNums(n);

            bytes32 packed = _pack(n);
            id = WINDFALL_TICKET.mint(msg.sender, currentDrawId, d.endTime, msg.sender, packed);

            if (d.firstTicketId == 0) d.firstTicketId = id;
            d.lastTicketId = id;

            emit TicketBought(currentDrawId, id, msg.sender, n);

            unchecked {
                ++i;
            }
        }

        emit TicketsBought(msg.sender, currentDrawId, count, totalPrice);
    }

    // ===== Donation (no ticket, no host fee) =====
    function donateToJackpot(uint256 amount) external {
        if (amount == 0) revert DonationAmountZero();
        Draw storage d = draws[currentDrawId];

        if (d.state != DrawState.OPEN) revert DrawNotOpen();
        if (block.timestamp >= d.endTime) revert DrawEnded();

        TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        d.jackpot += uint128(amount);

        WINDFALL_FEESHARE.registerDonation(msg.sender, amount);

        emit JackpotDonated(currentDrawId, msg.sender, amount);
    }

    // ===== Close draw & request random (permissionless) =====
    // OPEN -> Chainlink
    // timeout -> Supra
    // timeout -> blockhash
    // blockhash ready -> reveal
    function closeDrawAndRequestRandom() external {
        Draw storage d = draws[currentDrawId];

        if (block.timestamp < d.endTime) revert CloseTooEarly();

        // No tickets => rollover (no random needed)
        if (d.firstTicketId == 0) {
            if (d.state != DrawState.OPEN) revert BadDrawState();

            d.activeTier = 0;
            d.activeWinners = 0;
            d.payoutPerWinner = 0;
            d.remainder = d.jackpot;
            d.state = DrawState.COUNTING_DONE;

            emit TierFinalized(currentDrawId, 0, 0, 0, d.remainder);
            return;
        }

        if (d.state == DrawState.OPEN) {
            _requestChainlinkRandom(currentDrawId);
            return;
        }

        if (d.state == DrawState.CHAINLINK_REQUESTED) {
            if (block.timestamp < d.randomRequestedAt + CHAINLINK_TIMEOUT) revert BadDrawState();
            _requestSupraRandom(currentDrawId);
            return;
        }

        if (d.state == DrawState.SUPRA_REQUESTED) {
            if (block.timestamp < d.randomRequestedAt + SUPRA_TIMEOUT) revert BadDrawState();
            _armBlockhashFallback(currentDrawId);
            return;
        }

        if (d.state == DrawState.BLOCKHASH_PENDING) {
            if (block.number <= d.fallbackBlockNumber + blockConfirmations) revert NotReady();

            bytes32 bh = blockhash(d.fallbackBlockNumber);
            //if (bh == bytes32(0)) revert NotReady();
            if (bh == bytes32(0)) {
                _requestChainlinkRandom(currentDrawId);
                return;
            }

            uint256 r = uint256(
                keccak256(
                    abi.encodePacked(
                        bh,
                        currentDrawId,
                        d.jackpot,
                        d.firstTicketId,
                        d.lastTicketId
                    )
                )
            );

            _revealDraw(currentDrawId, r);
            return;
        }

        revert BadDrawState();
    }

    function _requestChainlinkRandom(uint32 drawId) internal {
        Draw storage d = draws[drawId];

        d.state = DrawState.CHAINLINK_REQUESTED;
        d.randomSource = RandomSource.CHAINLINK;
        d.randomRequestedAt = uint64(block.timestamp);

        VRFV2PlusClient.RandomWordsRequest memory req = VRFV2PlusClient.RandomWordsRequest({
            keyHash: VRF_KEY_HASH,
            subId: VRF_SUB_ID,
            requestConfirmations: vrfRequestConfirmations,
            callbackGasLimit: vrfCallbackGasLimit,
            numWords: 1,
            extraArgs: VRFV2PlusClient._argsToBytes(
                VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
            )
        });

        uint256 requestId = s_vrfCoordinator.requestRandomWords(req);

        d.chainlinkRequestId = requestId;
        chainlinkRequestToDrawId[requestId] = drawId;

        emit DrawVRFRequested(drawId, requestId);
    }

    function _requestSupraRandom(uint32 drawId) internal {
        Draw storage d = draws[drawId];

        if (SUPRA_RNG_COUNT == 0) revert BadSupraRngCount();

        d.state = DrawState.SUPRA_REQUESTED;
        d.randomSource = RandomSource.SUPRA;
        d.randomRequestedAt = uint64(block.timestamp);

        // custom seed adds extra entropy/context but callback still receives Supra RNG
        uint256 clientSeed = uint256(
            keccak256(
                abi.encodePacked(
                    block.prevrandao,
                    block.timestamp,
                    drawId,
                    d.jackpot,
                    d.firstTicketId,
                    d.lastTicketId
                )
            )
        );

        uint256 nonce = SUPRA_ROUTER.generateRequest(
            "supraCallback(uint256,uint256[])",
            SUPRA_RNG_COUNT,
            supraConfirmations,
            clientSeed,
            SUPRA_CLIENT_WALLET
        );

        d.supraNonce = nonce;
        supraNonceToDrawId[nonce] = drawId;

        emit DrawSupraRequested(drawId, nonce);
    }

    function _armBlockhashFallback(uint32 drawId) internal {
        Draw storage d = draws[drawId];

        d.state = DrawState.BLOCKHASH_PENDING;
        d.randomSource = RandomSource.BLOCKHASH;
        d.randomRequestedAt = uint64(block.timestamp);
        d.fallbackBlockNumber = uint64(block.number + BLOCKHASH_DELAY);

        emit DrawBlockhashArmed(drawId, d.fallbackBlockNumber);
    }

    function _revealDraw(uint32 drawId, uint256 r) internal {
        Draw storage d = draws[drawId];

        d.winning = _derive5(r);

        // debug only
        //d.winning[0] = 11;
        //d.winning[1] = 0;
        //d.winning[2] = 77;
        //d.winning[3] = 77;
        //d.winning[4] = 0;

        d.state = DrawState.REVEALED;
        d.revealedAt = uint64(block.timestamp);
        d.processedUpTo = d.firstTicketId - 1;
        
        emit RandomnessUsed(drawId, uint8(d.randomSource), r);
        emit DrawRevealed(drawId, d.winning);
    }
    
    // ===== Chainlink VRF callback =====
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint32 drawId = chainlinkRequestToDrawId[requestId];
        if (drawId == 0) revert ReqUknown();

        Draw storage d = draws[drawId];
        if (d.state != DrawState.CHAINLINK_REQUESTED) revert ReqNotWaiting();
        if (d.chainlinkRequestId != requestId) revert ReqMismatch();

        _revealDraw(drawId, randomWords[0]);
    }

    // ===== Supra dVRF callback =====
    // Signature must match the string used in generateRequest(...)
    function supraCallback(uint256 nonce, uint256[] calldata rngList) external {
        if (msg.sender != address(SUPRA_ROUTER)) revert NotAutorize();
        if (rngList.length == 0) revert BadSupraRngCount();

        uint32 drawId = supraNonceToDrawId[nonce];
        if (drawId == 0) revert BadSupraNonce();

        Draw storage d = draws[drawId];
        if (d.state != DrawState.SUPRA_REQUESTED) revert ReqNotWaiting();
        if (d.supraNonce != nonce) revert ReqMismatch();

        _revealDraw(drawId, rngList[0]);
    }

    function mintDrawNfts(uint32 drawId) external nonReentrant {
        _mintDrawNfts(drawId);
    }

    function _mintDrawNfts(uint32 drawId) internal {
        Draw storage d = draws[drawId];
        if (d.state != DrawState.COUNTING_DONE) revert NoCount();
        if (drawNftsMinted[drawId]) revert AlrMinted();
        
        // No tickets => no Mint
        if (d.firstTicketId == 0) return;

        bytes32 packedWinning = _pack(d.winning);

        drawNftsMinted[drawId] = true;

        uint256 hostNftId = WINDFALL_DRAWNFT.mintDraw(
            hostTreasury,
            drawId,
            d.revealedAt,
            d.jackpot,
            packedWinning,
            d.activeTier,
            d.activeWinners
        );

        uint256 contractNftId = WINDFALL_DRAWNFT.mintDraw(
            address(this),
            drawId,
            d.revealedAt,
            d.jackpot,
            packedWinning,
            d.activeTier,
            d.activeWinners
        );

        drawIdToHostNftId[drawId] = hostNftId;
        drawIdToContractNftId[drawId] = contractNftId;

        emit DrawNFTMinted(drawId, hostNftId, contractNftId);
    }

    // ===== Batch counting (permissionless, capped) =====
    function processTickets(uint32 drawId) external {
        Draw storage d = draws[drawId];
        if (d.state != DrawState.REVEALED) revert NotRevealed();
        if (d.firstTicketId == 0) revert NoTickets();
        if (d.processedUpTo >= d.lastTicketId) revert AllProcessed();

        uint256 fromTicketId = d.processedUpTo + 1;
        if (fromTicketId < d.firstTicketId) {
            fromTicketId = d.firstTicketId;
        }

        uint256 toTicketId = fromTicketId + MAX_PROCESS_BATCH - 1;
        if (toTicketId > d.lastTicketId) {
            toTicketId = d.lastTicketId;
        }

        for (uint256 id = fromTicketId; id <= toTicketId; id++) {
            (uint32 tDrawId, , , bytes32 packed) = WINDFALL_TICKET.ticketData(id);
            if (tDrawId != drawId) continue;

            uint8 tier = _matchTier(_unpack(packed), d.winning);

            if (tier == 5) {
                d.tier5++;
                WINDFALL_TICKET.setTicketTier(id, 5);
            } else if (tier == 4) {
                d.tier4++;
                WINDFALL_TICKET.setTicketTier(id, 4);
            } else if (tier == 3) {
                d.tier3++;
                WINDFALL_TICKET.setTicketTier(id, 3);
            }
        }

        d.processedUpTo = toTicketId;
        emit TicketsProcessed(drawId, fromTicketId, toTicketId);
    }

    function getProcessRange(uint32 drawId) external view returns (
        uint256 fromTicketId,
        uint256 toTicketId,
        bool done
    ) {
        Draw storage d = draws[drawId];

        if (d.firstTicketId == 0 || d.processedUpTo >= d.lastTicketId) {
            return (0, 0, true);
        }

        fromTicketId = d.processedUpTo + 1;
        if (fromTicketId < d.firstTicketId) {
            fromTicketId = d.firstTicketId;
        }

        toTicketId = fromTicketId + MAX_PROCESS_BATCH - 1;
        if (toTicketId > d.lastTicketId) {
            toTicketId = d.lastTicketId;
        }

        done = false;
    }

    // ===== Finalize tier (permissionless) =====
    function finalizeTier(uint32 drawId) external {
        Draw storage d = draws[drawId];
        if (d.state != DrawState.REVEALED) revert NotRevealed();
        if (d.processedUpTo != d.lastTicketId) revert NotFullProcessed();

        if (d.tier5 > 0) {
            d.activeTier = 5;
            d.activeWinners = d.tier5;
        } else if (d.tier4 > 0) {
            d.activeTier = 4;
            d.activeWinners = d.tier4;
        } else if (d.tier3 > 0) {
            d.activeTier = 3;
            d.activeWinners = d.tier3;
        } else {
            d.activeTier = 0;
            d.activeWinners = 0;
        }

        if (d.activeTier == 0) {
            // no winners => full rollover
            d.payoutPerWinner = 0;
            d.remainder = d.jackpot;
        } else {
            uint256 distributable;

            if (d.jackpot < WINDFALL_TRIGGER){
                if (d.activeTier == 5) distributable = (uint256(d.jackpot) * TIER5_SHARE_BPS) / BPS;
                else if (d.activeTier == 4) distributable = (uint256(d.jackpot) * TIER4_SHARE_BPS) / BPS;
                else distributable = (uint256(d.jackpot) * TIER3_SHARE_BPS) / BPS;
            } else distributable = (uint256(d.jackpot) * TIER5_SHARE_BPS) / BPS; // The winning Tier become a Tier5 winner

            d.payoutPerWinner = distributable / uint256(d.activeWinners);
            uint256 used = d.payoutPerWinner * uint256(d.activeWinners);

            // undistributed dust + non-shared part rolls over
            d.remainder = uint256(d.jackpot) - used;
        }

        d.state = DrawState.COUNTING_DONE;

        emit TierFinalized(
            drawId,
            d.activeTier,
            d.activeWinners,
            d.payoutPerWinner,
            d.remainder
        );
    }

    // ===== Claim =====
    function claim(uint256 ticketId) external nonReentrant {
        if (claimed[ticketId]) revert AlrClaimed();
        if (WINDFALL_TICKET.ownerOf(ticketId) != msg.sender) revert NotOwner();

        (uint32 drawId, , address minter, bytes32 packed) = WINDFALL_TICKET.ticketData(ticketId);
        Draw storage d = draws[drawId];

        if (d.state != DrawState.COUNTING_DONE) revert NotReady();
        if (d.activeTier == 0) revert NoActiveTier();
        if (d.activeWinners <= 0) revert NoWinners();
        if (d.payoutPerWinner <= 0) revert ZeroPayout();

        uint8 tier = _matchTier(_unpack(packed), d.winning);
        if (tier != d.activeTier) revert NoWinningTier();

        claimed[ticketId] = true;
        d.paidWinners += 1;
        if (d.paidWinners > d.activeWinners) revert OverPay();

        uint256 gross = d.payoutPerWinner;

        address claimer = msg.sender;
        uint256 minterAmt = 0;
        uint256 claimerAmt = gross;

        if (claimer != minter) {
            minterAmt = (gross * MINTER_ROYALTY_BPS) / BPS;
            claimerAmt = gross - minterAmt;
            TOKEN.safeTransfer(minter, minterAmt);
        }

        TOKEN.safeTransfer(claimer, claimerAmt);
        emit Claimed(ticketId, claimer, minter, claimerAmt, minterAmt);
    }

    function distributeHostFee(uint32 drawId) external nonReentrant {
        Draw storage d = draws[drawId];
        if (d.state != DrawState.COUNTING_DONE) revert NoCount();
        // distibution of cumulated hostfees
        _distributeHostFee(drawId);
    }

    function _distributeHostFee(uint32 drawId) internal {
        Draw storage d = draws[drawId];
        // distibution of cumulated hostfees
        if (!d.hostfeeSent){
            d.hostfeeSent = true;
            if (d.hostfee == 0) return;
            TOKEN.safeTransfer(address(WINDFALL_FEESHARE), d.hostfee);
            WINDFALL_FEESHARE.distributeFee(d.hostfee);
        }
    }

    // ===== Open next draw (permissionless) =====
    function openNextDraw() external nonReentrant {
        Draw storage d = draws[currentDrawId];
        if (d.state != DrawState.COUNTING_DONE) revert NoCount();
        // carry remainder always; if no winners, remainder==jackpot
        uint128 carry = uint128(d.remainder);
        if (!drawNftsMinted[currentDrawId]) _mintDrawNfts(currentDrawId);
        _distributeHostFee(currentDrawId);

        currentDrawId++;
        _openNewDraw(carry);
    }

    // ===== Open next draw (permissionless) Light version for emergency =====
    function openNextDrawLight() external nonReentrant {
        Draw storage d = draws[currentDrawId];
        if (d.state != DrawState.COUNTING_DONE) revert NoCount();
        // carry remainder always; if no winners, remainder==jackpot
        uint128 carry = uint128(d.remainder);
        // No Ticket Mnting
        // No fee Distribution

        currentDrawId++;
        _openNewDraw(carry);
    }

    function _openNewDraw(uint128 startingJackpot) internal {
        Draw storage nd = draws[currentDrawId];
        nd.endTime = _getNextFriday23UTC();
        nd.jackpot = startingJackpot;
        nd.state = DrawState.OPEN;
        nd.hostfee = 0;
        nd.hostfeeSent = false;

        emit NextDrawOpened(currentDrawId, nd.endTime, startingJackpot);
    }

    // ===== Helpers =====
    function _validateNums(uint8[5] memory nums) internal pure {
        for (uint256 i = 0; i < 5; i++) if (nums[i] > 99) revert NumSup99();
        // duplicates allowed => no uniqueness checks
    }

    function _pack(uint8[5] memory nums) internal pure returns (bytes32 out) {
        out = bytes32(
            uint256(nums[0]) |
            (uint256(nums[1]) << 8) |
            (uint256(nums[2]) << 16) |
            (uint256(nums[3]) << 24) |
            (uint256(nums[4]) << 32)
        );
    }

    function _unpack(bytes32 packed) internal pure returns (uint8[5] memory nums) {
        uint256 x = uint256(packed);
        nums[0] = uint8(x);
        nums[1] = uint8(x >> 8);
        nums[2] = uint8(x >> 16);
        nums[3] = uint8(x >> 24);
        nums[4] = uint8(x >> 32);
    }

    function _derive5(uint256 r) internal pure returns (uint8[5] memory w) {
        w[0] = uint8(r % 100);
        w[1] = uint8(uint256(keccak256(abi.encode(r, 1))) % 100);
        w[2] = uint8(uint256(keccak256(abi.encode(r, 2))) % 100);
        w[3] = uint8(uint256(keccak256(abi.encode(r, 3))) % 100);
        w[4] = uint8(uint256(keccak256(abi.encode(r, 4))) % 100);
    }

    // order-sensitive,consecutive, correct places, duplicates allowed
    function _matchTier(uint8[5] memory a, uint8[5] memory w) internal pure returns (uint8) {
        uint8 maxStreak = 0;
        uint8 currentStreak = 0;

        for (uint8 i = 0; i < 5; i++) {
            if (a[i] == w[i]) {
                currentStreak++;
                if (currentStreak > maxStreak) {
                    maxStreak = currentStreak;
                }
            } else {
                currentStreak = 0; // reset streak if mismatch
            }
        }

        if (maxStreak >= 3) return maxStreak; // longest consecutive streak of matches
        return 0;
    }


    function setVRFCallbackGasLimit(uint32 newLimit) external {
        if (msg.sender != hostTreasury) revert NotAutorize();
        if (newLimit < 100000) revert TooLow();
        if (newLimit > 2500000) revert TooHigh();

        vrfCallbackGasLimit = newLimit;
    }

    function setVRFRequestConfirmations(uint16 newConf) external {
        if (msg.sender != hostTreasury) revert NotAutorize();
        if (newConf < 12 || newConf > 200) revert BadConfirmation();
        vrfRequestConfirmations = newConf;
    }

    function setSupraConfirmations(uint256 supraNumConfirmations) external {
        if (msg.sender != hostTreasury) revert NotAutorize();
        if (supraNumConfirmations < 12) revert BadConfirmation();
        if (supraNumConfirmations > 20) revert BadConfirmation();
        supraConfirmations = supraNumConfirmations;
    }

    function setBlockConfirmations(uint256 blockNumConfirmations) external {
        if (msg.sender != hostTreasury) revert NotAutorize();
        if (blockNumConfirmations < 12) revert BadConfirmation();
        if (blockNumConfirmations > 50) revert BadConfirmation();
        blockConfirmations = blockNumConfirmations;
    }

    function getComputedTicketTier(uint256 ticketId) public view returns (uint8) {
        (uint32 drawId, , , bytes32 packed) = WINDFALL_TICKET.ticketData(ticketId);
        Draw storage d = draws[drawId];

        if (d.state != DrawState.REVEALED && d.state != DrawState.COUNTING_DONE) {
            return 0;
        }

        return _matchTier(_unpack(packed), d.winning);
    }

    // ===== Next date to open a draw (Every Friday 23H UTC) =====
    function _getNextFriday23UTC() internal view returns (uint64) {
        // Current block timestamp (UTC)
        uint64 current = uint64(block.timestamp);

        // Seconds in a day
        uint64 day = 1 days;

        // Day of week
        uint64 dayOfWeek = (current / day + 4) % 7;

        // Seconds since start of current day
        uint64 secondsToday = current % day;

        // Target time = Friday (5) at 23h (23*3600 seconds)
        uint64 targetDay = 5;
        uint64 targetSeconds = 23 * 3600;

        uint64 daysUntilTarget;
        if (dayOfWeek < targetDay || (dayOfWeek == targetDay && secondsToday < targetSeconds)) {
            // This week's Friday still ahead
            daysUntilTarget = targetDay - dayOfWeek;
        } else {
            // Next week's Friday
            daysUntilTarget = 7 - dayOfWeek + targetDay;
        }

        uint64 nextFridayday = (current - secondsToday) + daysUntilTarget * day + targetSeconds;
        return nextFridayday;
    }

    // ===== For test only every 1h =====
    /*
    function _getNextHourUTC() internal view returns (uint64) {
        uint64 current = uint64(block.timestamp);

        // Seconds in an hour
        uint64 hour = 1 hours;

        // Seconds since start of current hour
        uint64 secondsThisHour = current % hour;

        uint64 nextHour;
        if (secondsThisHour == 0) {
            // Exactly at the start of an hour → return current + 1h
            nextHour = current + hour;
        } else {
            // Otherwise → round up to the next hour
            nextHour = current - secondsThisHour + hour;
        }

        return nextHour;
    }
    */
}