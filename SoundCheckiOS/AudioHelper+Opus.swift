//
//  AudioHelper+Opus.swift
//  SoundCheckiOS
//
//  Created by Artem Mkrtchyan on 3/11/25.
//

import Combine
import AVFoundation
import Opus

extension AudioHelper {
    
    func initiateNetworkWorker(serverUrl: String, authToken: String){
        
        guard let url = URL(string: serverUrl) else {
            print("Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("chunked", forHTTPHeaderField: "Transfer-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = session.uploadTask(withStreamedRequest: request)
        
        task?.resume()
    }
    
    // MARK: - Setup for Recording
    func setupRecording() {
        stopAudioSession() // Ensure clean session before reconfiguring

        do {
            print("🎙 Setting up AVAudioSession for Recording...")
            opusSession = AVAudioSession.sharedInstance()
            try opusSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try opusSession.setActive(true, options: .notifyOthersOnDeactivation)
            try opusSession.setPreferredInputNumberOfChannels(1)
            try opusSession.setPreferredOutputNumberOfChannels(1)

            audioEngine = AVAudioEngine()
            inputNode = audioEngine.inputNode

            let inputFormat = AVAudioFormat(standardFormatWithSampleRate: OPUS_ENCODER_SAMPLE_RATE, channels: 1)!

            encoder = try Opus.Encoder(format: inputFormat, application: .voip)

            audioEngine.prepare()
            try audioEngine.start()
            print("✅ Recording setup complete.")
        } catch {
            print("❌ Failed to setup recording: \(error.localizedDescription)")
        }
    }

    // MARK: - Stop Recording
    func stopOpusRecording() {
        print("🛑 Stopping recording...")
        audioEngine?.stop()
        inputNode?.removeTap(onBus: 0)
        stopAudioSession()
        print("✅ Recording stopped.")
        // Notify delegate
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.recordingStopped()
        }
    }

    // MARK: - Setup for Playback
    func setupPlayback() {
        stopAudioSession() // Ensure clean session before reconfiguring

        do {
            print("🔊 Setting up AVAudioSession for Playback...")
            opusSession = AVAudioSession.sharedInstance()
            try opusSession.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try opusSession.setActive(true, options: .notifyOthersOnDeactivation)

            audioEngine = AVAudioEngine()
            opusPlayerNode = AVAudioPlayerNode()
            audioEngine.attach(opusPlayerNode)

            let outputFormat = AVAudioFormat(standardFormatWithSampleRate: AUDIO_OUTPUT_SAMPLE_RATE, channels: AUDIO_OUTPUT_CHANNELS)!
            audioEngine.connect(opusPlayerNode, to: audioEngine.mainMixerNode, format: outputFormat)

            decoder = try Opus.Decoder(format: outputFormat, application: .voip)

            audioEngine.prepare()
            try audioEngine.start()
            print("✅ Playback setup complete.")
        } catch {
            print("❌ Failed to setup playback: \(error.localizedDescription)")
        }
    }

    // MARK: - Stop Playback
    func stopOpusPlayback() {
        print("🛑 Stopping playback...")
        opusPlayerNode.stop()
        audioEngine?.stop()
        stopAudioSession()
        cancellable?.cancel()
        cancellable = nil
        readQueue = DispatchQueue(label: "audio.read.queue", qos: .userInitiated)
        print("✅ Playback stopped.")
        // Notify delegate
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.playbackDone()
        }
    }

    // MARK: - Stop & Reset Audio Session
    private func stopAudioSession() {
        do {
            print("🔄 Resetting AVAudioSession...")
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            print("✅ AVAudioSession reset.")
        } catch {
            print("❌ Error resetting AVAudioSession: \(error.localizedDescription)")
        }
    }
    
    
    func startOpusRecording(serverUrl: String, authToken: String) {
        initiateNetworkWorker(serverUrl: serverUrl, authToken: authToken)

        do {
            let inputFormat = AVAudioFormat(standardFormatWithSampleRate: OPUS_ENCODER_SAMPLE_RATE, channels: 1)!
            let desiredBufferSize = AVAudioFrameCount((Double(OPUS_ENCODER_DURATION_MS) / 1000.0) * OPUS_ENCODER_SAMPLE_RATE)
            
            inputNode.installTap(onBus: 0, bufferSize: desiredBufferSize, format: inputFormat) { [weak self] buffer, _ in
                self?.processBuffer(buffer)
            }
            
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            // Notify delegate
            DispatchQueue.main.async {
                self.delegate?.recordingStarted()
            }
        } catch {
            print("Recording start error: \(error)")
        }
    }
    
    private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let encoder = encoder else { return }
        
