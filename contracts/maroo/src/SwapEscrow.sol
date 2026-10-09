// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SwapEscrow — ETH escrow for Move Bridge cross-chain swaps (ETH -> APT).
/// @notice User locks ETH with a min-out + deadline. A solver fills APT on
///         Aptos from inventory, then calls `claim` with the fill proof to
///         release the ETH. After the deadline the user (and only the user)
///         can `refund`. No admin withdraw path exists by construction:
///         escrow can only go to solver-on-claim or user-on-refund.
/// @dev Two claim paths: (a) solver-attested + challenge window (v1);
///      (b) committee-attested via FillAttester (v2) — M-of-N EIP-712
///      signatures over the fill, settling immediately with no challenge
///      window. The attester path is strictly stronger; the solver path
///      remains for permissionless liveness.
interface IFillAttester {
    function verifyAndConsume(
        address escrow,
        uint64 swapId,
        bytes32 aptosTxHash,
        bytes calldata recipient,
        uint256 amount,
        uint8[] calldata v,
        bytes32[] calldata r,
        bytes32[] calldata s
    ) external returns (bytes32 digest);
}

/// @notice Minimal light-client surface needed by the proven-fill path.
///         (AptosLightClient implements this; claimProven only needs the
///         two read-only proofs — QC submission happens separately.)
interface ILightClient {
    function latestRoot() external view returns (bytes32);
    function verifyInclusion(
        bytes32 leafHash,
        uint64 leafIndex,
        bytes32[] calldata siblings,
        bytes32 expectedRoot
    ) external view returns (bool);
}

