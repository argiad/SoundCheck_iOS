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
    
    var delegate: AudioHelperDelegate? = nil
    
    private var audioSession: AVAudioSession? = nil
    private let captureSession = AVCaptureSession()
    private var playerNode = AVAudioPlayerNode()
    private var engine = AVAudioEngine()
    private var buffersCounter = 0
    
    private let recordingFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: false)!
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: false)!
    
    private var outputStream: OutputStream?
    private var task: URLSessionUploadTask?
    
    private var dataSession: URLSession?
    var activeTask: URLSessionTask? = nil
    
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
        let targetFormat = outputNode.outputFormat(forBus: 0)
        let outputFormat = outputNode.outputFormat(forBus: 0)
        print("Output Format: \(outputFormat)")
        print("Target Format: \(targetFormat)")
        
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: targetFormat)
        engine.connect(engine.mainMixerNode, to: outputNode, format: targetFormat)
        
        do {
            try engine.start()
            playerNode.play()
            print("Playback started")
        } catch {
            print("Audio engine start error: \(error.localizedDescription)")
            stopPlayback()
        }
    }
    
    func pushPlayerChunk(_ chunk: Data) {
        guard !chunk.isEmpty, let buffer = dataToAudioBuffer(data: chunk) else {
            print("Invalid or empty chunk, skipping")
            return
        }
        
        guard engine.isRunning else {
            print("Audio engine not running, skipping chunk")
            return
        }
        
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        buffersCounter += 1
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            print("Scheduling buffer with \(buffer.frameLength) frames")
            
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
        print("Buffer completed, remaining: \(buffersCounter)")
        if buffersCounter <= 0 {
            DispatchQueue.main.async { [weak self] in
                self?.stopPlayback()
            }
        }
    }
    
    // Преобразование с AVAudioConverter
    private func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            print("Ошибка создания конвертера формата")
            return nil
        }
        
        // Создаем новый буфер с нужным форматом
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity) else {
            print("Ошибка создания буфера для конвертации")
            return nil
        }
        
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        // Конвертация
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
    func downloadAndPlayAudio(serverUrl: String, authToken: String) {
        guard let url = URL(string: serverUrl) else {
            print("Invalid URL")
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("chunked", forHTTPHeaderField: "Transfer-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cahe-Control")
        
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        dataSession = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
        
        DispatchQueue.main.async { [weak self] in
            self?.beginPlayback()
        }
        
        dataSession?.dataTask(with: request).resume()
    }
    
    func stopPlayback() {
        print("******** STOP *********")
        if audioSession != nil && playerNode.isPlaying {
            playerNode.stop()
            engine.detach(playerNode)
            if engine.isRunning {
                engine.stop()
            }
            engine = AVAudioEngine()
            playerNode = AVAudioPlayerNode()
            buffersCounter = 0
        }
        activeTask?.cancel()
        activeTask = nil
        dataSession?.finishTasksAndInvalidate()
        dataSession = nil
        delegate?.playbackDone()
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
        outputStream = nil
        task?.cancel()
        task = nil
        try? audioSession?.setActive(false)
        audioSession = nil
        print("Recording and streaming stopped")
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
        guard !data.isEmpty else {
            print("Empty data received, cannot create buffer")
            return nil
        }
        
        let frameCapacity = UInt32(data.count) / 2 // 2 bytes per Int16 sample
        guard let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: frameCapacity),
              let channelData = buffer.int16ChannelData else {
            print("Failed to allocate buffer or access channel data")
            return nil
        }
        
        guard data.count % 2 == 0 else {
            print("Data size \(data.count) is not aligned for PCM Int16 (must be even)")
            return nil
        }
        
        buffer.frameLength = frameCapacity
        return data.withUnsafeBytes { rawBufferPointer in
            guard let baseAddress = rawBufferPointer.baseAddress else {
                print("No base address for data")
                return nil
            }
            
            memcpy(channelData[0], baseAddress, data.count)
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
        print("Received audio chunk of size: \(data.count) bytes")
        pushPlayerChunk(data)
    }
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("Streaming error: \(error.localizedDescription)")
        } else {
            print("Streaming completed")
        }
        DispatchQueue.main.async { [weak self] in
            self?.stopPlayback()
            self?.delegate?.playbackDone()
        }
    }
}

// MARK: - SwiftUI ContentView
struct ContentView: View {
    @StateObject private var audioHelper = AudioHelper.sharedInstance
    @State private var broadcastID = "01JMMZZNT29ZXWRR2F2DRF9T5R"
    @State private var serverUrl = "https://ptt.steegler.com/broadcast"
    @State private var authToken = "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhdXRoLXNlcnZpY2UiLCJ1c2VySWQiOiIwMUpNTVpDOEZYRzBLOU4wUzZWS1AyQkFOUSIsInVzZXJuYW1lIjoiTWF4IiwiZXhwIjoxNzQwMjAyMTYzfQ.HCJgYC8ipLcd1EDe8EelfdJKlD5BiAfGUW0CMlnP3wP6bIBAvJw-ySK0m_Rv5xD5Upm0auNe_GiZoaaPc5tIag"
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
                    isStreaming = false
                } else {
                    audioHelper.beginRecording(serverUrl: "\(serverUrl)/\(broadcastID)", authToken: authToken)
                    isStreaming = true
                }
                //isStreaming.toggle()
            }
            .buttonStyle(.borderedProminent)
            
            Button(isPlaying ? "Stop Playback" : "Start Playback") {
                if isPlaying {
                    audioHelper.stopPlayback()
                    isPlaying = false
                } else {
                    audioHelper.downloadAndPlayAudio(serverUrl: "\(serverUrl)/\(broadcastID)", authToken: authToken)
                    isPlaying = true
                }
                //isPlaying.toggle()
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
        isPlaying = false
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
    
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        activeTask = task
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
