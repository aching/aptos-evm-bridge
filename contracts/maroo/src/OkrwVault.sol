// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title OkrwVault — lock/unlock vault for Maroo native OKRW bridged to Aptos.
/// @notice OKRW is Maroo's native gas token (18 decimals, base unit aokrw).
///         Users lock native OKRW via payable `deposit`; a trusted off-chain
///         relayer attests deposits to the Aptos side, and calls `release`
///         to unlock OKRW on the return path (Aptos burn -> Maroo unlock).
/// @dev Demo security model: single trusted `relayer`. Production would use a
///      multisig / validator set. Daily cap bounds relayer compromise blast radius.
contract OkrwVault {
    // ------------------------------------------------------------------ state

    /// @notice Address authorized to release locked OKRW (the relayer key).
    address public relayer;

    /// @notice Contract admin (can rotate relayer, pause, set cap). Demo: deployer.
    address public admin;

    /// @notice Pending admin for two-step transfer (zero = none in flight).
    address public pendingAdmin;

    /// @notice Reentrancy mutex for `release` (defense in depth around the
    ///         native-OKRW external call; state is also updated before it).
    uint256 private _locked;

    /// @notice Paused flag — halts deposits and releases.
    bool public paused;

    /// @notice Max total released per UTC day (demo safety rail). 0 = no releases.
    uint256 public dailyReleaseCap;

    /// @notice Monotonic deposit nonce. Each deposit consumes exactly one nonce.
    uint64 public nextDepositNonce;

    /// @notice Monotonic release nonce, independent from deposits.
    uint64 public nextReleaseNonce;

    /// @notice Amount released in the current UTC day window.
    uint256 public releasedToday;

    /// @notice Start timestamp of the current UTC day window.
    uint256 public currentDay;

    /// @notice Processed release ids (keccak256(to, amount, releaseNonce)) — replay guard.
    mapping(bytes32 => bool) public processedRelease;

    // ------------------------------------------------------------------ events

    /// @notice Emitted when native OKRW is locked for bridging to Aptos.
    /// @param marooSender Depositor on Maroo.
    /// @param aptosRecipient Destination Aptos address (32 raw bytes, BCS form).
    /// @param amount Locked amount in aokrw.
    /// @param nonce Deposit nonce (monotonic).
    event DepositLocked(
        address indexed marooSender,
        bytes aptosRecipient,
        uint256 amount,
        uint64 nonce
    );

    /// @notice Emitted when locked OKRW is released back to a Maroo address.
    event Released(address indexed to, uint256 amount, uint64 nonce);

    event RelayerUpdated(address indexed oldRelayer, address indexed newRelayer);
    event AdminProposed(address indexed oldAdmin, address indexed newAdmin);
    event AdminAccepted(address indexed oldAdmin, address indexed newAdmin);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event DailyReleaseCapUpdated(uint256 oldCap, uint256 newCap);

    // ------------------------------------------------------------------ errors

    error ZeroAmount();
    error ZeroAddress();
    error BadRecipientLength(uint256 len);
    error NotRelayer(address caller);
    error NotAdmin(address caller);
    error IsPaused();
    error AlreadyProcessed(bytes32 id);
    error OutOfOrderNonce(uint64 expected, uint64 got);
    error DailyCapExceeded(uint256 requested, uint256 remaining);
    error ReleaseFailed();
    error Reentrant();
    error NotPendingAdmin(address caller);

    // --------------------------------------------------------------- modifiers

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert NotRelayer(msg.sender);
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 0) revert Reentrant();
        _locked = 1;
        _;
        _locked = 0;
    }

    // ------------------------------------------------------------- constructor

    constructor(address _relayer, address _admin, uint256 _dailyReleaseCap) {
        if (_relayer == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        relayer = _relayer;
        admin = _admin;
        dailyReleaseCap = _dailyReleaseCap;
        currentDay = block.timestamp / 1 days;
        emit RelayerUpdated(address(0), _relayer);
        emit DailyReleaseCapUpdated(0, _dailyReleaseCap);
    }

    // ---------------------------------------------------------------- deposits

    /// @notice Lock native OKRW for bridging to Aptos.
    /// @param aptosRecipient Destination Aptos account, 32 raw bytes (BCS address).
    /// @return nonce The deposit nonce assigned to this lock.
    function deposit(bytes calldata aptosRecipient)
        external
        payable
        whenNotPaused
        returns (uint64 nonce)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (aptosRecipient.length != 32) revert BadRecipientLength(aptosRecipient.length);
        nonce = nextDepositNonce;
        nextDepositNonce = nonce + 1;
        emit DepositLocked(msg.sender, aptosRecipient, msg.value, nonce);
    }

    // ---------------------------------------------------------------- releases

    /// @notice Release locked OKRW. Called by the relayer after observing the
    ///         corresponding burn on Aptos.
    /// @param to Maroo recipient of the unlocked OKRW.
    /// @param amount Amount in aokrw.
    /// @param releaseNonce Relayer-assigned nonce (monotonic per relayer).
    function release(address payable to, uint256 amount, uint64 releaseNonce)
        external
        onlyRelayer
        whenNotPaused
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        bytes32 id = keccak256(abi.encode(to, amount, releaseNonce));
        if (processedRelease[id]) revert AlreadyProcessed(id);
        if (releaseNonce != nextReleaseNonce) revert OutOfOrderNonce(nextReleaseNonce, releaseNonce);
        processedRelease[id] = true;

        // Daily cap accounting (UTC day windows).
        uint256 day = block.timestamp / 1 days;
        if (day > currentDay) {
            currentDay = day;
            releasedToday = 0;
        }
        if (releasedToday + amount > dailyReleaseCap) {
            revert DailyCapExceeded(amount, dailyReleaseCap - releasedToday);
        }
        releasedToday += amount;
        nextReleaseNonce = releaseNonce + 1;

        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ReleaseFailed();
        emit Released(to, amount, releaseNonce);
    }

    // ------------------------------------------------------------------- admin

    function setRelayer(address _relayer) external onlyAdmin {
        if (_relayer == address(0)) revert ZeroAddress();
        emit RelayerUpdated(relayer, _relayer);
        relayer = _relayer;
    }

    /// @notice Propose a new admin. Completes only when the pending admin
    ///         calls `acceptAdmin`, proving key ownership. Prevents bricking
    ///         pause/relayer/cap controls by typo-ing the admin address.
    function proposeAdmin(address _admin) external onlyAdmin {
        if (_admin == address(0)) revert ZeroAddress();
        pendingAdmin = _admin;
        emit AdminProposed(admin, _admin);
    }

    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin(msg.sender);
        emit AdminAccepted(admin, pendingAdmin);
        admin = pendingAdmin;
        pendingAdmin = address(0);
    }

    function setDailyReleaseCap(uint256 _cap) external onlyAdmin {
        emit DailyReleaseCapUpdated(dailyReleaseCap, _cap);
        dailyReleaseCap = _cap;
    }

    function pause() external onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Total OKRW currently escrowed in the vault.
    function escrowed() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {
        revert("direct transfers not allowed; use deposit()");
    }
}