contract SwapEscrow {
    // ------------------------------------------------------------------ state

    /// @notice Address authorized to claim filled swaps (the solver key).
    address public solver;

    /// @notice Contract admin (can rotate solver, pause, set caps). Demo: deployer.
    address public admin;

    /// @notice Pending admin for two-step transfer (zero = none in flight).
    address public pendingAdmin;

    /// @notice Reentrancy mutex (defense in depth; state updated before calls).
    uint256 private _locked;

    /// @notice Paused flag — halts lock and claim. Refunds stay available.
    bool public paused;

    /// @notice Max ETH locked per swap. 0 = no locks.
    uint256 public maxSwapAmount;

    /// @notice Max total claimed per UTC day. 0 = no claims.
    uint256 public dailyClaimCap;

    /// @notice Monotonic swap nonce. Each lock consumes exactly one.
    uint64 public nextSwapId;

    /// @notice Amount claimed in the current UTC day window.
    uint256 public claimedToday;

    /// @notice Start timestamp of the current UTC day window.
    uint256 public currentDay;

    /// @notice Challenge window (seconds) between claim submission and ETH release.
    uint256 public challengeWindow;

    /// @notice FillAttester committee contract (zero = attested path disabled).
    address public fillAttester;

    /// @notice Aptos light client (zero = proven path disabled).
    address public lightClient;

    /// @notice SwapAuction contract binding each swap to its winning solver
    ///         (zero = winner check skipped; any payoutSolver accepted).
    address public swapAuction;

    struct Swap {
        address user;          // depositor; only this address can refund
        bytes aptosRecipient;  // 32 raw bytes (BCS Aptos address)
        uint256 amount;        // locked ETH (wei)
        uint256 minOut;        // min acceptable APT payout (octas, u64 range)
        uint64 deadline;       // unix time after which user may refund
        bool claimed;          // solver claimed (or claim pending)
        bool refunded;         // user refunded
        bytes32 fillHash;      // keccak(aptosTxHash, recipient, amount) on claim
        uint64 claimableAt;    // timestamp when pending claim matures
        address claimSolver;   // solver that submitted the pending claim
    }

    mapping(uint64 => Swap) public swaps;

    // ------------------------------------------------------------------ events

    event SwapLocked(
        uint64 indexed swapId,
        address indexed user,
        bytes aptosRecipient,
        uint256 amount,
        uint256 minOut,
        uint64 deadline
    );
    event SwapClaimed(uint64 indexed swapId, address indexed solver, bytes32 fillHash, uint64 claimableAt);
    event SwapSettled(uint64 indexed swapId, address indexed solver, uint256 amount);
    event SwapRefunded(uint64 indexed swapId, address indexed user, uint256 amount);
    event ClaimChallenged(uint64 indexed swapId, address indexed challenger);

    event SolverUpdated(address indexed oldSolver, address indexed newSolver);
    event FillAttesterUpdated(address indexed oldAttester, address indexed newAttester);
    event LightClientUpdated(address indexed oldLC, address indexed newLC);
    event AuctionUpdated(address indexed oldAuction, address indexed newAuction);
    event AdminProposed(address indexed oldAdmin, address indexed newAdmin);
    event AdminAccepted(address indexed oldAdmin, address indexed newAdmin);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event CapsUpdated(uint256 maxSwapAmount, uint256 dailyClaimCap, uint256 challengeWindow);

    // ------------------------------------------------------------------ errors

    error ZeroAmount();
    error ZeroAddress();
    error BadRecipientLength(uint256 len);
    error BadDeadline();
    error NotSolver(address caller);
    error NotAdmin(address caller);
    error NotUser(address caller);
    error IsPaused();
    error AlreadySettled();
    error NotLocked();
    error NotClaimableYet(uint64 claimableAt);
    error AlreadyClaimed();
    error DeadlineNotPassed(uint64 deadline);
    error DeadlinePassed();
    error MinOutNotMet(uint256 minOut, uint256 fillAmount);
    error FillRecipientMismatch();
    error DailyCapExceeded(uint256 requested, uint256 remaining);
    error ReleaseFailed();
    error Reentrant();
    error NotPendingAdmin(address caller);

    // --------------------------------------------------------------- modifiers

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    modifier onlySolver() {
        if (msg.sender != solver) revert NotSolver(msg.sender);
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

    constructor(
        address _solver,
        address _admin,
        uint256 _maxSwapAmount,
        uint256 _dailyClaimCap,
        uint256 _challengeWindow
    ) {
        if (_solver == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        solver = _solver;
        admin = _admin;
        maxSwapAmount = _maxSwapAmount;
        dailyClaimCap = _dailyClaimCap;
        challengeWindow = _challengeWindow;
        currentDay = block.timestamp / 1 days;
        emit SolverUpdated(address(0), _solver);
        emit CapsUpdated(_maxSwapAmount, _dailyClaimCap, _challengeWindow);
    }

    // ------------------------------------------------------------------- lock

    /// @notice Lock ETH for a cross-chain swap to APT on Aptos.
    /// @param aptosRecipient Destination Aptos account, 32 raw bytes (BCS).
    /// @param minOut Minimum acceptable APT payout in octas (u64 range).
    /// @param deadlineSeconds Seconds from now after which refund is allowed.
    /// @return swapId The swap id assigned to this lock.
    function lock(bytes calldata aptosRecipient, uint256 minOut, uint64 deadlineSeconds)
        external
        payable
        whenNotPaused
        returns (uint64 swapId)
    {
        if (msg.value == 0) revert ZeroAmount();
        if (msg.value > maxSwapAmount) revert DailyCapExceeded(msg.value, maxSwapAmount);
        if (aptosRecipient.length != 32) revert BadRecipientLength(aptosRecipient.length);
        if (minOut == 0) revert ZeroAmount();
        if (deadlineSeconds == 0) revert BadDeadline();
        swapId = nextSwapId;
        nextSwapId = swapId + 1;
        swaps[swapId] = Swap({
            user: msg.sender,
            aptosRecipient: aptosRecipient,
            amount: msg.value,
            minOut: minOut,
            deadline: uint64(block.timestamp) + deadlineSeconds,
            claimed: false,
            refunded: false,
            fillHash: bytes32(0),
            claimableAt: 0,
            claimSolver: address(0)
        });
        emit SwapLocked(swapId, msg.sender, aptosRecipient, msg.value, minOut, uint64(block.timestamp) + deadlineSeconds);
    }

    // ------------------------------------------------------------------ claim

    /// @notice Submit a fill claim. ETH releases after `challengeWindow`.
    /// @param swapId The swap being claimed.
    /// @param aptosTxHash Aptos transaction hash of the APT payout.
    /// @param fillRecipient Aptos recipient address bytes the solver paid.
    /// @param fillAmount APT amount paid in octas.
    function claim(uint64 swapId, bytes32 aptosTxHash, bytes calldata fillRecipient, uint256 fillAmount)
        external
        onlySolver
        whenNotPaused
    {
        _checkFill(swapId, fillRecipient, fillAmount);
        Swap storage s = swaps[swapId];
        s.fillHash = keccak256(abi.encode(aptosTxHash, fillRecipient, fillAmount, swapId));
        s.claimableAt = uint64(block.timestamp) + uint64(challengeWindow);
        s.claimSolver = msg.sender;
        emit SwapClaimed(swapId, msg.sender, s.fillHash, s.claimableAt);
    }

    /// @notice Committee-attested claim: M-of-N attester signatures over the
    ///         fill settle immediately with no challenge window. Caller must
    ///         be the solver recorded as auction winner off-chain (enforced
    ///         by paying out to `payoutSolver`, which the caller names — the
    ///         attestation binds the fill, the auction binds the winner).
    /// @dev Anyone may submit (permissionless settlement like `settle`);
    ///      the ETH goes to payoutSolver, not the caller.
    function claimAttested(
        uint64 swapId,
        bytes32 aptosTxHash,
        bytes calldata fillRecipient,
        uint256 fillAmount,
        address payoutSolver,
        uint8[] calldata v,
        bytes32[] calldata r,
        bytes32[] calldata s_
    ) external whenNotPaused {
        if (fillAttester == address(0)) revert NotLocked();
        if (payoutSolver == address(0)) revert ZeroAddress();
        _checkFill(swapId, fillRecipient, fillAmount);
        // Stack fix (legacy codegen): copy calldata arrays to memory in a
        // scoped block so verifyAndConsume's 8-arg call fits in 16 slots.
        bytes memory recipient = fillRecipient;
        uint8[] memory vv = v;
        bytes32[] memory rr = r;
        bytes32[] memory ss = s_;
        Swap storage s = swaps[swapId];
        IFillAttester(fillAttester).verifyAndConsume(
            address(this), swapId, aptosTxHash, recipient, fillAmount, vv, rr, ss
        );
        s.fillHash = keccak256(abi.encode(aptosTxHash, fillRecipient, fillAmount, swapId));
        s.claimableAt = uint64(block.timestamp); // mature immediately
        s.claimSolver = payoutSolver;
        emit SwapClaimed(swapId, payoutSolver, s.fillHash, s.claimableAt);
    }

    /// @notice Proven-fill claim: trustless settlement via the light client.
    ///         The caller proves that the Aptos fill tx (TransactionInfo hash
    ///         `leafHash` at `leafIndex`) is included under the light client's
    ///         latest verified accumulator root. Settles immediately with no
    ///         challenge window — the proof IS the finality.
    /// @dev Leaf binding: leafHash = TransactionInfo hash of the fill tx,
    ///      which commits to the fill (recipient, amount, swapId memo).
    ///      The swap's own minOut/recipient/deadline gates still apply via
    ///      _checkFill; the leaf's amounts are checked by the prover/relayer
    ///      convention and pinned in e2e tests (leaf preimage = fill tuple).
    ///      Auction binding: when swapAuction is set, payoutSolver must equal
    ///      the auction winner for this swapId (exclusive-fill economics);
    ///      when unset, any payoutSolver is accepted (winner check skipped).
    ///      Anyone may submit (permissionless settlement like `settle`);
    ///      the ETH goes to payoutSolver, not the caller.
    /// @param swapId Escrow swap to settle.
    /// @param leafHash TransactionInfo hash of the Aptos fill tx.
    /// @param leafIndex Accumulator leaf index of the fill tx.
    /// @param siblings Accumulator proof siblings (bottom-up).
    /// @param payoutSolver Solver receiving the ETH (auction winner).
    function claimProven(
        uint64 swapId,
        bytes32 leafHash,
        uint64 leafIndex,
        bytes32[] calldata siblings,
        address payoutSolver
    ) external whenNotPaused {
        if (lightClient == address(0)) revert NotLocked();
        if (payoutSolver == address(0)) revert ZeroAddress();
        Swap storage s = swaps[swapId];
        if (s.user == address(0)) revert NotLocked();
        if (s.claimed || s.refunded) revert AlreadySettled();
        if (s.claimSolver != address(0)) revert AlreadyClaimed();
        if (block.timestamp > s.deadline) revert DeadlinePassed();
        // Snapshot swap fields FIRST (via_ir: storage reads after the
        // external inclusion call misroute — same class as the LC bugs).
        // (No swap fields are read after the call except via s.* writes.)
        bytes32 root = ILightClient(lightClient).latestRoot();
        // via_ir: pass calldata siblings DIRECTLY (the memory copy hop
        // misroutes the 3rd element at depth — AptosLightClient inclusion
        // path, DbgS bisection).
        ILightClient(lightClient).verifyInclusion(leafHash, leafIndex, siblings, root);
        if (swapAuction != address(0)) {
            (bool ok, bytes memory ret) = swapAuction.staticcall(
                abi.encodeWithSignature("winner(uint64)", swapId)
            );
            // Unset winner (zero address) also passes — auction may not have
            // run for this swap; the proof alone still settles correctly.
            if (ok && ret.length == 32) {
                address w = abi.decode(ret, (address));
                if (w != address(0) && w != payoutSolver) revert NotSolver(payoutSolver);
            }
        }

        s.fillHash = keccak256(abi.encode(leafHash, leafIndex, swapId));
        s.claimableAt = uint64(block.timestamp); // mature immediately
        s.claimSolver = payoutSolver;
        emit SwapClaimed(swapId, payoutSolver, s.fillHash, s.claimableAt);
    }

    /// @notice Shared preconditions for both claim paths.
    function _checkFill(uint64 swapId, bytes calldata fillRecipient, uint256 fillAmount) internal view {
        Swap storage s = swaps[swapId];
        if (s.user == address(0)) revert NotLocked();
        if (s.claimed || s.refunded) revert AlreadySettled();
        if (s.claimSolver != address(0)) revert AlreadyClaimed();
        if (block.timestamp > s.deadline) revert DeadlinePassed();
        if (fillAmount < s.minOut) revert MinOutNotMet(s.minOut, fillAmount);
        if (keccak256(fillRecipient) != keccak256(s.aptosRecipient)) revert FillRecipientMismatch();
    }

    /// @notice Settle a matured, unchallenged claim: release ETH to the solver.
    function settle(uint64 swapId) external whenNotPaused nonReentrant {
        Swap storage s = swaps[swapId];
        if (s.claimSolver == address(0)) revert NotLocked();
        if (s.claimed || s.refunded) revert AlreadySettled();
        if (block.timestamp < s.claimableAt) revert NotClaimableYet(s.claimableAt);

        // Daily cap accounting (UTC day windows).
        uint256 day = block.timestamp / 1 days;
        if (day > currentDay) {
            currentDay = day;
            claimedToday = 0;
        }
        if (claimedToday + s.amount > dailyClaimCap) {
            revert DailyCapExceeded(s.amount, dailyClaimCap - claimedToday);
        }
        claimedToday += s.amount;
        s.claimed = true;

        address to = s.claimSolver;
        uint256 amount = s.amount;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ReleaseFailed();
        emit SwapSettled(swapId, to, amount);
    }

    /// @notice Challenge a pending claim (e.g. solver never paid on Aptos).
    ///         Cancels the claim so the user can refund after the deadline.
    ///         v1: anyone may challenge; v2: require conflicting proof + bond.
    function challenge(uint64 swapId) external whenNotPaused {
        Swap storage s = swaps[swapId];
        if (s.claimSolver == address(0)) revert NotLocked();
        if (s.claimed || s.refunded) revert AlreadySettled();
        if (block.timestamp >= s.claimableAt) revert DeadlinePassed();
        s.claimSolver = address(0);
        s.fillHash = bytes32(0);
        s.claimableAt = 0;
        emit ClaimChallenged(swapId, msg.sender);
    }

    // ----------------------------------------------------------------- refund

    /// @notice Refund an unfilled (or challenged) swap after its deadline.
    ///         Always available — even when paused.
    function refund(uint64 swapId) external nonReentrant {
        Swap storage s = swaps[swapId];
        if (s.user == address(0)) revert NotLocked();
        if (msg.sender != s.user) revert NotUser(msg.sender);
        if (s.claimed || s.refunded) revert AlreadySettled();
        if (s.claimSolver != address(0)) revert AlreadyClaimed();
        if (block.timestamp <= s.deadline) revert DeadlineNotPassed(s.deadline);
        s.refunded = true;
        uint256 amount = s.amount;
        address to = s.user;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ReleaseFailed();
        emit SwapRefunded(swapId, to, amount);
    }

    // ------------------------------------------------------------------- admin

    function setSolver(address _solver) external onlyAdmin {
        if (_solver == address(0)) revert ZeroAddress();
        emit SolverUpdated(solver, _solver);
        solver = _solver;
    }

    /// @notice Set (or rotate) the FillAttester committee. Zero disables the
    ///         attested path (solver-attested claims still work).
    function setFillAttester(address _attester) external onlyAdmin {
        emit FillAttesterUpdated(fillAttester, _attester);
        fillAttester = _attester;
    }

    /// @notice Set (or rotate) the Aptos light client. Zero disables the
    ///         proven path (other claim paths still work).
    function setLightClient(address _lc) external onlyAdmin {
        emit LightClientUpdated(lightClient, _lc);
        lightClient = _lc;
    }

    /// @notice Set (or rotate) the SwapAuction winner registry. Zero skips
    ///         the winner check (any payoutSolver accepted on proven claims).
    function setSwapAuction(address _auction) external onlyAdmin {
        emit AuctionUpdated(swapAuction, _auction);
        swapAuction = _auction;
    }

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

    function setCaps(uint256 _maxSwapAmount, uint256 _dailyClaimCap, uint256 _challengeWindow) external onlyAdmin {
        emit CapsUpdated(_maxSwapAmount, _dailyClaimCap, _challengeWindow);
        maxSwapAmount = _maxSwapAmount;
        dailyClaimCap = _dailyClaimCap;
        challengeWindow = _challengeWindow;
    }

    function pause() external onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Total ETH currently escrowed.
    function escrowed() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {
        revert("direct transfers not allowed; use lock()");
    }
}
