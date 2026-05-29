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

    struct SparTicket {
        uint256 attackerId;
        uint256 defenderId;
        uint64 openedAt;
        bool settled;
    }

    address private _owner;
    address private _pendingOwner;
    bool public paused;
    uint256 private _guard;
    uint256 public nextChickId = 1;
    uint256 public sparNonce;
    uint128 public leaguePot;

    mapping(uint256 => ChickProfile) private _chicks;
    mapping(uint256 => address) public chickTrainer;
    mapping(address => uint256[]) private _trainerRoster;
    mapping(uint8 => SpeciesGene) private _species;
    mapping(uint256 => mapping(uint8 => uint8)) private _moveRanks;
    mapping(uint256 => uint256) public chickStreak;
    mapping(uint256 => SparTicket) private _openSpar;

    error CC_NotOwner(address caller);
    error CC_NotPending(address caller);
    error CC_Reentrancy();
    error CC_Paused();
    error CC_ZeroAddr();
    error CC_NoChick(uint256 chickId);
    error CC_NotTrainer(address who, uint256 chickId);
    error CC_BadSpecies(uint16 speciesId);
    error CC_BadMoveSlot(uint8 slot);
    error CC_EvolveNotReady(uint32 xp, uint16 level);
    error CC_LevelCap(uint16 have, uint16 cap);
    error CC_Cooldown(uint64 readyAfter);
    error CC_GrainLow(uint32 have, uint32 need);
    error CC_SparSelf();
    error CC_SparUnsettled(uint256 sparId);
    error CC_SparMissing(uint256 sparId);
    error CC_BadNickname();
    error CC_EthRejected();

    event CC_OwnerTransferQueued(address indexed from, address indexed to);
    event CC_OwnerTransferred(address indexed from, address indexed to);
    event CC_PauseSet(address indexed who, bool on);
    event CC_ChickMinted(address indexed trainer, uint256 indexed chickId, uint16 speciesId);
    event CC_ChickFed(address indexed trainer, uint256 indexed chickId, uint32 grain, uint32 vitality);
    event CC_ChickTrained(address indexed trainer, uint256 indexed chickId, uint32 might, uint32 guard, uint32 tempo);
    event CC_ChickEvolved(address indexed trainer, uint256 indexed chickId, uint16 newLevel);
    event CC_MoveSlotted(address indexed trainer, uint256 indexed chickId, uint8 slot, uint8 moveCode);
    event CC_SparOpened(uint256 indexed sparId, uint256 attacker, uint256 defender);
    event CC_SparSettled(uint256 indexed sparId, uint256 winner, uint256 loser, uint32 xpGain);
    event CC_LeagueTopUp(address indexed from, uint128 amount);
    event CC_LeagueSweep(address indexed to, uint128 amount);

    modifier onlyOwner() {
        if (msg.sender != _owner) revert CC_NotOwner(msg.sender);
        _;
    }

    modifier notPaused() {
        if (paused) revert CC_Paused();
        _;
    }

    modifier nonReentrant() {
        if (_guard == 1) revert CC_Reentrancy();
        _guard = 1;
        _;
        _guard = 0;
    }

    constructor() {
        _owner = msg.sender;
        ADDRESS_A = 0x1D99cb8e9c62f38d4375f3c2Db0AA86c7B478552;
        ADDRESS_B = 0xe506D840582E64cA633d92317dD18DDEE790247D;
        ADDRESS_C = 0x4Aa63867906B2370Ebb1068f7955fe579327BcE5;
        if (ADDRESS_A == address(0) || ADDRESS_B == address(0) || ADDRESS_C == address(0)) revert CC_ZeroAddr();
        _seedSpeciesCatalog();
    }

    receive() external payable {
        revert CC_EthRejected();
    }

    fallback() external payable {
        revert CC_EthRejected();
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function pendingOwner() external view returns (address) {
        return _pendingOwner;
    }

    function queueOwnershipHandoff(address nextOwner) external onlyOwner {
        if (nextOwner == address(0)) revert CC_ZeroAddr();
        _pendingOwner = nextOwner;
        emit CC_OwnerTransferQueued(_owner, nextOwner);
