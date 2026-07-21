// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {WindfallSVG} from "./WindfallSVG.sol";

interface IWindfallLotto {
    function getComputedTicketTier(uint256 ticketId) external view returns (uint8);
}

interface IERC4906 {
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
}

/**
 * On-chain SVG Ticket NFT
 * - minted only by Lotto contract (WINDFALL_LOTTO = deployer)
 * - stores drawId + minter + packed nums
 * - tokenURI() returns base64 JSON with base64 SVG image
 */
contract WindfallTicket is ERC721Enumerable, IERC4906 {
    // ===== Errors =====
    error ZeroAddress();
    error LottoAlreadySet();
    error NotHost();
    error NotLotto();
    error BadTier();
    error NonExistent();

    using Strings for uint256;

    address public WINDFALL_LOTTO; // only WINDFALL_LOTTO can mint
    address public immutable hostTreasury;
    uint256 public nextId = 1;

    struct TicketData {
        uint32  drawId;
        uint64  drawEnd;      // NEW: draw end timestamp
        address minter;      // first buyer forever
        bytes32 packedNums;  // packed 5 uint8 numbers in 5 bytes
    }

    mapping(uint256 => TicketData) public ticketData;
    mapping(uint256 => uint8) public ticketTier;

    modifier onlyLotto() {
        if (msg.sender != WINDFALL_LOTTO) revert NotLotto();
        _;
    }

    modifier onlyHost() {
        if (msg.sender != hostTreasury) revert NotHost();
        _;
    }

    constructor(
        address _hostTreasury
    ) ERC721("Windfall Lotto Ticket", "WLT") {
        if (_hostTreasury == address(0)) revert ZeroAddress();
        hostTreasury = _hostTreasury;
    }

    function setLotto(address _lotto) external onlyHost {
        // no require for test
        if (WINDFALL_LOTTO != address(0)) revert LottoAlreadySet();
        if (_lotto == address(0)) revert ZeroAddress();
        WINDFALL_LOTTO = _lotto;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Enumerable)
        returns (bool)
    {
        // ERC-4906 interface id
        return interfaceId == 0x49064906 || super.supportsInterface(interfaceId);
    }

    // ---------- Only the lotto contract can call this ----------
    event TicketTierSet(uint256 indexed tokenId, uint8 tier);
    function setTicketTier(uint256 tokenId, uint8 tier) external onlyLotto {
        //require(tier == 0 || tier == 3 || tier == 4 || tier == 5, "bad tier");
        if (tier != 0 && tier != 3 && tier != 4 && tier != 5) revert BadTier();
        ticketTier[tokenId] = tier;
        emit TicketTierSet(tokenId, tier);
        emit MetadataUpdate(tokenId); // important
    }

    //Mint the Ticket
    function mint(
        address to,
        uint32 drawId,
        uint64 drawEnd,   // NEW
        address minter,
        bytes32 packedNums
    ) external onlyLotto returns (uint256 id) {
        id = nextId++;
        _safeMint(to, id);
        ticketData[id] = TicketData(drawId, drawEnd, minter, packedNums);
    }

    // ---------- On-chain metadata + SVG ----------
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        //require(_ownerOf(tokenId) != address(0), "nonexistent");
        if (_ownerOf(tokenId) == address(0)) revert NonExistent();

        TicketData memory t = ticketData[tokenId];
        uint8[5] memory n = _unpack(t.packedNums);

        uint8 tier = ticketTier[tokenId];
            if (tier == 0 && WINDFALL_LOTTO != address(0)) {
                tier = IWindfallLotto(WINDFALL_LOTTO).getComputedTicketTier(tokenId);
        }

        string memory svg = _buildSVG(tokenId, t.drawId, t.drawEnd, n, t.minter, tier);
        string memory image = string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(svg))
        );

        // attributes
        string memory attrs = string.concat(
            '[{"trait_type":"Draw","value":"', _u32ToString(t.drawId),
            '"},{"trait_type":"Ends","value":"', _dateTimeString(t.drawEnd),
            '"},{"trait_type":"Numbers","value":"', _numsString(n),
            '"},{"trait_type":"N1","value":', uint256(n[0]).toString(),
            '},{"trait_type":"N2","value":', uint256(n[1]).toString(),
            '},{"trait_type":"N3","value":', uint256(n[2]).toString(),
            '},{"trait_type":"N4","value":', uint256(n[3]).toString(),
            '},{"trait_type":"N5","value":', uint256(n[4]).toString(),
            '},{"trait_type":"Minter","value":"', _addrShort(t.minter),
            '"}]'
        );

        string memory json = string.concat(
            '{"name":"Windfall Ticket #', tokenId.toString(),
            '","description":"web : windfall-lotto.eth",',
            '"tier":', uint256(tier).toString(), ',',
            '"image":"', image, '",',
            '"attributes":', attrs,
            "}"
        );

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(json))
        );
    }

    function _buildSVG(
    uint256 tokenId,
    uint32 drawId,
    uint64 drawEnd,
    uint8[5] memory n,
    address minter, 
    uint8 tier
) internal pure returns (string memory) {
    //uint8 tier = ticketTier[tokenId];

    string memory bgColor;

    if (tier == 5) bgColor = "url(#bggold)";      // gold
    else if (tier == 4) bgColor = "url(#bgsilver)"; // silver
    else if (tier == 3) bgColor = "url(#bgbronze)"; // bronze
    else bgColor = "url(#bg)";               // default / losing
    return string.concat(
        '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="600" viewBox="0 0 600 600" preserveAspectRatio="xMidYMid meet">',
        '<defs>',
          // Background gradients
          '<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">',
            '<stop offset="0%" stop-color="#070A18"/>',
            '<stop offset="55%" stop-color="#0D1330"/>',
            '<stop offset="100%" stop-color="#140A2B"/>',
          '</linearGradient>',

          '<linearGradient id="bggold" x1="0" y1="0" x2="1" y2="1">',
            '<stop offset="0%" stop-color="#070A18"/>',
            '<stop offset="55%" stop-color="#0D1330"/>',
            '<stop offset="100%" stop-color="#FFD700"/>',
          '</linearGradient>',

          '<linearGradient id="bgsilver" x1="0" y1="0" x2="1" y2="1">',
            '<stop offset="0%" stop-color="#070A18"/>',
            '<stop offset="55%" stop-color="#0D1330"/>',
            '<stop offset="100%" stop-color="#C0C0C0"/>',
          '</linearGradient>',

          '<linearGradient id="bgbronze" x1="0" y1="0" x2="1" y2="1">',
            '<stop offset="0%" stop-color="#070A18"/>',
            '<stop offset="55%" stop-color="#0D1330"/>',
            '<stop offset="100%" stop-color="#CD7F32"/>',
          '</linearGradient>',

          // Neon border gradient
          '<linearGradient id="border" x1="0" y1="0" x2="1" y2="0">',
            '<stop offset="0%" stop-color="#00E5FF"/>',
            '<stop offset="50%" stop-color="#8A5CFF"/>',
            '<stop offset="100%" stop-color="#FF3DF2"/>',
          '</linearGradient>',

          WindfallSVG.ballDefs(),

          // Neon glow filter
          '<filter id="glow" x="-50%" y="-50%" width="200%" height="200%">',
            '<feGaussianBlur stdDeviation="6" result="blur"/>',
            '<feColorMatrix in="blur" type="matrix" values="',
              '1 0 0 0 0 ',
              '0 0.6 1 0 0 ',
              '0 0 1 0 0 ',
              '0 0 0 0.9 0',
            '" result="neon"/>',
            '<feMerge>',
              '<feMergeNode in="neon"/>',
              '<feMergeNode in="SourceGraphic"/>',
            '</feMerge>',
          '</filter>',

          // Soft shadow
          '<filter id="shadow" x="-50%" y="-50%" width="200%" height="200%">',
            '<feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.45"/>',
          '</filter>',

          // Animated shine gradient (subtle)
          '<linearGradient id="shine" x1="-1" y1="0" x2="1" y2="0">',
            '<stop offset="0%" stop-color="rgba(255,255,255,0)"/>',
            '<stop offset="50%" stop-color="rgba(255,255,255,0.12)"/>',
            '<stop offset="100%" stop-color="rgba(255,255,255,0)"/>',
          '</linearGradient>',
        '</defs>',
        
        // Background
        //'<rect width="600" height="600" fill="url(#bg)"/>',
        '<rect width="600" height="600" fill="', bgColor, '"/>',

        // Card
        '<rect x="40" y="55" width="520" height="490" rx="26" fill="rgba(0,0,0,0.20)" filter="url(#shadow)"/>',

        // Neon border
        '<rect x="40" y="55" width="520" height="490" rx="26" fill="none" stroke="url(#border)" stroke-width="3" opacity="0.9" filter="url(#glow)"/>',

        // Shine sweep (very subtle)
        '<g opacity="0.7">',
          '<rect x="-200" y="55" width="160" height="490" fill="url(#shine)">',
            '<animate attributeName="x" values="-200; 700" dur="6s" repeatCount="indefinite"/>',
          '</rect>',
        '</g>',

        // Header
        '<text x="70" y="120" fill="#ffffff" font-family="Inter, Arial" font-size="34" font-weight="800" letter-spacing="2">',
          'WINDFALL LOTTO',
        '</text>',
        '<text x="70" y="152" fill="#B7C7FF" font-family="Inter, Arial" font-size="18">',
          'Draw #', _u32ToString(drawId),
          ' Ticket #', tokenId.toString(),
        '</text>',
        '<text x="300" y="200" font-size="18" font-family="Inter, Arial" fill="#8A5CFF" text-anchor="middle">',
            'Ends: ', _dateTimeString(drawEnd),
        '</text>',

        // first row (3 balls)
         WindfallSVG.ball(170, 270, n[0]),
         WindfallSVG.ball(300, 270, n[1]),
         WindfallSVG.ball(430, 270, n[2]),

        // second row (2 balls centered)
         WindfallSVG.ball(235, 360, n[3]),
         WindfallSVG.ball(365, 360, n[4]),

        // Footer
        '<text x="70" y="470" fill="#8FA3FF" font-family="Inter, Arial" font-size="16">',
          'Minter: ', _addrShort(minter),
        '</text>',
        '<text x="70" y="495" fill="#8FA3FF" font-family="Inter, Arial" font-size="16">',
          'Numbers: ', _numsString(n),
        '</text>',

        // Small tagline
        '<text x="70" y="515" fill="rgba(255,255,255,0.55)" font-family="Inter, Arial" font-size="13">',
          'On-chain - Provably random - Transferable ticket',
        '</text>',
        '<text x="70" y="535" fill="rgba(255,255,255,0.55)" font-family="Inter, Arial" font-size="13">',
          'web : windfall-lotto.eth',
        '</text>',

        '</svg>'
    );
}
 

    function _dateTimeString(uint64 timestamp) internal pure returns (string memory) {
        (uint256 year, uint256 month, uint256 day) = _daysToDate(timestamp / 86400);
        uint256 secs = uint256(timestamp % 86400);
        uint256 hour = secs / 3600;
        uint256 minute = (secs % 3600) / 60;

        return string.concat(
            year.toString(), "-",
            _pad2(month), "-",
            _pad2(day), " ",
            _pad2(hour), ":",
            _pad2(minute), " UTC"
        );
    }

    function _pad2(uint256 v) internal pure returns (string memory) {
        if (v < 10) return string.concat("0", v.toString());
        return v.toString();
    }

    function _daysToDate(uint256 _days) internal pure returns (uint256 year, uint256 month, uint256 day) {
        int256 __days = int256(_days);

        int256 L = __days + 68569 + 2440588;
        int256 N = (4 * L) / 146097;
        L = L - (146097 * N + 3) / 4;
        int256 _year = (4000 * (L + 1)) / 1461001;
        L = L - (1461 * _year) / 4 + 31;
        int256 _month = (80 * L) / 2447;
        int256 _day = L - (2447 * _month) / 80;
        L = _month / 11;
        _month = _month + 2 - 12 * L;
        _year = 100 * (N - 49) + _year + L;

        year = uint256(_year);
        month = uint256(_month);
        day = uint256(_day);
    }

    function _numsString(uint8[5] memory n) internal pure returns (string memory) {
        // "12-44-87-03-55" (pads 1-digit with leading 0 for nicer look)
        return string.concat(
            _two(n[0]), "-", _two(n[1]), "-", _two(n[2]), "-", _two(n[3]), "-", _two(n[4])
        );
    }

    function _two(uint8 x) internal pure returns (string memory) {
        if (x < 10) return string.concat("0", uint256(x).toString());
        return uint256(x).toString();
    }

    function _u32ToString(uint32 x) internal pure returns (string memory) {
        return uint256(x).toString();
    }

    function _addrShort(address a) internal pure returns (string memory) {
        // Short display like 0x1234…ABCD
        bytes20 b = bytes20(a);
        bytes16 hexSymbols = 0x30313233343536373839616263646566;

        bytes memory out = new bytes(12); // "0x" + 4 + "…" + 4  => 2+4+1+4=11 (we use 12 for safety)
        out[0] = "0";
        out[1] = "x";

        // first 2 bytes => 4 hex chars
        for (uint256 i = 0; i < 2; i++) {
            out[2 + i*2]     = bytes1(hexSymbols[uint8(b[i] >> 4)]);
            out[2 + i*2 + 1] = bytes1(hexSymbols[uint8(b[i] & 0x0f)]);
        }

        out[6] = bytes1(uint8(0xE2)); // '…' (UTF-8 ellipsis) = E2 80 A6
        // but Solidity bytes are raw; easier: just use three dots "..."
        // We'll override it below with ASCII "..."

        // Replace with ASCII "..."
        out = abi.encodePacked("0x",
            _hex4(uint16(uint8(b[0])) << 8 | uint16(uint8(b[1]))),
            "...",
            _hex4(uint16(uint8(b[18])) << 8 | uint16(uint8(b[19])))
        );

        return string(out);
    }

    function _hex4(uint16 v) internal pure returns (string memory) {
        bytes16 hexSymbols = 0x30313233343536373839616263646566;
        bytes memory s = new bytes(4);
        s[0] = bytes1(hexSymbols[(v >> 12) & 0xF]);
        s[1] = bytes1(hexSymbols[(v >> 8) & 0xF]);
        s[2] = bytes1(hexSymbols[(v >> 4) & 0xF]);
        s[3] = bytes1(hexSymbols[v & 0xF]);
        return string(s);
    }

    function _unpack(bytes32 packed) internal pure returns (uint8[5] memory nums) {
        uint256 x = uint256(packed);
        nums[0] = uint8(x);
        nums[1] = uint8(x >> 8);
        nums[2] = uint8(x >> 16);
        nums[3] = uint8(x >> 24);
        nums[4] = uint8(x >> 32);
    }

    function tokensOfOwner(address owner) external view returns (uint256[] memory) {
        uint256 count = balanceOf(owner);
        uint256[] memory ids = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            ids[i] = tokenOfOwnerByIndex(owner, i);
        }

        return ids;
    }
}