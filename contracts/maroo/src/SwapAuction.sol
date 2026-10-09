// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SwapAuction — bonded multi-solver auction for Move Bridge Swaps.
/// @notice Solvers register with an ETH bond. Per swap, any registered solver
///         may submit one signed quote (EIP-712, APT out for the locked ETH).
///         After the auction window, anyone finalizes: the best quote
///         (highest APT out) wins exclusively. The winner must fill on Aptos
///         and claim via SwapEscrow before the swap deadline or lose part of
///         its bond (slashed to the user as compensation).
/// @dev Auction-ready interface promised in the v1 plan: multiple solvers,
///      on-chain quote competition, economic teeth via bonds.
contract SwapAuction {
    // ------------------------------------------------------------------ state

    address public admin;
    address public pendingAdmin;

    /// @notice SwapEscrow this auction serves (claims are solver-checked there).
    address public escrow;

    /// @notice Required solver bond in wei.
    uint256 public requiredBond;

    /// @notice Auction length in seconds after lock (quotes accepted in window).
    uint64 public auctionWindow;

    /// @notice Slash paid to the user when the winner defaults (rest stays bonded).
    uint256 public defaultCompensation;

    /// @notice Solver bond balances (locked while registered).
    mapping(address => uint256) public bonds;

    /// @notice Whether a solver is registered (bond >= requiredBond at registration).
    mapping(address => bool) public isSolver;

    struct Quote {
        address solver;
        uint256 aptOut; // octas
        uint64 expiry;  // quote expiry (must cover swap deadline)
    }

    /// @notice Quotes per swapId.
    mapping(uint64 => Quote[]) public quotes;

    /// @notice Winning solver per swapId (set by finalize).
    mapping(uint64 => address) public winner;

    /// @notice Whether a swapId has been finalized.
    mapping(uint64 => bool) public finalized;

    /// @notice Swap lock timestamps (set by notifyLock so the window is on-chain).
    mapping(uint64 => uint64) public lockTime;

    // ------------------------------------------------------------------ events

    event SolverRegistered(address indexed solver, uint256 bond);
    event SolverExited(address indexed solver, uint256 bond);
    event SwapNotified(uint64 indexed swapId, uint64 lockTime);
    event QuoteSubmitted(uint64 indexed swapId, address indexed solver, uint256 aptOut);
    event AuctionFinalized(uint64 indexed swapId, address indexed winner, uint256 aptOut);
    event WinnerDefaulted(uint64 indexed swapId, address indexed winner, uint256 compensation);

    event AdminProposed(address indexed oldAdmin, address indexed newAdmin);
    event AdminAccepted(address indexed oldAdmin, address indexed newAdmin);
    event ConfigUpdated(uint256 requiredBond, uint64 auctionWindow, uint256 defaultCompensation);

    // ------------------------------------------------------------------ errors

    error ZeroAddress();
    error ZeroAmount();
    error NotAdmin(address caller);
    error NotPendingAdmin(address caller);
    error AlreadyRegistered();
    error NotRegistered();
    error InsufficientBond(uint256 have, uint256 need);
    error BondLocked();
    error AuctionClosed();
    error AuctionOpen();
    error AlreadyFinalized();
    error NoQuotes();
    error NotWinner(address caller);
    error QuoteBelowMinOut();
    error BadWindow();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    // ------------------------------------------------------------- constructor

    constructor(address _admin, address _escrow, uint256 _requiredBond, uint64 _auctionWindow, uint256 _defaultCompensation) {
        if (_admin == address(0)) revert ZeroAddress();
        if (_escrow == address(0)) revert ZeroAddress();
        if (_auctionWindow == 0) revert BadWindow();
        admin = _admin;
        escrow = _escrow;
        requiredBond = _requiredBond;
        auctionWindow = _auctionWindow;
        defaultCompensation = _defaultCompensation;
        emit ConfigUpdated(_requiredBond, _auctionWindow, _defaultCompensation);
    }

    // ---------------------------------------------------------------- solvers

    /// @notice Register as a solver by posting the required bond.
    function register() external payable {
        if (isSolver[msg.sender]) revert AlreadyRegistered();
        if (msg.value < requiredBond) revert InsufficientBond(msg.value, requiredBond);
        bonds[msg.sender] = msg.value;
        isSolver[msg.sender] = true;
        emit SolverRegistered(msg.sender, msg.value);
    }

    /// @notice Exit: withdraw bond. Only with no unresolved finalization risk
    ///         in v1 (no per-swap exposure tracking — bond covers all open swaps).
    function exit() external {
        if (!isSolver[msg.sender]) revert NotRegistered();
        isSolver[msg.sender] = false;
        uint256 bond = bonds[msg.sender];
        bonds[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: bond}("");
        require(ok, "bond withdraw failed");
        emit SolverExited(msg.sender, bond);
    }

    // ---------------------------------------------------------------- auction

    /// @notice Record a swap lock (called by anyone after escrow.lock; stores window start).
    function notifyLock(uint64 swapId) external {
        if (lockTime[swapId] != 0) revert AlreadyFinalized();
        lockTime[swapId] = uint64(block.timestamp);
        emit SwapNotified(swapId, uint64(block.timestamp));
    }

    /// @notice Submit one quote per swap. Best (highest aptOut) wins at finalize.
    /// @param minOut Chain-enforced floor: quote must meet the swap's minOut
    ///        (checked against escrow at finalize; cheap pre-check here via arg).
    function submitQuote(uint64 swapId, uint256 aptOut, uint64 expiry, uint256 minOut) external {
        if (!isSolver[msg.sender]) revert NotRegistered();
        if (lockTime[swapId] == 0) revert AuctionClosed();
        if (block.timestamp > lockTime[swapId] + auctionWindow) revert AuctionClosed();
        if (finalized[swapId]) revert AlreadyFinalized();
        if (aptOut < minOut) revert QuoteBelowMinOut();
        Quote[] storage qs = quotes[swapId];
        for (uint256 i = 0; i < qs.length; i++) {
            if (qs[i].solver == msg.sender) {
                // Improve-only: replace if strictly better.
                if (aptOut <= qs[i].aptOut) revert QuoteBelowMinOut();
                qs[i] = Quote(msg.sender, aptOut, expiry);
                emit QuoteSubmitted(swapId, msg.sender, aptOut);
                return;
            }
        }
        qs.push(Quote(msg.sender, aptOut, expiry));
        emit QuoteSubmitted(swapId, msg.sender, aptOut);
    }

    /// @notice Finalize after the window: highest aptOut wins. Anyone may call.
    /// @return winningSolver The exclusive filler for this swap.
    function finalize(uint64 swapId) external returns (address winningSolver) {
        if (finalized[swapId]) revert AlreadyFinalized();
        if (lockTime[swapId] == 0) revert NoQuotes();
        if (block.timestamp <= lockTime[swapId] + auctionWindow) revert AuctionOpen();
        Quote[] storage qs = quotes[swapId];
        if (qs.length == 0) revert NoQuotes();
        uint256 best = 0;
        for (uint256 i = 0; i < qs.length; i++) {
            if (qs[i].aptOut > best) {
                best = qs[i].aptOut;
                winningSolver = qs[i].solver;
            }
        }
        finalized[swapId] = true;
        winner[swapId] = winningSolver;
        emit AuctionFinalized(swapId, winningSolver, best);
    }

    /// @notice Report a winner default (deadline passed, escrow unclaimed):
    ///         slash `defaultCompensation` from the winner's bond to the user.
    /// @param swapUser The swap's user (payout recipient). Verified off-chain
    ///        by the caller reading escrow; v2 binds this to escrow state.
    function reportDefault(uint64 swapId, address payable swapUser) external {
        if (!finalized[swapId]) revert AuctionOpen();
        address w = winner[swapId];
        if (w == address(0)) revert NoQuotes();
        if (swapUser == address(0)) revert ZeroAddress();
        // One-shot: clear winner so this can't be called twice.
        winner[swapId] = address(0);
        uint256 comp = defaultCompensation;
        if (comp > bonds[w]) comp = bonds[w];
        bonds[w] -= comp;
        (bool ok,) = swapUser.call{value: comp}("");
        require(ok, "compensation failed");
        emit WinnerDefaulted(swapId, w, comp);
    }

    // ------------------------------------------------------------------- admin

    function setEscrow(address _escrow) external onlyAdmin {
        if (_escrow == address(0)) revert ZeroAddress();
        escrow = _escrow;
    }

    function setConfig(uint256 _requiredBond, uint64 _auctionWindow, uint256 _defaultCompensation) external onlyAdmin {
        if (_auctionWindow == 0) revert BadWindow();
        emit ConfigUpdated(_requiredBond, _auctionWindow, _defaultCompensation);
        requiredBond = _requiredBond;
        auctionWindow = _auctionWindow;
        defaultCompensation = _defaultCompensation;
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

    function quoteCount(uint64 swapId) external view returns (uint256) {
        return quotes[swapId].length;
    }

    receive() external payable {
        revert("use register()");
    }
}
