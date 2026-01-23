// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @title LZEndpointMock
/// @notice Deployable LayerZero V2 endpoint mock for testing
/// @dev Self-contained - no LayerZero library dependencies for deployment
contract LZEndpointMock is Ownable {
    // ============ Structs (mirror LayerZero V2 types) ============

    struct MessagingParams {
        uint32 dstEid;
        bytes32 receiver;
        bytes message;
        bytes options;
        bool payInLzToken;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    struct Origin {
        uint32 srcEid;
        bytes32 sender;
        uint64 nonce;
    }

    struct StoredMessage {
        Origin origin;
        bytes32 guid;
        address receiver;
        bytes message;
        bool delivered;
    }

    // ============ State ============

    uint32 public immutable eid;
    uint64 public nonce;

    /// @notice Configurable fee for quote/send operations
    uint256 public mockNativeFee = 0.001 ether;
    uint256 public mockLzTokenFee = 0;

    /// @notice Registered delegates for OApps
    mapping(address oapp => address delegate) public delegates;

    /// @notice Stored messages for manual delivery
    StoredMessage[] public storedMessages;

    /// @notice Mapping of OApp to peer on remote chain
    mapping(address oapp => mapping(uint32 eid => bytes32 peer)) public peers;

    // ============ Events ============

    event MessageSent(
        bytes32 indexed guid,
        uint64 nonce,
        uint32 dstEid,
        address sender,
        bytes32 receiver,
        bytes message,
        bytes options,
        uint256 nativeFee
    );

    event MessageDelivered(
        bytes32 indexed guid,
        uint32 srcEid,
        address receiver
    );

    event DelegateSet(address indexed sender, address indexed delegate);

    event PacketSent(bytes encodedPacket, bytes options, address sendLibrary);

    // ============ Errors ============

    error LZEndpointMock__InvalidMessageIndex();
    error LZEndpointMock__MessageAlreadyDelivered();
    error LZEndpointMock__InsufficientFee(uint256 required, uint256 provided);
    error LZEndpointMock__LzReceiveFailed(bytes reason);

    // ============ Constructor ============

    constructor(uint32 _eid) Ownable(msg.sender) {
        eid = _eid;
    }

    // ============ Configuration ============

    /// @notice Set the mock fee returned by quote()
    function setMockFee(uint256 _nativeFee, uint256 _lzTokenFee) external onlyOwner {
        mockNativeFee = _nativeFee;
        mockLzTokenFee = _lzTokenFee;
    }

    // ============ Core Functions ============

    /// @notice Quote the fee for sending a message
    function quote(
        MessagingParams calldata,
        address
    ) external view returns (MessagingFee memory) {
        return MessagingFee(mockNativeFee, mockLzTokenFee);
    }

    /// @notice Send a message to a destination chain
    function send(
        MessagingParams calldata _params,
        address _refundAddress
    ) external payable returns (MessagingReceipt memory) {
        if (msg.value < mockNativeFee) {
            revert LZEndpointMock__InsufficientFee(mockNativeFee, msg.value);
        }

        nonce++;
        bytes32 guid = _generateGUID(nonce, eid, msg.sender, _params.dstEid, _params.receiver);

        // Store the message for manual delivery
        storedMessages.push(StoredMessage({
            origin: Origin({
                srcEid: eid,
                sender: _addressToBytes32(msg.sender),
                nonce: nonce
            }),
            guid: guid,
            receiver: _bytes32ToAddress(_params.receiver),
            message: _params.message,
            delivered: false
        }));

        emit MessageSent(
            guid,
            nonce,
            _params.dstEid,
            msg.sender,
            _params.receiver,
            _params.message,
            _params.options,
            msg.value
        );

        // Emit PacketSent for compatibility
        emit PacketSent(
            abi.encodePacked(nonce, eid, msg.sender, _params.dstEid, _params.receiver, guid, _params.message),
            _params.options,
            address(this)
        );

        // Refund excess
        if (msg.value > mockNativeFee) {
            (bool success,) = _refundAddress.call{value: msg.value - mockNativeFee}("");
            require(success, "Refund failed");
        }

        return MessagingReceipt({
            guid: guid,
            nonce: nonce,
            fee: MessagingFee(mockNativeFee, mockLzTokenFee)
        });
    }

    /// @notice Manually deliver a stored message to simulate cross-chain receipt
    /// @param _index The index of the stored message to deliver
    function deliverMessage(uint256 _index) external payable {
        if (_index >= storedMessages.length) revert LZEndpointMock__InvalidMessageIndex();
        StoredMessage storage stored = storedMessages[_index];
        if (stored.delivered) revert LZEndpointMock__MessageAlreadyDelivered();

        stored.delivered = true;

        // Call lzReceive on the receiver
        (bool success, bytes memory returnData) = stored.receiver.call{value: msg.value}(
            abi.encodeWithSignature(
                "lzReceive((uint32,bytes32,uint64),bytes32,bytes,address,bytes)",
                stored.origin,
                stored.guid,
                stored.message,
                msg.sender,
                ""
            )
        );

        if (!success) {
            revert LZEndpointMock__LzReceiveFailed(returnData);
        }

        emit MessageDelivered(stored.guid, stored.origin.srcEid, stored.receiver);
    }

    /// @notice Directly call lzReceive on a receiver (for testing inbound messages)
    /// @dev This is the main function for simulating incoming cross-chain messages
    function mockLzReceive(
        address _receiver,
        uint32 _srcEid,
        bytes32 _sender,
        uint64 _nonce,
        bytes32 _guid,
        bytes calldata _message
    ) external payable {
        Origin memory origin = Origin({
            srcEid: _srcEid,
            sender: _sender,
            nonce: _nonce
        });

        (bool success, bytes memory returnData) = _receiver.call{value: msg.value}(
            abi.encodeWithSignature(
                "lzReceive((uint32,bytes32,uint64),bytes32,bytes,address,bytes)",
                origin,
                _guid,
                _message,
                msg.sender,
                ""
            )
        );

        if (!success) {
            revert LZEndpointMock__LzReceiveFailed(returnData);
        }

        emit MessageDelivered(_guid, _srcEid, _receiver);
    }

    /// @notice Set delegate for an OApp
    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
        emit DelegateSet(msg.sender, _delegate);
    }

    // ============ View Functions ============

    /// @notice Get the number of stored messages
    function getStoredMessageCount() external view returns (uint256) {
        return storedMessages.length;
    }

    /// @notice Get a stored message by index
    function getStoredMessage(uint256 _index) external view returns (
        Origin memory origin,
        bytes32 guid,
        address receiver,
        bytes memory message,
        bool delivered
    ) {
        StoredMessage storage stored = storedMessages[_index];
        return (stored.origin, stored.guid, stored.receiver, stored.message, stored.delivered);
    }

    /// @notice Get next GUID for a send operation
    function nextGuid(address _sender, uint32 _dstEid, bytes32 _receiver) external view returns (bytes32) {
        return _generateGUID(nonce + 1, eid, _sender, _dstEid, _receiver);
    }

    // ============ Helpers ============

    function _generateGUID(
        uint64 _nonce,
        uint32 _srcEid,
        address _sender,
        uint32 _dstEid,
        bytes32 _receiver
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_nonce, _srcEid, _sender, _dstEid, _receiver));
    }

    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    function _bytes32ToAddress(bytes32 _b) internal pure returns (address) {
        return address(uint160(uint256(_b)));
    }

    /// @notice Helper to convert address to bytes32 (for setting peers)
    function addressToBytes32(address _addr) external pure returns (bytes32) {
        return _addressToBytes32(_addr);
    }

    /// @notice Helper to convert bytes32 to address
    function bytes32ToAddress(bytes32 _b) external pure returns (address) {
        return _bytes32ToAddress(_b);
    }

    // ============ Receive ETH ============

    receive() external payable {}
}
