//
//  ContentView.swift
//  SoundCheckiOS
//
//  Created by Artem Mkrtchyan on 11/13/24.
//

import SwiftUI
import AVFoundation
import UIKit
import SwiftData

// MARK: - AudioHelperDelegate Protocol
protocol AudioHelperDelegate {
    func playbackDone()
    func playbackStarted()
    func recordingStarted()
    func recordingStopped()
}

// MARK: - AudioHelper Class
class AudioHelper: NSObject, ObservableObject {
    
    static let sharedInstance = AudioHelper()
    var delegate: AudioHelperDelegate? = nil
    
    private var audioSession: AVAudioSession? = nil
    private let captureSession = AVCaptureSession()
    private var playerNode = AVAudioPlayerNode()
    private var engine = AVAudioEngine()
    private var buffersCounter = 0
    private var isPlaybackActive = false
    
    private let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: false)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: false)!
    
    private var outputStream: OutputStream?
    private var task: URLSessionUploadTask?
    
    private var dataSession: URLSession?
    var activeTask: URLSessionTask? = nil
    
    
    private override init() {
        super.init()
    }
    
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
    func beginPlayback(serverUrl: String, authToken: String, broadcastID: String) {
        configureSession()
        
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        isPlaybackActive = true
        buffersCounter = 0
        
        let outputNode = engine.outputNode
        let targetFormat = outputNode.outputFormat(forBus: 0)
        
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: targetFormat)
        engine.connect(engine.mainMixerNode, to: outputNode, format: targetFormat)
        
        do {
            try engine.start()
            playerNode.play()
            print("Playback started")
            
            // Start downloading audio data
            downloadAndPlayAudio(serverUrl: "\(serverUrl)/\(broadcastID)", authToken: authToken)
            
            // Notify delegate
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.playbackStarted()
            }
        } catch {
            print("Audio engine start error: \(error.localizedDescription)")
            stopPlayback() // Reset state on failure
        }
    }
    
    func pushPlayerChunk(_ chunk: Data) {
        guard !chunk.isEmpty else {
            print("Empty chunk, skipping")
            return
        }
        
        guard let buffer = dataToAudioBuffer(data: chunk) else {
            print("Failed to create audio buffer from chunk")
            return
        }
        
        guard engine.isRunning else {
            print("Audio engine not running, skipping chunk")
            return
        }
        
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        buffersCounter += 1
        print("Adding buffer #\(buffersCounter) with \(buffer.frameLength) frames")
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if buffer.format != outputFormat {
                guard let convertedBuffer = self.convertBuffer(buffer, to: outputFormat) else {
                    print("Failed to convert buffer format")
                    self.buffersCounter -= 1
                    return
                }
                self.playerNode.scheduleBuffer(convertedBuffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                    self?.handleBufferCompletion()
                }
            } else {
                self.playerNode.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                    self?.handleBufferCompletion()
                }
            }
        }
    }
    
    private func handleBufferCompletion() {
        buffersCounter -= 1
        print("Buffer completed. Remaining: \(buffersCounter)")
        
        if buffersCounter <= 0 && !isPlaybackActive {
            DispatchQueue.main.async { [weak self] in
                self?.stopPlayback()
                self?.delegate?.playbackDone()
            }
        }
    }
    
    // Преобразование с AVAudioConverter
    private func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            print("Ошибка создания конвертера формата")
            return nil
        }
        
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity) else {
            print("Ошибка создания буфера для конвертации")
            return nil
        }
        
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            print("Ошибка преобразования формата: \(error.localizedDescription)")
            return nil
        }
        
        if status == .haveData {
            return convertedBuffer
        } else {
            print("Конвертер не вернул данные: статус - \(status.rawValue)")
            return nil
        }
    }
    
    // Download and Play Audio
    private func downloadAndPlayAudio(serverUrl: String, authToken: String) {
        guard let url = URL(string: serverUrl) else {
            print("Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("chunked", forHTTPHeaderField: "Transfer-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        dataSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
        
        let task = dataSession?.dataTask(with: request)
        activeTask = task
        task?.resume()
    }
    
    func stopPlayback() {
        print("Stopping playback")
        isPlaybackActive = false
        
        if playerNode.isPlaying {
            playerNode.stop()
            
            if playerNode.engine == engine {
                engine.detach(playerNode)
            }
            
            if engine.isRunning {
                engine.stop()
            }
            
            engine = AVAudioEngine()
            playerNode = AVAudioPlayerNode()
            buffersCounter = 0
            
            activeTask?.cancel()
            activeTask = nil
            
            // Clean up the session
            dataSession?.finishTasksAndInvalidate()
            dataSession = nil
        }
    }
    
    // MARK: - Recording Logic
    func beginRecording(serverUrl: String, authToken: String, broadcastID: String) {
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else { return }
        configureSession()
        
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            
            self.captureSession.beginConfiguration()
            
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
            
            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
            print("Recording and streaming started")
            
            // Start streaming to server
            self.setupStreaming(serverUrl: "\(serverUrl)/\(broadcastID)", authToken: authToken)
            
            // Notify delegate
            DispatchQueue.main.async {
                self.delegate?.recordingStarted()
            }
        }
    }
    
    func stopRecording() {
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        
        // Close stream and cancel task
        outputStream?.close()
        task?.cancel()
        
        try? audioSession?.setActive(false)
        print("Recording and streaming stopped")
        
        // Notify delegate
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.recordingStopped()
        }
    }
    
    // MARK: - Sending Logic
    private func setupStreaming(serverUrl: String, authToken: String) {
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
        
        // Send initial dummy data to keep session alive
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.1) { [weak self] in
            let initialChunk = Data(repeating: 0, count: 4096) // Empty 4KB chunk
            self?.sendAudioData(initialChunk)
        }
    }
    
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
    
    // MARK: - Audio Data Conversions
    private func dataToAudioBuffer(data: Data) -> AVAudioPCMBuffer? {
        guard !data.isEmpty else {
            print("Empty data received, cannot create buffer")
            return nil
        }
        
        // Make data size even by padding if necessary
        var processedData = data
        if data.count % 2 != 0 {
            print("Aligning odd-sized data (\(data.count) bytes) by adding padding")
            processedData = data + Data([0]) // Add one byte of padding
        }
        
        let frameCapacity = UInt32(processedData.count) / 2 // 2 bytes per Int16 sample
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: frameCapacity),
              let channelData = buffer.int16ChannelData else {
            print("Failed to allocate buffer or access channel data")
            return nil
        }
        
        buffer.frameLength = frameCapacity
        return processedData.withUnsafeBytes { rawBufferPointer in
            guard let baseAddress = rawBufferPointer.baseAddress else {
                print("No base address for data")
                return nil
            }
            
            memcpy(channelData[0], baseAddress, processedData.count)
            return buffer
        }
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

