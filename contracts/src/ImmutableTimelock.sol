// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title ImmutableTimelock
/// @notice A minimal timelock whose delay is `immutable` — it can never be shortened or removed,
///         and there is no instant path. Intended to OWN the {SumUSDEngine}: after the deployer
///         renounces, every parameter change (collateral listing, oracle swap, tilt slope) must be
///         queued and then wait `DELAY` before it can execute, giving SumUSD holders a guaranteed,
///         publicly-visible window to exit before any change lands.
///
/// @dev A compromised `executor` still cannot act faster than `DELAY` (no setDelay, no bypass), and a
///      separate, immutable `canceller` can VETO anything it queues inside that window — the delay alone
///      only gives holders notice, the canceller gives defenders a lever. Queued operations expire after
///      `GRACE_PERIOD` so a forgotten proposal cannot be executed years later against changed assumptions.
///      Renouncing the executor freezes the owned contract's parameters forever and is therefore itself
///      two-step and delayed.
contract ImmutableTimelock {
    /// @notice Mandatory wait between queuing and executing a call. Set once, immutable forever.
    uint256 public immutable DELAY;
    /// @notice How long a matured operation stays executable before it expires. Bounds the window in which
    ///         a stale, forgotten proposal could still land. Immutable.
    uint256 public immutable GRACE_PERIOD;
    /// @notice Account allowed to queue/execute/cancel (intended: a governance multisig).
    address public executor;
    /// @notice Cancel-only account (intended: the fast guardian multisig). It can veto any queued
    ///         operation but can never queue or execute one, so granting it costs no additional authority.
    ///         Immutable, because an executor able to remove the canceller instantly would defeat the point;
    ///         signer rotation happens inside the multisig, exactly as it does for `executor`.
    address public immutable CANCELLER;

    /// @notice Earliest execution timestamp per operation id; 0 means not queued.
    mapping(bytes32 id => uint256 eta) public eta;

    /// @notice Timestamp from which {renounceExecutor} may be called; 0 when no renounce is pending.
    uint256 public renounceEta;

    error NotExecutor();
    error NotCanceller();
    error AlreadyQueued();
    error NotReady();
    error Expired(uint256 readyAt, uint256 expiredAt);
    error CallFailed();
    error ZeroExecutor();
    error InvalidGracePeriod();
    error RenounceNotPending();

    event Queued(bytes32 indexed id, address indexed target, bytes data, uint256 eta);
    event Executed(bytes32 indexed id, address indexed target, bytes data);
    event Cancelled(bytes32 indexed id, address indexed by);
    event RenounceInitiated(uint256 eta);
    event RenounceAborted();
    event ExecutorRenounced();

    /// @param delaySeconds The immutable timelock delay (reference deployment: 96 hours).
    /// @param gracePeriod  How long a matured operation stays executable (reference: 14 days). Must be > 0.
    /// @param _executor    The initial executor (a multisig); cannot be the zero address.
    /// @param _canceller   Cancel-only veto account (intended: the guardian multisig). May be the zero
    ///                     address to disable the veto, though a production deployment should set it.
    constructor(uint256 delaySeconds, uint256 gracePeriod, address _executor, address _canceller) {
        if (_executor == address(0)) revert ZeroExecutor();
        if (gracePeriod == 0) revert InvalidGracePeriod();
        DELAY = delaySeconds;
        GRACE_PERIOD = gracePeriod;
        executor = _executor;
        CANCELLER = _canceller;
    }

    modifier onlyExecutor() {
        if (msg.sender != executor) revert NotExecutor();
        _;
    }

    /// @notice Deterministic id for a (target, data, salt) operation.
    function operationId(address target, bytes calldata data, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(target, data, salt));
    }

    /// @notice Queue a call. It cannot execute until `block.timestamp + DELAY`.
    function queue(address target, bytes calldata data, bytes32 salt) external onlyExecutor returns (bytes32 id) {
        id = operationId(target, data, salt);
        if (eta[id] != 0) revert AlreadyQueued();
        uint256 readyAt = block.timestamp + DELAY;
        eta[id] = readyAt;
        emit Queued(id, target, data, readyAt);
    }

    /// @notice Execute a previously-queued call once its delay has elapsed.
    function execute(address target, bytes calldata data, bytes32 salt)
        external
        onlyExecutor
        returns (bytes memory ret)
    {
        bytes32 id = operationId(target, data, salt);
        uint256 readyAt = eta[id];
        if (readyAt == 0 || block.timestamp < readyAt) revert NotReady();
        // A matured operation is executable only inside its grace window. Past that it must be re-queued,
        // so a proposal drafted against long-stale assumptions cannot simply be fired years later.
        uint256 expiresAt = readyAt + GRACE_PERIOD;
        if (block.timestamp > expiresAt) revert Expired(readyAt, expiresAt);
        eta[id] = 0;
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) revert CallFailed();
        emit Executed(id, target, data);
    }

    /// @notice Cancel a queued call before it executes. Callable by the executor OR by the cancel-only
    ///         {CANCELLER}, so a compromised executor's queued operation can still be vetoed inside the
    ///         delay window by an account that has no power to queue or execute anything itself.
    function cancel(address target, bytes calldata data, bytes32 salt) external {
        if (msg.sender != executor && msg.sender != CANCELLER) revert NotCanceller();
        bytes32 id = operationId(target, data, salt);
        if (eta[id] == 0) revert NotReady();
        eta[id] = 0;
        emit Cancelled(id, msg.sender);
    }

    /// @notice Begin renouncing the executor. Renouncing freezes the owned contract's parameters
    ///         permanently — including the ability to re-point a deprecated price feed — so it is
    ///         deliberately two-step and waits the full `DELAY`, exactly like any other change. Publicly
    ///         visible for the whole window, and abortable via {abortRenounce}.
    function initiateRenounce() external onlyExecutor {
        renounceEta = block.timestamp + DELAY;
        emit RenounceInitiated(renounceEta);
    }

    /// @notice Abort a pending renounce.
    function abortRenounce() external onlyExecutor {
        if (renounceEta == 0) revert RenounceNotPending();
        renounceEta = 0;
        emit RenounceAborted();
    }

    /// @notice Complete the renounce once its delay has elapsed. After this, no call can ever be queued or
    ///         executed again, freezing the owned contract's parameters permanently.
    function renounceExecutor() external onlyExecutor {
        if (renounceEta == 0) revert RenounceNotPending();
        if (block.timestamp < renounceEta) revert NotReady();
        renounceEta = 0;
        executor = address(0);
        emit ExecutorRenounced();
    }
}
