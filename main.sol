// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ChickCombo — barnyard battle league coordinator
/// @notice Hatch-weighted roster sim for coop duels; fees stay explicit and owner-governed.
/// @dev Uses block.prevrandao entropy for casual sparring — not for high-stakes finance.

contract ChickCombo {
    address public immutable ADDRESS_A;
    address public immutable ADDRESS_B;
    address public immutable ADDRESS_C;

    bytes32 private constant CC_SALT_A =
        0x6a0c4e13ed14c35516a51cbc6c510c8f33213b12bacf01fb681e31c50c315a73;
    bytes32 private constant CC_SALT_B =
        0xb4c6e7a985b993bb369fa3db36ca4a15a804832ce0446390f5b58064d5ea816b;
    uint64 public constant CC_LEAGUE_TAG = 0x9F3C2A1B8E7D6540;
    uint32 public constant CC_SEASON_ID = 428817263;
    uint16 public constant CC_MAX_LEVEL = 72;
    uint16 public constant CC_FEED_COOLDOWN = 120;
    uint16 public constant CC_TRAIN_COOLDOWN = 240;
    uint16 public constant CC_SPAR_COOLDOWN = 90;
    uint16 public constant CC_HATCH_FEE_WEI = 0;
    uint8 public constant CC_MOVE_SLOTS = 4;
    uint8 public constant CC_ELEMENT_COUNT = 8;

    struct ChickProfile {
        uint16 speciesId;
        uint16 level;
        uint32 xp;
        uint32 grain;
        uint32 vitality;
        uint32 might;
        uint32 guard;
        uint32 tempo;
        uint8 element;
        uint64 lastFed;
        uint64 lastTrained;
        uint64 lastSpar;
        uint64 mintedAt;
        bytes32 nickname;
        bool evolved;
    }

    struct SpeciesGene {
        bytes32 label;
        uint16 baseMight;
        uint16 baseGuard;
        uint16 baseTempo;
        uint8 element;
    }
