/*
Binary layout for configuration packets sent over the opaque message channel:

  Offset  Size  Type     Field
  ------  ----  ------   -----
  0       2     UInt16   magic = 0x4346 ("CF")
  2       4     UInt32   jsonLength (little-endian)
  6       N     bytes    JSON payload (UTF-8)

C/C++ reference:

  #pragma pack(push, 1)
  typedef struct {
      uint16_t magic;       // 0x4346
      uint32_t jsonLength;  // little-endian byte count of trailing JSON
  } StreamConfigPacketHeader;  // 6 bytes, followed by jsonLength bytes of UTF-8 JSON
  #pragma pack(pop)
*/

import Foundation

#if !targetEnvironment(simulator)
import FoveatedStreaming

enum ServerConfigurationError: LocalizedError {
    case noReadyChannel

    var errorDescription: String? {
        switch self {
        case .noReadyChannel:
            "No message channel available for sending configuration"
        }
    }
}

@MainActor
final class ServerConfigurationManager {
    /// Magic number prefix for configuration packets: "CF" in ASCII.
    static let magic: UInt16 = 0x4346

    /// Clear XR's channel, which also carries the controller packets; the PC layer tells them
    /// apart by their magic number.
    static let channelID = FoveatedStreamingSession.MessageChannel.ID(ControllerBridgeProtocol.channelUUID)

    func sendConfiguration(_ payload: StreamConfigurationMessage, via channelModel: MessageChannelModel) throws {
        // Find the ready channel, refreshing if needed.
        var channel = channelModel.availableChannels[Self.channelID].flatMap { $0.channelStatus == .ready ? $0 : nil }
        if channel == nil {
            channelModel.refreshChannels()
            channel = channelModel.availableChannels[Self.channelID].flatMap { $0.channelStatus == .ready ? $0 : nil }
        }

        guard let channel else {
            throw ServerConfigurationError.noReadyChannel
        }

        let jsonData = try JSONEncoder().encode(payload)

        var frame = Data(capacity: 2 + 4 + jsonData.count)
        // Magic number prefix
        withUnsafeBytes(of: Self.magic.littleEndian) { frame.append(contentsOf: $0) }
        // JSON payload length
        withUnsafeBytes(of: UInt32(jsonData.count).littleEndian) { frame.append(contentsOf: $0) }
        // JSON payload
        frame.append(jsonData)

        print("[ServerConfig] Sending configuration via message channel: \(jsonData.count) bytes JSON")
        try channel.sendMessage(frame)
    }
}
#endif