// MARK: - URLSessionDataDelegate
extension AudioHelper: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("Invalid response from server: \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
            completionHandler(.cancel)
            return
        }
        print("Valid response received: \(httpResponse.statusCode)")
        completionHandler(.allow)
    }
    
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard isPlaybackActive else {
            print("Playback inactive, ignoring received data")
            return
        }
        
        print("Received audio chunk of size: \(data.count) bytes")
        pushPlayerChunk(data)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            if (error as NSError).code == NSURLErrorCancelled {
                print("Task cancelled")
            } else {
                print("Streaming error: \(error.localizedDescription)")
            }
        } else {
            print("Streaming completed - all data received")
        }
        
        // Don't immediately stop - wait for remaining buffers to complete
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isPlaybackActive = false
            
            // Only stop immediately if no buffers are in flight
            if self.buffersCounter <= 0 {
                self.stopPlayback()
                self.delegate?.playbackDone()
            } else {
                print("Waiting for \(self.buffersCounter) buffers to complete...")
            }
        }
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
    
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        activeTask = task
    }
}

// MARK: - SwiftUI ContentView
struct ContentView: View {
    @StateObject private var audioHelper = AudioHelper.sharedInstance
    @State private var broadcastID = "01JMMZZNT29ZXWRR2F2DRF9T5R"
    @State private var serverUrl = "https://ptt.steegler.com/broadcast"
    @State private var authToken = "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhdXRoLXNlcnZpY2UiLCJ1c2VySWQiOiIwMUpNTVpDOEZYRzBLOU4wUzZWS1AyQkFOUSIsInVzZXJuYW1lIjoiTWF4IiwiZXhwIjoxNzQwOTYwMTIyfQ.Mv-kEj6NFSSf2DInZjmj59ir6oKVnzHZjp_ZLd6DD91Osf4cuMkOPaC7km-zc4t_BOo2ho1OhqMqwbto9y78kg"
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
            
            Button(action: {
                if isStreaming {
                    audioHelper.stopRecording()
                    // isStreaming будет изменен через делегат
                } else {
                    audioHelper.beginRecording(serverUrl: serverUrl, authToken: authToken, broadcastID: broadcastID)
                    // isStreaming будет изменен через делегат
                }
            }) {
                Text(isStreaming ? "Stop Streaming" : "Start Streaming")
                    .frame(minWidth: 200)
                    .padding()
                    .background(isStreaming ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(isPlaying) // Отключаем кнопку, если воспроизведение активно
            
            Button(action: {
                if isPlaying {
                    audioHelper.stopPlayback()
                    // isPlaying будет изменен через делегат
                } else {
                    audioHelper.beginPlayback(serverUrl: serverUrl, authToken: authToken, broadcastID: broadcastID)
                    // isPlaying будет изменен через делегат
                }
            }) {
                Text(isPlaying ? "Stop Playback" : "Start Playback")
                    .frame(minWidth: 200)
                    .padding()
                    .background(isPlaying ? Color.orange : Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(isStreaming) // Отключаем кнопку, если запись активна
        }
        .padding()
        .onAppear {
            audioHelper.delegate = self
        }
    }
}

// MARK: - AudioHelperDelegate Implementation
extension ContentView: AudioHelperDelegate {
    func playbackDone() {
        isPlaying = false
        print("Playback finished")
    }
    
    func playbackStarted() {
        isPlaying = true
        print("Playback started")
    }
    
    func recordingStarted() {
        isStreaming = true
        print("Recording started")
    }
    
    func recordingStopped() {
        isStreaming = false
        print("Recording stopped")
    }
}

#Preview {
    ContentView()
        .modelContainer(PreviewContainer.container)
}

struct PreviewContainer {
    static var container: ModelContainer = {
        let schema = Schema([Item.self])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        
        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            // Add any sample data here if needed
            return container
        } catch {
            fatalError("Could not create preview container: \(error)")
        }
    }()
}
