//
//  ContentView.swift
//  SoundCheckiOS
//
//  Created by Artem Mkrtchyan on 11/13/24.
//

import SwiftUI
import AVFoundation
import UIKit

// MARK: - AudioHelperDelegate Protocol
protocol AudioHelperDelegate {
//    func pushToOutputStream(_ data: Data)
    func playbackDone()
}

// MARK: - AudioHelper Class
class AudioHelper: NSObject, ObservableObject {
    
    private func sendAudioData(_ data: Data) {
        guard let outputStream = outputStream, outputStream.hasSpaceAvailable else {
            print("OutputStream not ready or no space available")
            return
        }
        
        data.withUnsafeBytes { bufferPointer in
            guard let baseAddress = bufferPointer.baseAddress else { return }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
            let written = outputStream.write(bytes, maxLength: data.count)
            if written < 0 {
                print("OutputStream write error")
            } else {
                print("Sent \(written) bytes")
            }
        }
    }
    
    static let sharedInstance = AudioHelper()
    private override init() {
        super.init()
    }
    
    var delegate: AudioHelperDelegate?
    
    private var audioSession: AVAudioSession?
    private let captureSession = AVCaptureSession()
    private var playerNode = AVAudioPlayerNode()
    private var engine = AVAudioEngine()
    private var buffersCounter = 0
    
    private let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: false)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: false)!
    
    private var outputStream: OutputStream?
    private var task: URLSessionUploadTask?
    
    // MARK: - Audio Session Configuration
    private func initSession() throws {
        audioSession = AVAudioSession.sharedInstance()
        try audioSession?.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession?.setActive(true)
    }
    
    func configureSession() {
        do {
            try initSession()
        } catch {
            print("Audio session configuration failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Playback Logic
    func beginPlayback() {
        configureSession()
        
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        let outputNode = engine.outputNode
        let outputFormat = outputNode.outputFormat(forBus: 0)
        
        engine.attach(playerNode)
        engine.connect(playerNode, to: outputNode, format: outputFormat)
        
        do {
            try engine.start()
            playerNode.play()
            print("Playback started")
        } catch {
            print("Audio engine start error: \(error.localizedDescription)")
        }
    }
    
    func pushPlayerChunk(_ chunk: Data) {
        guard let buffer = dataToAudioBuffer(data: chunk) else { return }
        buffersCounter += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            guard let self = self else { return }
            self.buffersCounter -= 1
            if self.buffersCounter == 0 {
                DispatchQueue.main.async {
                    self.stopPlayback()
                    self.delegate?.playbackDone()
                }
            }
        }
    }
    
    func stopPlayback() {
        playerNode.stop()
        engine.stop()
        buffersCounter = 0
        print("Playback stopped")
    }
    
    // MARK: - Recording Logic
    func beginRecording(serverUrl: String, authToken: String) {
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else { return }
        configureSession()
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            captureSession.beginConfiguration()
            
            do {
                let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                let audioOutput = AVCaptureAudioDataOutput()
                audioOutput.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: .userInteractive))
                
                if captureSession.canAddInput(audioInput) {
                    captureSession.addInput(audioInput)
                }
                if captureSession.canAddOutput(audioOutput) {
                    captureSession.addOutput(audioOutput)
                }
            } catch {
                print("Failed to configure recording session: \(error.localizedDescription)")
            }
            
            
            captureSession.commitConfiguration()
            captureSession.startRunning()
            print("Recording and streaming started")
            setupStreaming(serverUrl: serverUrl, authToken: authToken)

        }
    }
    
    func stopRecording() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        outputStream?.close()
        task?.cancel()
        try? audioSession?.setActive(false)
        print("Recording and streaming stopped")
    }
    
    // MARK: - Sending Logic
    private func setupStreaming(serverUrl: String, authToken: String) {
        guard let url = URL(string: serverUrl) else {
            print("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("chunked", forHTTPHeaderField: "Transfer-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cahe-Control")

        
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        task = session.uploadTask(withStreamedRequest: request)
        
        task?.resume()
        
        // Send initial dummy data to keep session alive
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.1) { [weak self] in
            let initialChunk = Data(repeating: 0, count: 4096) // Empty 4KB chunk
            self?.sendAudioData(initialChunk)
        }
    }
    
    
    
    // MARK: - Audio Data Conversions
    private func dataToAudioBuffer(data: Data) -> AVAudioPCMBuffer? {
        let frameCapacity = UInt32(data.count) / 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: frameCapacity) else { return nil }
        buffer.frameLength = frameCapacity
        data.withUnsafeBytes { rawBufferPointer in
            memcpy(buffer.int16ChannelData![0], rawBufferPointer.baseAddress!, data.count)
        }
        return buffer
    }
    
    private func audioBufferToData(audioBuffer: AVAudioPCMBuffer) -> Data {
        let bufferLength = Int(audioBuffer.frameLength * audioBuffer.format.streamDescription.pointee.mBytesPerFrame)
        guard let channelData = audioBuffer.int16ChannelData else { return Data() }
        return Data(bytes: channelData[0], count: bufferLength)
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate
extension AudioHelper: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pcmBuffer = sampleBufferToPCMBuffer(sampleBuffer),
              let convertedBuffer = convertBufferFormat(pcmBuffer, to: recordingFormat) else {
            return
        }
        
        let data = audioBufferToData(audioBuffer: convertedBuffer)
        sendAudioData(data)
    }
    
    private func sampleBufferToPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = try? AVAudioFormat(cmAudioFormatDescription: formatDesc),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))) else {
            return nil
        }
        pcmBuffer.frameLength = pcmBuffer.frameCapacity
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(pcmBuffer.frameLength), into: pcmBuffer.mutableAudioBufferList)
        return pcmBuffer
    }
    
    private func convertBufferFormat(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.format.sampleRate != format.sampleRate else {
            // No sample rate conversion needed
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            print("Failed to create AVAudioConverter")
            return nil
        }

        let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(Double(buffer.frameCapacity) * format.sampleRate / buffer.format.sampleRate)
        )!
        
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        let result = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            print("Conversion error: \(error.localizedDescription)")
            return nil
        }

        if result == .error {
            print("Conversion failed")
            return nil
        }

        return convertedBuffer
    }
    
}

