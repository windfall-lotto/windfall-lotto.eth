// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/Strings.sol";

library WindfallSVG {
    using Strings for uint256;

    function ballDefs() internal pure returns (string memory) {
        return string.concat(
            '<defs>',

                '<filter id="glow" x="-50%" y="-50%" width="200%" height="200%">',
                    '<feGaussianBlur stdDeviation="3.2" result="b"/>',
                    '<feMerge>',
                        '<feMergeNode in="b"/>',
                        '<feMergeNode in="SourceGraphic"/>',
                    '</feMerge>',
                '</filter>',

                '<radialGradient id="bo0" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#E8FCFF"/>',
                    '<stop offset="100%" stop-color="#B8F3FF"/>',
                '</radialGradient>',
                '<radialGradient id="bi0" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#127A8A"/>',
                    '<stop offset="100%" stop-color="#062C33"/>',
                '</radialGradient>',

                '<radialGradient id="bo1" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#FFE5EA"/>',
                    '<stop offset="100%" stop-color="#FFC2CD"/>',
                '</radialGradient>',
                '<radialGradient id="bi1" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#A61E4D"/>',
                    '<stop offset="100%" stop-color="#3F0A1B"/>',
                '</radialGradient>',

                '<radialGradient id="bo2" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#FFF5D6"/>',
                    '<stop offset="100%" stop-color="#FFE08A"/>',
                '</radialGradient>',
                '<radialGradient id="bi2" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#B77900"/>',
                    '<stop offset="100%" stop-color="#4A3200"/>',
                '</radialGradient>',

                '<radialGradient id="bo3" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#DBFFF4"/>',
                    '<stop offset="100%" stop-color="#9EF0D6"/>',
                '</radialGradient>',
                '<radialGradient id="bi3" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#0A8F6A"/>',
                    '<stop offset="100%" stop-color="#05382A"/>',
                '</radialGradient>',

                '<radialGradient id="bo4" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#EFE7FF"/>',
                    '<stop offset="100%" stop-color="#CDB8FF"/>',
                '</radialGradient>',
                '<radialGradient id="bi4" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#5B33B6"/>',
                    '<stop offset="100%" stop-color="#241249"/>',
                '</radialGradient>',

                '<radialGradient id="bo5" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#FFF0D9"/>',
                    '<stop offset="100%" stop-color="#FFD08A"/>',
                '</radialGradient>',
                '<radialGradient id="bi5" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#B85E00"/>',
                    '<stop offset="100%" stop-color="#4A2600"/>',
                '</radialGradient>',

                '<radialGradient id="bo6" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#FFE1E8"/>',
                    '<stop offset="100%" stop-color="#FFB3C3"/>',
                '</radialGradient>',
                '<radialGradient id="bi6" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#A11D43"/>',
                    '<stop offset="100%" stop-color="#3D0A18"/>',
                '</radialGradient>',

                '<radialGradient id="bo7" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#DDF5FF"/>',
                    '<stop offset="100%" stop-color="#9ADFFF"/>',
                '</radialGradient>',
                '<radialGradient id="bi7" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#0B5D79"/>',
                    '<stop offset="100%" stop-color="#042734"/>',
                '</radialGradient>',

                '<radialGradient id="bo8" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#ECDDFF"/>',
                    '<stop offset="100%" stop-color="#C9A7FF"/>',
                '</radialGradient>',
                '<radialGradient id="bi8" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#5523A0"/>',
                    '<stop offset="100%" stop-color="#220D43"/>',
                '</radialGradient>',

                '<radialGradient id="bo9" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#F1FFDF"/>',
                    '<stop offset="100%" stop-color="#D4FF9B"/>',
                '</radialGradient>',
                '<radialGradient id="bi9" cx="30%" cy="30%" r="80%">',
                    '<stop offset="0%" stop-color="#5B8C1A"/>',
                    '<stop offset="100%" stop-color="#24380A"/>',
                '</radialGradient>',

            '</defs>'
        );
    }

    function ball(uint256 cx, uint256 cy, uint8 val) internal pure returns (string memory) {
        (string memory ring, uint8 theme) = _ballMeta(val);
        string memory t = uint256(theme).toString();

        return string.concat(
            '<g>',
                '<circle cx="', cx.toString(),
                '" cy="', cy.toString(),
                '" r="47" fill="none" stroke="', ring,
                '" stroke-width="3" opacity="0.95" filter="url(#glow)"/>',

                '<circle cx="', cx.toString(),
                '" cy="', cy.toString(),
                '" r="49" fill="url(#bo', t, ')"/>',

                '<circle cx="', cx.toString(),
                '" cy="', cy.toString(),
                '" r="36" fill="url(#bi', t, ')"/>',

                '<circle cx="', (cx - 13).toString(),
                '" cy="', (cy - 15).toString(),
                '" r="6" fill="rgba(255,255,255,0.24)"/>',

                '<text x="', cx.toString(),
                '" y="', (cy + 13).toString(),
                '" text-anchor="middle" fill="#FFFFFF" font-family="Inter,Arial" font-size="28" font-weight="900">',
                    uint256(val).toString(),
                '</text>',
            '</g>'
        );
    }

    function _ballMeta(uint8 val) internal pure returns (string memory ring, uint8 theme) {
        theme = val % 10;

        if (theme == 0) return ("#00E5FF", 0);
        if (theme == 1) return ("#FF4D6D", 1);
        if (theme == 2) return ("#FFD166", 2);
        if (theme == 3) return ("#06D6A0", 3);
        if (theme == 4) return ("#8A5CFF", 4);
        if (theme == 5) return ("#FF9F1C", 5);
        if (theme == 6) return ("#EF476F", 6);
        if (theme == 7) return ("#118AB2", 7);
        if (theme == 8) return ("#8338EC", 8);

        return ("#A8FF60", 9);
    }
}