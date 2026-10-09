// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title FillAttester — committee verification for Move Bridge Swap fills.
/// @notice Replaces single-solver attestation: a fill is proven by M-of-N
///         attester signatures over an EIP-712 `Fill` struct binding
///         (chainId, escrow, swapId, aptosTxHash, recipient, amount).
///         SwapEscrow consults this contract on claim: claims carrying a
///         valid attestation skip (or shorten) the challenge window; the
///         committee is the production-standard trust shape (Wormhole
///         guardians / LZ DVNs / CCIP DONs at demo scale).
/// @dev Inline EIP-712 + ecrecover (no OZ dependency — offline build).
///      Attester set managed by admin with two-step rotation per member.
contract FillAttester {
    // ------------------------------------------------------------- EIP-712 domain

    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant FILL_TYPEHASH =
        keccak256("Fill(address escrow,uint64 swapId,bytes32 aptosTxHash,bytes recipient,uint256 amount)");

    bytes32 public immutable DOMAIN_SEPARATOR;

    // ------------------------------------------------------------------ state

    address public admin;
    address public pendingAdmin;

    /// @notice Current attesters.
    address[] public attesters;

    /// @notice Attester membership (for O(1) checks).
    mapping(address => bool) public isAttester;

    /// @notice Required signatures (M of N).
    uint256 public threshold;

    /// @notice Consumed fill digests (replay guard across swaps and chains).
    mapping(bytes32 => bool) public consumed;

    // ------------------------------------------------------------------ events

    event AttesterAdded(address indexed attester);
    event AttesterRemoved(address indexed attester);
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event FillVerified(uint64 indexed swapId, bytes32 indexed digest, uint256 sigCount);
    event AdminProposed(address indexed oldAdmin, address indexed newAdmin);
    event AdminAccepted(address indexed oldAdmin, address indexed newAdmin);

    // ------------------------------------------------------------------ errors

    error ZeroAddress();
    error NotAdmin(address caller);
    error NotPendingAdmin(address caller);
    error AlreadyAttester(address a);
    error NotAttester(address a);
    error BadThreshold();
    error ThresholdExceedsSet();
    error InsufficientSignatures(uint256 have, uint256 need);
    error BadSignature();
    error AlreadyConsumed(bytes32 digest);
    error EmptySet();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    // ------------------------------------------------------------- constructor

    constructor(address _admin, address[] memory _attesters, uint256 _threshold) {
        if (_admin == address(0)) revert ZeroAddress();
        if (_attesters.length == 0) revert EmptySet();
        if (_threshold == 0 || _threshold > _attesters.length) revert BadThreshold();
        admin = _admin;
        threshold = _threshold;
        for (uint256 i = 0; i < _attesters.length; i++) {
            if (_attesters[i] == address(0)) revert ZeroAddress();
            if (isAttester[_attesters[i]]) revert AlreadyAttester(_attesters[i]);
            isAttester[_attesters[i]] = true;
            attesters.push(_attesters[i]);
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                TYPE_HASH,
                keccak256("MoveBridgeFillAttester"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        emit ThresholdUpdated(0, _threshold);
    }

    // ---------------------------------------------------------------- verify

    /// @notice EIP-712 hash of a Fill attestation.
    function fillDigest(address escrow, uint64 swapId, bytes32 aptosTxHash, bytes calldata recipient, uint256 amount)
        public
        view
        returns (bytes32)
    {
        return _digest(escrow, swapId, aptosTxHash, keccak256(recipient), amount);
    }

    function _structHash(address escrow, uint64 swapId, bytes32 aptosTxHash, bytes32 recipientHash, uint256 amount)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(FILL_TYPEHASH, escrow, swapId, aptosTxHash, recipientHash, amount));
    }

    function _digest(address escrow, uint64 swapId, bytes32 aptosTxHash, bytes32 recipientHash, uint256 amount)
        internal
        view
        returns (bytes32)
    {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _structHash(escrow, swapId, aptosTxHash, recipientHash, amount)));
    }

    /// @notice Verify M-of-N attester signatures and consume the digest.
    /// @dev Signatures must be sorted by ascending signer address — this
    ///      gives duplicate detection with one local (stack-safe) and saves
    ///      gas over an O(n^2) scan. Off-chain: sort before submitting.
    /// @return digest The consumed attestation hash (for escrow binding).
    function verifyAndConsume(
        address escrow,
        uint64 swapId,
        bytes32 aptosTxHash,
        bytes calldata recipient,
        uint256 amount,
        uint8[] calldata v,
        bytes32[] calldata r,
        bytes32[] calldata s
    ) external returns (bytes32 digest) {
        uint256 n = v.length;
        if (n != r.length || n != s.length) revert BadSignature();
        if (n < threshold) revert InsufficientSignatures(n, threshold);
        digest = _digest(escrow, swapId, aptosTxHash, keccak256(recipient), amount);
        if (consumed[digest]) revert AlreadyConsumed(digest);
        consumed[digest] = true;
        _checkSigs(digest, v, r, s, n);
        emit FillVerified(swapId, digest, n);
    }

    /// @notice ecrecover loop split out (legacy-codegen stack depth).
    function _checkSigs(bytes32 digest, uint8[] calldata v, bytes32[] calldata r, bytes32[] calldata s, uint256 n)
        private
        view
    {
        address prev = address(0);
        for (uint256 i = 0; i < n; i++) {
            address signer = ecrecover(digest, v[i], r[i], s[i]);
            if (signer <= prev || !isAttester[signer]) revert BadSignature();
            prev = signer;
        }
    }

    // ------------------------------------------------------------------- admin

    function addAttester(address a) external onlyAdmin {
        if (a == address(0)) revert ZeroAddress();
        if (isAttester[a]) revert AlreadyAttester(a);
        isAttester[a] = true;
        attesters.push(a);
        emit AttesterAdded(a);
    }

    function removeAttester(address a) external onlyAdmin {
        if (!isAttester[a]) revert NotAttester(a);
        if (attesters.length - 1 < threshold) revert ThresholdExceedsSet();
        isAttester[a] = false;
        for (uint256 i = 0; i < attesters.length; i++) {
            if (attesters[i] == a) {
                attesters[i] = attesters[attesters.length - 1];
                attesters.pop();
                break;
            }
        }
        emit AttesterRemoved(a);
    }

    function setThreshold(uint256 t) external onlyAdmin {
        if (t == 0 || t > attesters.length) revert BadThreshold();
        emit ThresholdUpdated(threshold, t);
        threshold = t;
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

    function attesterCount() external view returns (uint256) {
        return attesters.length;
    }
}