// MARK: - SwiftUI ContentView
struct ContentView: View {
    @StateObject private var audioHelper = AudioHelper.sharedInstance
    @State private var broadcastID = "01JBBBJT4SS9K04K3B7X8JG4TE"
    @State private var serverUrl = "http://192.168.1.22:9080/broadcast"
    @State private var authToken = "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhdXRoLXNlcnZpY2UiLCJ1c2VySWQiOiIwMUpBUFlUVEtSRE44Qjc3M1k4NlM3VFBKQiIsInVzZXJuYW1lIjoibWUiLCJleHAiOjE3MzI1OTgzOTR9.huyw_4ShokmG2Xbjc8hV8TkkLm4taF9v5WcPgpCdjOSRBKqmM2Bx1YpBt6PbklBd0r3SZ26VJ1yNgtnDZH-tgQ"
    @State private var isStreaming = false
    @State private var isPlaying = false
    
    
    var body: some View {
        VStack(spacing: 20) {
            TextField("Broadcast ID", text: $broadcastID)
                .textFieldStyle(.roundedBorder)
                .padding()
            
            TextField("Server URL", text: $serverUrl)
                .textFieldStyle(.roundedBorder)
                .padding()
            
            TextField("Authorization Token", text: $authToken)
                .textFieldStyle(.roundedBorder)
                .padding()
            
            Button(isStreaming ? "Stop Streaming" : "Start Streaming") {
                if isStreaming {
                    audioHelper.stopRecording()
                } else {
                    audioHelper.beginRecording(serverUrl: "\(serverUrl)/\(broadcastID)", authToken: authToken)
                }
                isStreaming.toggle()
            }
            .buttonStyle(.borderedProminent)
            
            Button(isPlaying ? "Stop Playback" : "Start Playback") {
                if isPlaying {
                    audioHelper.stopPlayback()
                } else {
                    audioHelper.beginPlayback()
                }
                isPlaying.toggle()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .onAppear {
            audioHelper.delegate = self
        }
    }
}

// MARK: - AudioHelperDelegate Implementation
extension ContentView: AudioHelperDelegate {
    func pushToOutputStream(_ data: Data) {
        // Send data to the server or handle streaming
        print("Pushing data chunk of size: \(data.count)")
    }
    
    func playbackDone() {
        print("Playback finished")
    }
}

extension AudioHelper: URLSessionTaskDelegate {
    
    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        let streamPipe = createStreamPipe()
        outputStream = streamPipe.output
        outputStream?.schedule(in: .current, forMode: .default)
        outputStream?.open()
        completionHandler(streamPipe.input)
    }
    
    private func createStreamPipe() -> (input: InputStream, output: OutputStream) {
        var inputStream: InputStream?
        var outputStream: OutputStream?
        Stream.getBoundStreams(withBufferSize: 4096, inputStream: &inputStream, outputStream: &outputStream)
        return (inputStream!, outputStream!)
    }
}
