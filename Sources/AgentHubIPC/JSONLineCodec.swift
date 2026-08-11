import Foundation
@preconcurrency import NIOCore

enum JSONLineCodec {
    static let maximumFrameBytes = 1_024 * 1_024

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        var data = try JSONEncoder.agentHub.encode(value)
        guard data.count <= maximumFrameBytes else { throw IPCError.oversizedFrame }
        data.append(0x0A)
        return data
    }

    static func validate(protocolVersion: Int) throws {
        guard protocolVersion == agentHubIPCProtocolVersion else {
            throw IPCError.unsupportedProtocolVersion(protocolVersion)
        }
    }
}

final class JSONLineFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    func decode(
        context: ChannelHandlerContext,
        buffer: inout ByteBuffer
    ) throws -> DecodingState {
        let newlineOffset = buffer.withUnsafeReadableBytes { bytes in
            bytes.firstIndex(of: 0x0A)
        }

        guard let newlineOffset else {
            guard buffer.readableBytes <= JSONLineCodec.maximumFrameBytes else {
                throw IPCError.oversizedFrame
            }
            return .needMoreData
        }
        guard newlineOffset <= JSONLineCodec.maximumFrameBytes else {
            throw IPCError.oversizedFrame
        }
        guard let frame = buffer.readSlice(length: newlineOffset) else {
            return .needMoreData
        }
        buffer.moveReaderIndex(forwardBy: 1)
        context.fireChannelRead(wrapInboundOut(frame))
        return .continue
    }
}

extension ByteBuffer {
    mutating func writeJSONLine(_ data: Data) {
        writeBytes(data)
    }

    mutating func readData() -> Data {
        Data(readBytes(length: readableBytes) ?? [])
    }
}