        do {
            var encodedData = Data(count: Int(buffer.frameLength) * MemoryLayout<Float32>.size)
            _ = try encoder.encode(buffer, to: &encodedData)
            self.opusBufferData.append(encodedData)
            self.sendAudioData (encodedData)
            print("buffer size before encode \(buffer.frameLength) and encoded: \(encodedData.count) 4 first elements: \(Data(encodedData.prefix(4)).base64EncodedString())")
            //            print("total buffer size: \(self.opusBufferData.count)")
        } catch {
            print("Failed to encode buffer: \(error.localizedDescription)")
        }
    }
    
    
    func setupReceivingStream() {
        let streamPipe = createStreamPipe()
        opusOutputStream = streamPipe.output
        opusOutputStream?.schedule(in: .current, forMode: .default)
        opusOutputStream?.open()
        opusInputStream = streamPipe.input
        opusInputStream?.open()
    }
    
    private func decodePackets() -> [AVAudioPCMBuffer] {
        var decodedBuffers: [AVAudioPCMBuffer] = []
        
        for packet in opusBufferData {
            print("debug data before decode,  data size: \(packet.count)")
            guard let decoder = decoder else { continue }
            do {
                let decodedBuffer = try decoder.decode(packet)
                decodedBuffers.append(decodedBuffer)
            } catch {
                print("Failed to decode packet: \(error.localizedDescription)")
            }
        }
        
        return decodedBuffers
    }
    
    private func scheduleBuffersForPlayback(_ buffers: [AVAudioPCMBuffer]) {
            guard !buffers.isEmpty else {
                print("buffers empty")
               return
            }
            
            for (index, buffer) in buffers.enumerated() {
                print("debug data \(index)")
                if index == buffers.count - 1 {
                    // For the last buffer, use scheduleBuffer(completionHandler:)
                    opusPlayerNode.scheduleBuffer(buffer) {
                        DispatchQueue.main.async {
                            self.opusBufferData.removeAll()
                            self.delegate?.playbackDone()
                        }
                    }
                } else {
                    opusPlayerNode.scheduleBuffer(buffer)
                }
            }
        }
    
    
    // MARK: -- opus read from Stream
    func readOpusPacketsFromStream() {
        setupReading()
        readFromStream(mInputStream: opusInputStream!)
    }
    
    private func setupReading(){
        cancellable = streamSubject
             .sink { [weak self] packets in
                 print("321312312")
                 self?.processPackets(packets)
             }
    }
    
    
    private func readFromStream(mInputStream: InputStream) {
        print("✅ readFromStream")
        readQueue.async {
            var readBuffer = [UInt8](repeating: 0, count: self.readBufferSize)

            while true {
                while mInputStream.hasBytesAvailable {
                    let bytesRead = mInputStream.read(&readBuffer, maxLength: self.readBufferSize)
                    print("Bytes read: \(bytesRead)")
                    if bytesRead > 0 {
                        self.streamSubject.send(Data(readBuffer.prefix(bytesRead)))
                    } else {
                        break
                    }
                }
            }
        }
    }

    private func processPackets(_ packets: Data) {
        opusBuffer += packets
        var bytesRead = opusBuffer.count
        var buffer = Data()
//        var readBuffer = [UInt8](repeating: 0, count: bytesRead)
        
        if bytesRead > 0 {
            
            // ✅ Process each byte one by one
            for i in 0..<bytesRead {
                let byte = opusBuffer[i]
                buffer.append(byte)
                
                // ✅ Check if we found the marker
                if buffer.suffix(2) == Data(marker) {
                    if collecting {
                        // ✅ Extract full packet (without the new marker)
                        let packet = buffer.dropLast(2)
                        if packet.count > 4 {
                            print("✅ Extracted Opus Packet (Size: \(packet.count) bytes), First 4 bytes: \(packet.prefix(4).base64EncodedString())")
                            self.processReceivedAudioChunk(packet)
                        }
                    }
                    // ✅ Start new packet with the marker
                    buffer = Data(marker)
                    collecting = true
                }
            }
            opusBuffer = buffer
        } else {
            // ✅ Handle the last remaining packet
            if collecting, buffer.count > 4 {
                print("✅ Processing last packet (Size: \(buffer.count) bytes), First 4 bytes: \(buffer.prefix(4).base64EncodedString())")
                self.processReceivedAudioChunk(buffer)
            }
        }
    }
    

    // MARK: - 🛠 Internal Helper Functions


    /// Extracts only the first Opus packet per attempt
    private func extractFirstOpusPacket(from buffer: inout Data, flush: Bool = false) {
        let headerBytes: [UInt8] = [0x7B, 0x85] // Opus Packet Start Header

        // **Find first marker only**
        guard let start = findFirstPacketMarker(in: buffer, header: headerBytes) else {
            return
        }

        // **Find the next marker (or use full buffer size if none found)**
        let end = findFirstPacketMarker(in: buffer.suffix(from: start + 2), header: headerBytes)
            .map { $0 + start + 2 } ?? 0

        guard start < end, end <= buffer.count else {
            print("❌ Invalid packet range: \(start) - \(end)")
            return
        }

        let packet = buffer[start..<end]
        buffer.removeSubrange(start..<end)

        print("✅ Extracted Opus Packet (Size: \(packet.count) bytes), First 4 bytes: \(packet.prefix(4).base64EncodedString())")
        self.processReceivedAudioChunk(packet)

        // **If flushing, process any remaining buffer data**
        if flush, !buffer.isEmpty {
            print("⚠️ Flushing last Opus packet (Size: \(buffer.count) bytes)")
            self.processReceivedAudioChunk(buffer)
            buffer.removeAll()
        }
    }

    /// Finds the first Opus packet marker in the given buffer
    private func findFirstPacketMarker(in buffer: Data, header: [UInt8]) -> Int? {
        guard buffer.count >= 2 else {
            return nil // Not enough data for a valid Opus marker
        }

        for i in 0..<(buffer.count - 2) { // ✅ Prevents out-of-bounds access
            print("i \(i) - \(buffer.base64EncodedString())")
            if buffer[i] == header[0], buffer[i + 1] == header[1] {
                return i
            }
        }
        
        return nil
    }
    
    private func findOpusPacket(in data: Data, marker: [UInt8]) -> Range<Data.Index>? {
        guard let firstMarkerIndex = data.range(of: Data(marker))?.lowerBound else {
            return nil // No marker found
        }

        let remainingData = data.suffix(from: firstMarkerIndex + marker.count)
        
        if let nextMarkerIndex = remainingData.range(of: Data(marker))?.lowerBound {
            return firstMarkerIndex..<(firstMarkerIndex + nextMarkerIndex + marker.count)
        } else {
            return nil // Not enough data for a complete packet
        }
    }
    
    
    private func processReceivedData(frame: Data) {
//    private func processReceivedData(_ accumulatedData: inout Data, frameSizes: [Int]) {
//        while let frameSize = frameSizes.first(where: { accumulatedData.count >= $0 }) {
//            let frame = accumulatedData.prefix(frameSize)
//            accumulatedData.removeFirst(frameSize)
            
            print("✅ Extracted Opus Frame (Size: \(frame.count) bytes), sending for decoding")

            guard let pcmBuffer = try? decoder?.decode(frame) else {
                print("❌ Opus decoding failed, skipping playback")
                return
            }

            originalPlayer(buffer: pcmBuffer)
//        }
    }
    
    private func processReceivedAudioChunk(_ chunk: Data) {
        if codecMode == .opus {
            // Decode Opus frame
            guard let pcmBuffer = try? decoder?.decode(chunk) else {
                print("chunk size is \(chunk.count)")
                print("❌ Opus decoding failed, skipping playback")
                return
            }

            // Convert to AVAudioPCMBuffer
//            guard let pcmBuffer = dataToAudioBuffer(data: decodedData) else {
//                print("❌ Failed to convert PCM Data to Buffer")
//                return
//            }
            opusPlayer(buffer: pcmBuffer)
            print("data sent to opusPlayer")
        } else {
            // PCM Direct Playback
            guard let pcmBuffer = dataToAudioBuffer(data: chunk) else {
                print("❌ Failed to convert PCM Data to Buffer")
                return
            }
            opusPlayer(buffer: pcmBuffer)
        }
    }
    
    func opusPlayer(buffer: AVAudioPCMBuffer) {
        guard audioEngine.isRunning else {
            print("Audio engine not running, skipping chunk")
            return
        }
        
        let outputFormat = audioEngine.outputNode.outputFormat(forBus: 0)
        buffersCounter += 1
        print("Adding buffer #\(buffersCounter)  ")
  
        Task {
//            guard let self = self else { return }
            self.opusPlayerNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
//                self?.buffersCounter -= 1
//                print("Buffers left \(self?.buffersCounter ?? 0)")
                self?.handleBufferCompletion()
            }
        }
        
//        DispatchQueue.global().async { [weak self] in
//            guard let self = self else { return }
//            self.opusPlayerNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
//                self?.buffersCounter -= 1
//                print("Buffers left \(self?.buffersCounter ?? 0)")
////                self?.handleBufferCompletion()
//            }
////            if buffer.format != outputFormat {
////                guard let convertedBuffer = self.convertBuffer(buffer, to: outputFormat) else {
////                    print("Failed to convert buffer format")
////                    self.buffersCounter -= 1
////                    return
////                }
////                self.opusPlayerNode.scheduleBuffer(convertedBuffer, completionCallbackType: .dataConsumed) { [weak self] _ in
////                    self?.handleBufferCompletion()
////                }
////            } else {
////                self.opusPlayerNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
////                    self?.handleBufferCompletion()
////                }
////            }
//        }
    }
}
