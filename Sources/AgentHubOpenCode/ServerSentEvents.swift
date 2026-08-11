import Foundation

struct ServerSentEvent: Equatable, Sendable {
    let event: String?
    let data: Data
}

struct ServerSentEventParser: Sendable {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [ServerSentEvent] {
        buffer.append(data)
        var events: [ServerSentEvent] = []
        while let boundary = frameBoundary(in: buffer) {
            let frame = Data(buffer[..<boundary.range.lowerBound])
            buffer.removeSubrange(..<boundary.range.upperBound)
            if let event = parse(frame) {
                events.append(event)
            }
        }
        return events
    }

    private func frameBoundary(in data: Data) -> (range: Range<Data.Index>, length: Int)? {
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                let next = data.index(after: index)
                if next < data.endIndex, data[next] == 0x0A {
                    return (index..<data.index(after: next), 2)
                }
            }
            if data[index] == 0x0D {
                let lf = data.index(after: index)
                if lf < data.endIndex, data[lf] == 0x0A {
                    let secondCR = data.index(after: lf)
                    if secondCR < data.endIndex, data[secondCR] == 0x0D {
                        let secondLF = data.index(after: secondCR)
                        if secondLF < data.endIndex, data[secondLF] == 0x0A {
                            return (index..<data.index(after: secondLF), 4)
                        }
                    }
                }
            }
            index = data.index(after: index)
        }
        return nil
    }

    private func parse(_ frame: Data) -> ServerSentEvent? {
        var eventName: String?
        var dataLines: [Data] = []
        for rawLine in frame.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var line = Data(rawLine)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty, line.first != 0x3A else { continue }

            let parts = line.split(separator: 0x3A, maxSplits: 1, omittingEmptySubsequences: false)
            let field = String(decoding: parts[0], as: UTF8.self)
            var value = parts.count == 2 ? Data(parts[1]) : Data()
            if value.first == 0x20 { value.removeFirst() }
            switch field {
            case "event":
                eventName = String(decoding: value, as: UTF8.self)
            case "data":
                dataLines.append(value)
            default:
                continue
            }
        }
        guard !dataLines.isEmpty else { return nil }
        var joined = Data()
        for (index, line) in dataLines.enumerated() {
            if index > 0 { joined.append(0x0A) }
            joined.append(line)
        }
        return ServerSentEvent(event: eventName, data: joined)
    }
}
