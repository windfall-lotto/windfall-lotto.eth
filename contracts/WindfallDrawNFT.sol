// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {WindfallSVG} from "./WindfallSVG.sol";

contract WindfallDrawNFT is ERC721 {
    // ===== Errors =====
    error ZeroAddress();
    error LottoAlreadySet();
    error NotHost();
    error NotLotto();
    error ContractNFTnonTransferable();
    error NonExistent();


    using Strings for uint256;

    address public lotto;
    address public immutable hostTreasury;
    uint256 public nextId = 1;

    struct DrawData {
        uint32 drawId;
        uint64 revealedAt;       // unix timestamp
        uint128 jackpotAmount;   // snapshot jackpot amount in wei-like token units (18 decimals for TOKEN)
        bytes32 packedWinning;   // packed 5 uint8
        uint8 activeTier;
        uint32 activeWinners;
    }

    mapping(uint256 => DrawData) public drawData;

    //mapping(uint32 => uint256) public drawIdToOfficialTokenId;
    //mapping(uint32 => uint256) public drawIdToHostTokenId;

    modifier onlyLotto() {
        if (msg.sender != lotto) revert NotLotto();
        _;
    }

    modifier onlyHost() {
        if (msg.sender != hostTreasury) revert NotHost();
        _;
    }

    constructor(
        address _hostTreasury
    ) ERC721("Windfall Draw", "WDRAW") {
        if (_hostTreasury == address(0)) revert ZeroAddress();
        hostTreasury = _hostTreasury;
    }

    function setLotto(address _lotto) external onlyHost {
        // no require for test
        if (lotto != address(0)) revert LottoAlreadySet();
        if (_lotto == address(0)) revert ZeroAddress();
        lotto = _lotto;
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // NFTs owned by the lotto contract itself cannot be transferred
        if (from == lotto && to != address(0)) {
            revert ContractNFTnonTransferable();
        }

        return super._update(to, tokenId, auth);
    }

    function mintDraw(
        address to,
        uint32 drawId,
        uint64 revealedAt,
        uint128 jackpotAmount,
        bytes32 packedWinning,
        uint8 activeTier,
        uint32 activeWinners
    ) external onlyLotto returns (uint256 id) {
        id = nextId++;
        drawData[id] = DrawData(drawId, revealedAt, jackpotAmount, packedWinning, activeTier, activeWinners);
        _safeMint(to, id);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if(_ownerOf(tokenId) == address(0)) revert NonExistent();

        DrawData memory d = drawData[tokenId];
        uint8[5] memory w = _unpack(d.packedWinning);

        string memory drawDate = _dateTimeString(d.revealedAt);
        string memory jackpotStr = _manaAmount(d.jackpotAmount);

        uint8 tier = d.activeTier;
        uint32 winners = d.activeWinners;

        string memory svg = _buildSVG(
            tokenId,
            d.drawId,
            d.revealedAt,
            drawDate,
            jackpotStr,
            w,
            tier,
            winners
        );

        string memory image = string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(svg))
        );

        string memory attrs = string.concat(
            '[{"trait_type":"Draw Number","value":"', uint256(d.drawId).toString(),
            '"},{"trait_type":"Reveal Date","value":"', drawDate,
            '"},{"trait_type":"Jackpot","value":"', jackpotStr,
            '"},{"trait_type":"Timestamp","display_type":"number","value":"', uint256(d.revealedAt).toString(),
            '"},{"trait_type":"Winning Numbers","value":"', _numsString(w),
            '"},{"trait_type":"W1","value":', uint256(w[0]).toString(),
            '},{"trait_type":"W2","value":', uint256(w[1]).toString(),
            '},{"trait_type":"W3","value":', uint256(w[2]).toString(),
            '},{"trait_type":"W4","value":', uint256(w[3]).toString(),
            '},{"trait_type":"W5","value":', uint256(w[4]).toString(),
            '}]'
        );

        string memory json = string.concat(
            '{"name":"Windfall Official Result #', uint256(d.drawId).toString(),
            '","description":"web : windfall-lotto.eth",',
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
        uint64 revealedAt,
        string memory drawDate,
        string memory jackpotStr,
        uint8[5] memory w,
        uint8 tier,
        uint32 winners
    ) internal pure returns (string memory) {
        string memory numbersLine = _numsString(w);
        string memory tsLine = uint256(revealedAt).toString();

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="700" height="700" viewBox="0 0 700 700" preserveAspectRatio="xMidYMid meet">',
            '<defs>',

                '<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">',
                    '<stop offset="0%" stop-color="#AFB0B3"/>',
                    '<stop offset="55%" stop-color="#0F1535"/>',
                    '<stop offset="100%" stop-color="#FFDF00"/>',
                '</linearGradient>',

                '<linearGradient id="frame" x1="0" y1="0" x2="1" y2="0">',
                    '<stop offset="0%" stop-color="#00E5FF"/>',
                    '<stop offset="50%" stop-color="#8A5CFF"/>',
                    '<stop offset="100%" stop-color="#FF42E8"/>',
                '</linearGradient>',

                '<linearGradient id="badge" x1="0" y1="0" x2="1" y2="0">',
                    '<stop offset="0%" stop-color="#00E5FF"/>',
                    '<stop offset="100%" stop-color="#8A5CFF"/>',
                '</linearGradient>',

                WindfallSVG.ballDefs(),

                '<filter id="glow" x="-50%" y="-50%" width="200%" height="200%">',
                    '<feGaussianBlur stdDeviation="7" result="blur"/>',
                    '<feColorMatrix in="blur" type="matrix" values="',
                        '1 0 0 0 0 ',
                        '0 0.7 1 0 0 ',
                        '0 0 1 0 0 ',
                        '0 0 0 1 0',
                    '" result="neon"/>',
                    '<feMerge>',
                        '<feMergeNode in="neon"/>',
                        '<feMergeNode in="SourceGraphic"/>',
                    '</feMerge>',
                '</filter>',

                '<filter id="shadow" x="-50%" y="-50%" width="200%" height="200%">',
                    '<feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000000" flood-opacity="0.45"/>',
                '</filter>',

                '<linearGradient id="shine" x1="-1" y1="0" x2="1" y2="0">',
                    '<stop offset="0%" stop-color="rgba(255,255,255,0)"/>',
                    '<stop offset="50%" stop-color="rgba(255,255,255,0.16)"/>',
                    '<stop offset="100%" stop-color="rgba(255,255,255,0)"/>',
                '</linearGradient>',

                '<radialGradient id="orb" cx="50%" cy="50%" r="50%">',
                    '<stop offset="0%" stop-color="#8A5CFF" stop-opacity="0.28"/>',
                    '<stop offset="100%" stop-color="#8A5CFF" stop-opacity="0"/>',
                '</radialGradient>',

            '</defs>',

            '<rect width="700" height="700" fill="url(#bg)"/>',

            '<circle cx="120" cy="130" r="120" fill="url(#orb)">',
                '<animate attributeName="cy" values="130;150;130" dur="8s" repeatCount="indefinite"/>',
            '</circle>',
            '<circle cx="590" cy="560" r="150" fill="url(#orb)">',
                '<animate attributeName="cy" values="560;535;560" dur="10s" repeatCount="indefinite"/>',
            '</circle>',

            '<rect x="45" y="50" width="610" height="600" rx="30" fill="rgba(0,0,0,0.22)" filter="url(#shadow)"/>',
            '<rect x="45" y="50" width="610" height="600" rx="30" fill="none" stroke="url(#frame)" stroke-width="3.5" opacity="0.95" filter="url(#glow)"/>',

            '<g opacity="0.65">',
                '<rect x="-220" y="50" width="170" height="600" fill="url(#shine)">',
                    '<animate attributeName="x" values="-220;800" dur="7s" repeatCount="indefinite"/>',
                '</rect>',
            '</g>',

            '<text x="80" y="105" fill="#FFFFFF" font-family="Inter,Arial" font-size="30" font-weight="900" letter-spacing="2">',
                'WINDFALL LOTTO',
            '</text>',

            '<rect x="80" y="122" width="230" height="34" rx="10" fill="url(#badge)" filter="url(#glow)"/>',
            '<text x="195" y="145" text-anchor="middle" fill="#FFFFFF" font-family="Inter,Arial" font-size="15" font-weight="900" letter-spacing="1.4">',
                'OFFICIAL RESULT',
            '</text>',

            '<text x="80" y="195" fill="#FFFFFF" font-family="Inter,Arial" font-size="30" font-weight="900">',
                'Draw #', uint256(drawId).toString(),
            '</text>',
            '<text x="250" y="195" fill="#8FA3FF" font-family="Inter,Arial" font-size="16">',
                'Poster Token #', tokenId.toString(),
            '</text>',

            '<rect x="446" y="122" width="173" height="78" rx="16" fill="rgba(255,255,255,0.05)" stroke="rgba(255,255,255,0.10)"/>',
            '<text x="461" y="148" fill="#8FA3FF" font-family="Inter,Arial" font-size="14" font-weight="700">',
                'GOOD NUMBERS: ', uint256(tier).toString(),
            '</text>',
            '<text x="461" y="184" fill="#FFD76A" font-family="Inter,Arial" font-size="22" font-weight="900">',
                uint256(winners).toString(), ' WIN(S)',
            '</text>',

            '<rect x="80" y="220" width="255" height="78" rx="16" fill="rgba(255,255,255,0.05)" stroke="rgba(255,255,255,0.10)"/>',
            '<text x="100" y="248" fill="#8FA3FF" font-family="Inter,Arial" font-size="14" font-weight="700">',
                'JACKPOT AMOUNT',
            '</text>',
            '<text x="100" y="279" fill="#FFD76A" font-family="Inter,Arial" font-size="24" font-weight="900">',
                jackpotStr,
            '</text>',

            '<rect x="365" y="220" width="255" height="78" rx="16" fill="rgba(255,255,255,0.05)" stroke="rgba(255,255,255,0.10)"/>',
            '<text x="385" y="248" fill="#8FA3FF" font-family="Inter,Arial" font-size="14" font-weight="700">',
                'REVEAL DATE (UTC)',
            '</text>',
            '<text x="385" y="279" fill="#FFFFFF" font-family="Inter,Arial" font-size="20" font-weight="800">',
                drawDate,
            '</text>',

            WindfallSVG.ball(202, 395, w[0]),
            WindfallSVG.ball(350, 395, w[1]),
            WindfallSVG.ball(498, 395, w[2]),
            WindfallSVG.ball(270, 505, w[3]),
            WindfallSVG.ball(430, 505, w[4]),

            '<rect x="80" y="565" width="540" height="44" rx="14" fill="rgba(255,255,255,0.05)" stroke="rgba(255,255,255,0.08)"/>',
            '<text x="250" y="595" fill="#FFFFFF" font-family="Inter,Arial" font-size="24" font-weight="900" letter-spacing="2">',
                numbersLine,
            '</text>',

            '<text x="80" y="625" fill="rgba(255,255,255,0.55)" font-family="Inter, Arial" font-size="13">',
                'web : windfall-lotto.eth',
            '</text>',
            '<text x="80" y="640" fill="rgba(255,255,255,0.58)" font-family="Inter,Arial" font-size="13">',
                'Official on-chain VRF result - Unix timestamp: ', tsLine,
            '</text>',

            '</svg>'
        );
    }

    function _numsString(uint8[5] memory n) internal pure returns (string memory) {
        return string.concat(
            _two(n[0]), "-", _two(n[1]), "-", _two(n[2]), "-", _two(n[3]), "-", _two(n[4])
        );
    }

    function _two(uint8 x) internal pure returns (string memory) {
        if (x < 10) return string.concat("0", uint256(x).toString());
        return uint256(x).toString();
    }

    function _manaAmount(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e18;

        if (whole >= 1_000) {
            uint256 unit;
            string memory suffix;

            if (whole >= 1_000_000_000) {
                unit = 1_000_000_000;
                suffix = "B USD";
            } else if (whole >= 1_000_000) {
                unit = 1_000_000;
                suffix = "M USD";
            } else {
                unit = 1_000;
                suffix = "K USD";
            }

            uint256 scaled = whole * 1000 / unit;

            return string.concat(
                (scaled / 1000).toString(),
                ".",
                _pad3(scaled % 1000),
                suffix
            );
        }

        return string.concat(
            whole.toString(),
            ".",
            _pad2((amount % 1e18) / 1e16),
            " USD(DAI)"
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

    function _pad3(uint256 v) internal pure returns (string memory) {
        if (v < 10) return string.concat("00", v.toString());
        if (v < 100) return string.concat("0", v.toString());
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

    function _unpack(bytes32 packed) internal pure returns (uint8[5] memory nums) {
        uint256 x = uint256(packed);
        nums[0] = uint8(x);
        nums[1] = uint8(x >> 8);
        nums[2] = uint8(x >> 16);
        nums[3] = uint8(x >> 24);
        nums[4] = uint8(x >> 32);
    }
    /*
    function officialTokenIdOfDraw(uint32 drawId) external view returns (uint256) {
        return drawIdToOfficialTokenId[drawId];
    }

    function hostTokenIdOfDraw(uint32 drawId) external view returns (uint256) {
        return drawIdToHostTokenId[drawId];
    }
    */
}