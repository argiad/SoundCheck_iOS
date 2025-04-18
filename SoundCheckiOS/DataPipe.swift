//
//  DataPipe.swift
//  SoundCheckiOS
//
//  Created by Artem Mkrtchyan on 3/12/25.
//

import Foundation

actor DataPipe {
    private var buffer = Data()

    /// Writes any size of data into the buffer
    func writeBytes(_ data: Data) {
        buffer.append(data)
    }

    /// Reads fixed-size chunks asynchronously
    func readBytes(count: Int) async -> Data? {
        while buffer.count < count {
            await Task.yield() // Yield execution until enough data is available
        }

        let chunk = buffer.prefix(count)
        buffer.removeFirst(count) // Trim buffer
        return chunk
    }

    /// **Resets the DataPipe (Clears buffer)**
    func reset() {
        buffer.removeAll()
    }
}
