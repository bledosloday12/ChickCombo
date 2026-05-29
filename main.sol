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
    }

    function acceptOwnership() external {
        if (msg.sender != _pendingOwner) revert CC_NotPending(msg.sender);
        address prev = _owner;
        _owner = msg.sender;
        _pendingOwner = address(0);
        emit CC_OwnerTransferred(prev, msg.sender);
    }

    function setPaused(bool on) external onlyOwner {
        paused = on;
        emit CC_PauseSet(msg.sender, on);
    }

    function donateLeague() external payable notPaused nonReentrant {
        if (msg.value == 0) revert CC_EthRejected();
        leaguePot += uint128(msg.value);
        emit CC_LeagueTopUp(msg.sender, uint128(msg.value));
    }

    function sweepLeague(address payable to, uint128 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert CC_ZeroAddr();
        if (amount > leaguePot) amount = leaguePot;
        leaguePot -= amount;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert CC_EthRejected();
        emit CC_LeagueSweep(to, amount);
    }

    function mintChick(uint16 speciesId, bytes32 nickname) external notPaused nonReentrant returns (uint256 chickId) {
        if (speciesId == 0 || speciesId > 49) revert CC_BadSpecies(speciesId);
        SpeciesGene memory gene = _species[uint8(speciesId)];
        if (gene.baseMight == 0) revert CC_BadSpecies(speciesId);
        if (nickname == bytes32(0)) revert CC_BadNickname();
        chickId = nextChickId++;
        uint32 baseVit = uint32(gene.baseMight + gene.baseGuard + gene.baseTempo);
        _chicks[chickId] = ChickProfile({
            speciesId: speciesId,
            level: 1,
            xp: 0,
            grain: 48,
            vitality: baseVit,
            might: gene.baseMight,
            guard: gene.baseGuard,
            tempo: gene.baseTempo,
            element: gene.element,
            lastFed: uint64(block.timestamp),
            lastTrained: uint64(block.timestamp),
            lastSpar: uint64(block.timestamp),
            mintedAt: uint64(block.timestamp),
            nickname: nickname,
            evolved: false
        });
        chickTrainer[chickId] = msg.sender;
        _trainerRoster[msg.sender].push(chickId);
        _primeMoves(chickId, gene.element);
        emit CC_ChickMinted(msg.sender, chickId, speciesId);
    }

    function renameChick(uint256 chickId, bytes32 nickname) external notPaused {
        if (nickname == bytes32(0)) revert CC_BadNickname();
        ChickProfile storage c = _loadChick(chickId);
        if (chickTrainer[chickId] != msg.sender) revert CC_NotTrainer(msg.sender, chickId);
        c.nickname = nickname;
    }

    function feedChick(uint256 chickId, uint32 spend) external notPaused nonReentrant {
        ChickProfile storage c = _loadChick(chickId);
        if (chickTrainer[chickId] != msg.sender) revert CC_NotTrainer(msg.sender, chickId);
        if (block.timestamp < c.lastFed + CC_FEED_COOLDOWN) {
            revert CC_Cooldown(c.lastFed + CC_FEED_COOLDOWN);
        }
        if (c.grain < spend) revert CC_GrainLow(c.grain, spend);
        c.grain -= spend;
        uint32 bump = spend / 3 + 2;
        c.vitality += bump;
        c.lastFed = uint64(block.timestamp);
        emit CC_ChickFed(msg.sender, chickId, spend, c.vitality);
    }

    function trainChick(uint256 chickId) external notPaused nonReentrant {
        ChickProfile storage c = _loadChick(chickId);
        if (chickTrainer[chickId] != msg.sender) revert CC_NotTrainer(msg.sender, chickId);
        if (block.timestamp < c.lastTrained + CC_TRAIN_COOLDOWN) {
            revert CC_Cooldown(c.lastTrained + CC_TRAIN_COOLDOWN);
        }
        if (c.grain < 6) revert CC_GrainLow(c.grain, 6);
        c.grain -= 6;
        uint8 pick = uint8(uint256(keccak256(abi.encodePacked(CC_SALT_A, chickId, block.prevrandao, c.level))) % 3);
        if (pick == 0) c.might += 1;
        else if (pick == 1) c.guard += 1;
        else c.tempo += 1;
        c.xp += 14;
        c.lastTrained = uint64(block.timestamp);
        _levelSync(c);
        emit CC_ChickTrained(msg.sender, chickId, c.might, c.guard, c.tempo);
    }

    function forageGrain(uint256 chickId) external notPaused {
        ChickProfile storage c = _loadChick(chickId);
        if (chickTrainer[chickId] != msg.sender) revert CC_NotTrainer(msg.sender, chickId);
        uint256 mix = uint256(keccak256(abi.encodePacked(CC_SALT_B, chickId, block.number, msg.sender)));
        uint32 gain = uint32(6 + (mix % 11));
        c.grain += gain;
    }

    function evolveIfReady(uint256 chickId) external notPaused nonReentrant {
        ChickProfile storage c = _loadChick(chickId);
        if (chickTrainer[chickId] != msg.sender) revert CC_NotTrainer(msg.sender, chickId);
        if (c.level < 18 || c.evolved) revert CC_EvolveNotReady(c.xp, c.level);
        if (c.xp < 900) revert CC_EvolveNotReady(c.xp, c.level);
        c.evolved = true;
        c.might += 3;
        c.guard += 3;
        c.tempo += 2;
        c.vitality += 20;
        emit CC_ChickEvolved(msg.sender, chickId, c.level);
    }

    function slotMove(uint256 chickId, uint8 slot, uint8 moveCode) external notPaused {
        if (slot >= CC_MOVE_SLOTS) revert CC_BadMoveSlot(slot);
        ChickProfile storage c = _loadChick(chickId);
        if (chickTrainer[chickId] != msg.sender) revert CC_NotTrainer(msg.sender, chickId);
        if (moveCode == 0 || moveCode > 32) revert CC_BadSpecies(moveCode);
        _moveRanks[chickId][slot] = moveCode;
        emit CC_MoveSlotted(msg.sender, chickId, slot, moveCode);
    }

    function openSpar(uint256 attackerId, uint256 defenderId) external notPaused returns (uint256 sparId) {
        if (attackerId == defenderId) revert CC_SparSelf();
        _loadChick(attackerId);
        _loadChick(defenderId);
        if (chickTrainer[attackerId] != msg.sender) revert CC_NotTrainer(msg.sender, attackerId);
        ChickProfile storage a = _chicks[attackerId];
        if (block.timestamp < a.lastSpar + CC_SPAR_COOLDOWN) {
            revert CC_Cooldown(a.lastSpar + CC_SPAR_COOLDOWN);
        }
        sparId = ++sparNonce;
        _openSpar[sparId] = SparTicket({
            attackerId: attackerId,
            defenderId: defenderId,
            openedAt: uint64(block.timestamp),
            settled: false
        });
        a.lastSpar = uint64(block.timestamp);
        emit CC_SparOpened(sparId, attackerId, defenderId);
    }

    function settleSpar(uint256 sparId) external notPaused nonReentrant {
        SparTicket storage t = _openSpar[sparId];
        if (t.openedAt == 0) revert CC_SparMissing(sparId);
        if (t.settled) revert CC_SparUnsettled(sparId);
        ChickProfile storage a = _chicks[t.attackerId];
        ChickProfile storage d = _chicks[t.defenderId];
        if (chickTrainer[t.attackerId] != msg.sender) revert CC_NotTrainer(msg.sender, t.attackerId);
        (uint256 winner, uint256 loser, uint32 xpGain) =
            _resolveSpar(t.attackerId, t.defenderId, a, d, sparId);
        t.settled = true;
        ChickProfile storage w = _chicks[winner];
        w.xp += xpGain;
        chickStreak[winner] += 1;
        chickStreak[loser] = 0;
        _levelSync(w);
        emit CC_SparSettled(sparId, winner, loser, xpGain);
    }

    function grantBonusGrain(address trainer, uint256 chickId, uint32 amount) external notPaused {
        if (msg.sender != ADDRESS_A && msg.sender != _owner) revert CC_NotOwner(msg.sender);
        ChickProfile storage c = _loadChick(chickId);
        if (chickTrainer[chickId] != trainer) revert CC_NotTrainer(trainer, chickId);
        c.grain += amount;
    }

    function rosterSize(address trainer) external view returns (uint256) {
        return _trainerRoster[trainer].length;
    }

    function rosterSlot(address trainer, uint256 idx) external view returns (uint256 chickId) {
        chickId = _trainerRoster[trainer][idx];
    }

    function readChick(uint256 chickId) external view returns (ChickProfile memory) {
        if (_chicks[chickId].mintedAt == 0) revert CC_NoChick(chickId);
        return _chicks[chickId];
    }

    function readSpecies(uint8 speciesId) external view returns (SpeciesGene memory) {
        return _species[speciesId];
    }

    function moveAt(uint256 chickId, uint8 slot) external view returns (uint8) {
        return _moveRanks[chickId][slot];
    }

    function typeAdvantage(uint8 atkElem, uint8 defElem) public pure returns (int8) {
        if (atkElem == defElem) return 0;
        if ((atkElem == 1 && defElem == 3) || (atkElem == 3 && defElem == 2) || (atkElem == 2 && defElem == 1)) return 1;
        if ((atkElem == 4 && defElem == 2) || (atkElem == 2 && defElem == 5) || (atkElem == 5 && defElem == 4)) return 1;
        if ((atkElem == 6 && defElem == 4) || (atkElem == 4 && defElem == 7) || (atkElem == 7 && defElem == 6)) return 1;
        if ((atkElem == 8 && defElem == 7) || (atkElem == 7 && defElem == 1) || (atkElem == 1 && defElem == 8)) return 1;
        if ((defElem == 1 && atkElem == 3) || (defElem == 3 && atkElem == 2) || (defElem == 2 && atkElem == 1)) return -1;
        if ((defElem == 4 && atkElem == 2) || (defElem == 2 && atkElem == 5) || (defElem == 5 && atkElem == 4)) return -1;
        if ((defElem == 6 && atkElem == 4) || (defElem == 4 && atkElem == 7) || (defElem == 7 && atkElem == 6)) return -1;
        if ((defElem == 8 && atkElem == 7) || (defElem == 7 && atkElem == 1) || (defElem == 1 && atkElem == 8)) return -1;
        return 0;
    }

    function _loadChick(uint256 chickId) private view returns (ChickProfile storage c) {
        c = _chicks[chickId];
        if (c.mintedAt == 0) revert CC_NoChick(chickId);
    }

    function _levelSync(ChickProfile storage c) private {
        uint16 target = uint16(1 + c.xp / 220);
        if (target > CC_MAX_LEVEL) target = CC_MAX_LEVEL;
        if (target > c.level) {
            uint16 delta = target - c.level;
            c.level = target;
            c.vitality += uint32(delta) * 3;
            c.grain += uint32(delta) * 2;
        }
    }

    function _primeMoves(uint256 chickId, uint8 elem) private {
        _moveRanks[chickId][0] = uint8(1 + (elem % 7));
        _moveRanks[chickId][1] = uint8(8 + (elem % 5));
        _moveRanks[chickId][2] = uint8(15 + (elem % 4));
        _moveRanks[chickId][3] = uint8(22 + (elem % 6));
    }

    function _resolveSpar(
        uint256 attackerId,
        uint256 defenderId,
        ChickProfile storage a,
        ChickProfile storage d,
        uint256 sparId
    ) private view returns (uint256 winner, uint256 loser, uint32 xpGain) {
        uint256 entropy = uint256(keccak256(abi.encodePacked(block.prevrandao, sparId, a.mintedAt, d.mintedAt)));
        int32 scoreA = int32(uint32(a.might + a.tempo / 2));
        int32 scoreD = int32(uint32(d.guard + d.tempo / 3));
        int8 adv = typeAdvantage(a.element, d.element);
        if (adv > 0) scoreA += 7;
        else if (adv < 0) scoreD += 7;
        scoreA += int32(uint32(entropy % 9));
        scoreD += int32(uint32((entropy >> 128) % 9));
        if (scoreA >= scoreD) {
            winner = attackerId;
            loser = defenderId;
            xpGain = 28 + uint32(entropy % 15);
        } else {
            winner = defenderId;
            loser = attackerId;
            xpGain = 20 + uint32(entropy % 12);
        }
    }

    function _seedSpeciesCatalog() private {
        _species[1] = SpeciesGene({
            label: bytes32(0x456d626572506565700000000000000000000000000000000000000000000000),
            baseMight: 11,
            baseGuard: 9,
            baseTempo: 10,
            element: 1
        });
        _species[2] = SpeciesGene({
            label: bytes32(0x41717561436c75636b0000000000000000000000000000000000000000000000),
            baseMight: 9,
            baseGuard: 11,
            baseTempo: 10,
            element: 2
        });
        _species[3] = SpeciesGene({
            label: bytes32(0x4c65616657696e67000000000000000000000000000000000000000000000000),
            baseMight: 10,
            baseGuard: 10,
            baseTempo: 11,
            element: 3
        });
        _species[4] = SpeciesGene({
            label: bytes32(0x537061726b48656e000000000000000000000000000000000000000000000000),
            baseMight: 12,
            baseGuard: 8,
            baseTempo: 11,
            element: 4
        });
        _species[5] = SpeciesGene({
            label: bytes32(0x46726f737442726f6f6400000000000000000000000000000000000000000000),
            baseMight: 8,
            baseGuard: 12,
            baseTempo: 9,
            element: 5
        });
        _species[6] = SpeciesGene({
            label: bytes32(0x53746f6e65526f6f737400000000000000000000000000000000000000000000),
            baseMight: 10,
            baseGuard: 13,
            baseTempo: 7,
            element: 6
        });
        _species[7] = SpeciesGene({
            label: bytes32(0x47616c6550756c6c657400000000000000000000000000000000000000000000),
            baseMight: 11,
            baseGuard: 8,
            baseTempo: 12,
            element: 1
        });
        _species[8] = SpeciesGene({
            label: bytes32(0x536861646f77436f6f7000000000000000000000000000000000000000000000),
            baseMight: 13,
            baseGuard: 9,
            baseTempo: 9,
            element: 7
        });
        _species[9] = SpeciesGene({
            label: bytes32(0x53756e436f6d6200000000000000000000000000000000000000000000000000),
            baseMight: 10,
            baseGuard: 10,
            baseTempo: 10,
            element: 1
        });
        _species[10] = SpeciesGene({
            label: bytes32(0x4d6f6f6e42726f6f646572000000000000000000000000000000000000000000),
            baseMight: 9,
            baseGuard: 12,
            baseTempo: 10,
            element: 7
        });
        _species[11] = SpeciesGene({
            label: bytes32(0x5468756e6465725065636b000000000000000000000000000000000000000000),
            baseMight: 14,
            baseGuard: 8,
            baseTempo: 10,
            element: 4
        });
        _species[12] = SpeciesGene({
            label: bytes32(0x4d6f737352756e6e657200000000000000000000000000000000000000000000),
            baseMight: 9,
            baseGuard: 10,
            baseTempo: 12,
            element: 3
        });
        _species[13] = SpeciesGene({
            label: bytes32(0x4372797374616c48656e00000000000000000000000000000000000000000000),
            baseMight: 10,
            baseGuard: 11,
            baseTempo: 10,
            element: 8
        });
        _species[14] = SpeciesGene({
            label: bytes32(0x4d61676d61576174746c65000000000000000000000000000000000000000000),
            baseMight: 13,
            baseGuard: 9,
            baseTempo: 8,
            element: 1
        });
        _species[15] = SpeciesGene({
            label: bytes32(0x5469646543616c6c657200000000000000000000000000000000000000000000),
            baseMight: 8,
            baseGuard: 11,
            baseTempo: 11,
            element: 2
        });
        _species[16] = SpeciesGene({
            label: bytes32(0x4272616d626c654265616b000000000000000000000000000000000000000000),
            baseMight: 11,
            baseGuard: 10,
            baseTempo: 9,
            element: 3
        });
        _species[17] = SpeciesGene({
            label: bytes32(0x566f6c744e657374000000000000000000000000000000000000000000000000),
            baseMight: 12,
            baseGuard: 9,
            baseTempo: 11,
            element: 4
        });
        _species[18] = SpeciesGene({
            label: bytes32(0x476c61636965724c617965720000000000000000000000000000000000000000),
            baseMight: 8,
            baseGuard: 13,
            baseTempo: 9,
            element: 5
        });
        _species[19] = SpeciesGene({
            label: bytes32(0x51756172747a436c75636b000000000000000000000000000000000000000000),
            baseMight: 10,
            baseGuard: 12,
            baseTempo: 9,
            element: 8
        });
        _species[20] = SpeciesGene({
            label: bytes32(0x44757374446576696c0000000000000000000000000000000000000000000000),
            baseMight: 11,
            baseGuard: 9,
            baseTempo: 11,
            element: 6
        });
        _species[21] = SpeciesGene({
            label: bytes32(0x537461726c696e67436869636b00000000000000000000000000000000000000),
            baseMight: 9,
            baseGuard: 9,
            baseTempo: 13,
            element: 7
        });
        _species[22] = SpeciesGene({
            label: bytes32(0x436f6d6574437265737400000000000000000000000000000000000000000000),
            baseMight: 12,
