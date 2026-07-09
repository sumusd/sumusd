// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title ImmutableTimelock
/// @notice A minimal timelock whose delay is `immutable` — it can never be shortened or removed,
///         and there is no instant path. Intended to OWN the {SumUSDEngine}: after the deployer
///         renounces, every parameter change (collateral listing, oracle swap, tilt slope) must be
///         queued and then wait `DELAY` before it can execute, giving SumUSD holders a guaranteed,
///         publicly-visible window to exit before any change lands.
///
/// @dev A compromised `executor` still cannot act faster than `DELAY` (no setDelay, no bypass).
///      Calling {renounceExecutor} freezes the owned contract's parameters forever.
contract ImmutableTimelock {
    /// @notice Mandatory wait between queuing and executing a call. Set once, immutable forever.
    uint256 public immutable DELAY;
    /// @notice Account allowed to queue/execute/cancel (intended: a governance multisig).
    address public executor;

    /// @notice Earliest execution timestamp per operation id; 0 means not queued.
    mapping(bytes32 id => uint256 eta) public eta;

    error NotExecutor();
    error AlreadyQueued();
    error NotReady();
    error CallFailed();
    error ZeroExecutor();

    event Queued(bytes32 indexed id, address indexed target, bytes data, uint256 eta);
    event Executed(bytes32 indexed id, address indexed target, bytes data);
    event Cancelled(bytes32 indexed id);
    event ExecutorRenounced();

    /// @param delaySeconds The immutable timelock delay (e.g. 48 hours).
    /// @param _executor    The initial executor (a multisig); cannot be the zero address.
    constructor(uint256 delaySeconds, address _executor) {
        if (_executor == address(0)) revert ZeroExecutor();
        DELAY = delaySeconds;
        executor = _executor;
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
        eta[id] = 0;
        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) revert CallFailed();
        emit Executed(id, target, data);
    }

    /// @notice Cancel a queued call before it executes.
    function cancel(address target, bytes calldata data, bytes32 salt) external onlyExecutor {
        bytes32 id = operationId(target, data, salt);
        if (eta[id] == 0) revert NotReady();
        eta[id] = 0;
        emit Cancelled(id);
    }

    /// @notice Renounce the executor — after this, no call can ever be queued or executed again,
    ///         freezing the owned contract's parameters permanently.
    function renounceExecutor() external onlyExecutor {
        executor = address(0);
        emit ExecutorRenounced();
    }
}
