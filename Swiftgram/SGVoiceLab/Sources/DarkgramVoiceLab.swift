import Foundation
import AVFoundation
import OpusBinding

private func darkgramSetBits(data: UnsafeMutableRawPointer, bitOffset: Int, numBits: Int, value: Int32) {
    let normalizedData = data.advanced(by: bitOffset / 8)
    let normalizedBitOffset = bitOffset % 8
    normalizedData.assumingMemoryBound(to: Int32.self).pointee |= value << Int32(normalizedBitOffset)
}

private func darkgramMakeWaveformBitstream(samples: Data, peak: Int32) -> Data {
    let numSamples = samples.count / 2
    let bitstreamLength = (numSamples * 5) / 8 + (((numSamples * 5) % 8) == 0 ? 0 : 1)
    var result = Data(count: bitstreamLength + 4)
    let maxSample = max(1, peak)
    
    samples.withUnsafeBytes { rawSamples in
        let sampleBuffer = rawSamples.baseAddress!.assumingMemoryBound(to: Int16.self)
        result.withUnsafeMutableBytes { rawBytes in
            let byteBuffer = rawBytes.baseAddress!
            for index in 0 ..< numSamples {
                let value = min(Int32(31), abs(Int32(sampleBuffer[index])) * 31 / maxSample)
                darkgramSetBits(data: byteBuffer, bitOffset: index * 5, numBits: 5, value: value & Int32(31))
            }
        }
    }
    
    result.count = bitstreamLength
    return result
}

public struct DarkgramVoiceLabSettingsSnapshot: Equatable {
    public let enabled: Bool
    public let applyToVoiceMessages: Bool
    public let applyToCalls: Bool
    public let applyToGroupCalls: Bool
    public let allowForwardWithVoiceChange: Bool
    public let pitchCents: Int32
    public let outputGainPercent: Int32
    public let preserveDuration: Bool
    public let dontSendOnFailure: Bool
    public let sendToSavedMessagesOnFailure: Bool
    
    public init(
        enabled: Bool,
        applyToVoiceMessages: Bool,
        applyToCalls: Bool,
        applyToGroupCalls: Bool,
        allowForwardWithVoiceChange: Bool,
        pitchCents: Int32,
        outputGainPercent: Int32,
        preserveDuration: Bool,
        dontSendOnFailure: Bool,
        sendToSavedMessagesOnFailure: Bool
    ) {
        self.enabled = enabled
        self.applyToVoiceMessages = applyToVoiceMessages
        self.applyToCalls = applyToCalls
        self.applyToGroupCalls = applyToGroupCalls
        self.allowForwardWithVoiceChange = allowForwardWithVoiceChange
        self.pitchCents = max(-1200, min(1200, pitchCents))
        self.outputGainPercent = max(25, min(200, outputGainPercent))
        self.preserveDuration = preserveDuration
        self.dontSendOnFailure = dontSendOnFailure
        self.sendToSavedMessagesOnFailure = sendToSavedMessagesOnFailure
    }
    
    public var hasActiveTransform: Bool {
        return self.pitchCents != 0 || self.outputGainPercent != 100
    }
    
    public var isActiveForVoiceMessages: Bool {
        return self.enabled && self.applyToVoiceMessages && self.hasActiveTransform
    }
    
    public var isActiveForForwardedVoiceMessages: Bool {
        return self.enabled && self.allowForwardWithVoiceChange && self.hasActiveTransform
    }
    
    public var isActiveForCalls: Bool {
        return self.enabled && self.applyToCalls && self.hasActiveTransform
    }
    
    public var isActiveForGroupCalls: Bool {
        return self.enabled && self.applyToGroupCalls && self.hasActiveTransform
    }
    
    public var failurePolicy: DarkgramVoiceLabFailurePolicy {
        if !self.dontSendOnFailure {
            return .sendOriginalToTarget
        } else if self.sendToSavedMessagesOnFailure {
            return .redirectOriginalToSavedMessages
        } else {
            return .skipSending
        }
    }
}

public enum DarkgramVoiceLabFailurePolicy: Equatable {
    case sendOriginalToTarget
    case skipSending
    case redirectOriginalToSavedMessages
}

public struct DarkgramVoiceLabProcessedAudio {
    public let compressedData: Data
    public let duration: Double
    public let waveformBitstream: Data?
    
    public init(compressedData: Data, duration: Double, waveformBitstream: Data?) {
        self.compressedData = compressedData
        self.duration = duration
        self.waveformBitstream = waveformBitstream
    }
}

public enum DarkgramVoiceLabError: Error {
    case disabled
    case invalidSource
    case invalidTrimRange
    case renderFailed
    case emptyOutput
}

private final class DarkgramVoiceWaveformAccumulator {
    private var compressedWaveformSamples = Data()
    private var currentPeak: Int64 = 0
    private var currentPeakCount: Int = 0
    private var peakCompressionFactor: Int = 1
    
    func append(int16Samples: UnsafeBufferPointer<Int16>) {
        for sampleValue in int16Samples {
            var sample = sampleValue
            if sample < 0 {
                if sample == Int16.min {
                    sample = Int16.max
                } else {
                    sample = -sample
                }
            }
            
            self.currentPeak = max(Int64(sample), self.currentPeak)
            self.currentPeakCount += 1
            if self.currentPeakCount == self.peakCompressionFactor {
                var compressedPeak = self.currentPeak
                withUnsafeBytes(of: &compressedPeak) { buffer in
                    self.compressedWaveformSamples.append(buffer.bindMemory(to: UInt8.self))
                }
                self.currentPeak = 0
                self.currentPeakCount = 0
                
                let compressedSampleCount = self.compressedWaveformSamples.count / 2
                if compressedSampleCount == 200 {
                    self.compressedWaveformSamples.withUnsafeMutableBytes { rawCompressedSamples in
                        let compressedSamples = rawCompressedSamples.baseAddress!.assumingMemoryBound(to: Int16.self)
                        for index in 0 ..< 100 {
                            let maxSample = Int64(max(compressedSamples[index * 2], compressedSamples[index * 2 + 1]))
                            compressedSamples[index] = Int16(maxSample)
                        }
                    }
                    self.compressedWaveformSamples.count = 100 * 2
                    self.peakCompressionFactor *= 2
                }
            }
        }
    }
    
    func makeBitstream() -> Data? {
        guard !self.compressedWaveformSamples.isEmpty else {
            return nil
        }
        
        let scaledSamplesMemory = malloc(100 * 2)!
        defer {
            free(scaledSamplesMemory)
        }
        let scaledSamples = scaledSamplesMemory.assumingMemoryBound(to: Int16.self)
        memset(scaledSamples, 0, 100 * 2)
        
        let count = self.compressedWaveformSamples.count / 2
        self.compressedWaveformSamples.withUnsafeBytes { rawSamples in
            let samples = rawSamples.baseAddress!.assumingMemoryBound(to: Int16.self)
            for index in 0 ..< count {
                let sample = samples[index]
                let targetIndex = index * 100 / count
                if scaledSamples[targetIndex] < sample {
                    scaledSamples[targetIndex] = sample
                }
            }
            
            var sumSamples: Int64 = 0
            for index in 0 ..< 100 {
                sumSamples += Int64(scaledSamples[index])
            }
            var calculatedPeak = UInt16((Double(sumSamples) * 1.8 / 100.0))
            if calculatedPeak < 2500 {
                calculatedPeak = 2500
            }
            
            for index in 0 ..< 100 {
                let sample = UInt16(Int64(scaledSamples[index]))
                let minPeak = min(Int64(sample), Int64(calculatedPeak))
                let resultPeak = minPeak * 31 / Int64(calculatedPeak)
                scaledSamples[index] = Int16(clamping: min(31, resultPeak))
            }
        }
        
        return darkgramMakeWaveformBitstream(samples: Data(bytes: scaledSamplesMemory, count: 100 * 2), peak: 31)
    }
}

public final class DarkgramVoiceLabProcessor {
    public static let shared = DarkgramVoiceLabProcessor()
    
    private let sampleRate: Double = 48_000.0
    private let bytesPerFrame = 2
    private let opusFrameSizeSamples = 960
    private let maxRenderFrames: AVAudioFrameCount = 4096
    
    private init() {
    }
    
    public func processVoiceMessage(
        sourcePath: String,
        trimRange: Range<Double>?,
        settings: DarkgramVoiceLabSettingsSnapshot
    ) throws -> DarkgramVoiceLabProcessedAudio {
        guard settings.isActiveForVoiceMessages else {
            throw DarkgramVoiceLabError.disabled
        }
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            throw DarkgramVoiceLabError.invalidSource
        }
        
        let inputData = try Data(contentsOf: URL(fileURLWithPath: sourcePath), options: [.mappedIfSafe])
        return try self.processPCM16Mono48k(data: inputData, trimRange: trimRange, settings: settings)
    }
    
    public func processExistingVoiceMessage(
        sourceOggPath: String,
        settings: DarkgramVoiceLabSettingsSnapshot
    ) throws -> DarkgramVoiceLabProcessedAudio {
        guard settings.isActiveForForwardedVoiceMessages else {
            throw DarkgramVoiceLabError.disabled
        }
        guard FileManager.default.fileExists(atPath: sourceOggPath) else {
            throw DarkgramVoiceLabError.invalidSource
        }
        
        let decodedPCM = try self.decodeOggOpusToPCM16Mono48k(path: sourceOggPath)
        return try self.processPCM16Mono48k(data: decodedPCM, trimRange: nil, settings: settings)
    }
    
    private func processPCM16Mono48k(
        data: Data,
        trimRange: Range<Double>?,
        settings: DarkgramVoiceLabSettingsSnapshot
    ) throws -> DarkgramVoiceLabProcessedAudio {
        let trimmedData = try self.slicePCM16Mono48k(data: data, trimRange: trimRange)
        guard !trimmedData.isEmpty else {
            throw DarkgramVoiceLabError.invalidSource
        }
        
        let inputBuffer = try self.makeInputBuffer(fromPCM16Mono48k: trimmedData)
        let renderedPCM: AVAudioPCMBuffer
        if settings.pitchCents == 0 {
            renderedPCM = inputBuffer
        } else {
            renderedPCM = try self.renderProcessedPCM(inputBuffer: inputBuffer, settings: settings)
        }
        return try self.encodeOpus(fromPCM16Mono48kFloat: renderedPCM, settings: settings)
    }
    
    private func decodeOggOpusToPCM16Mono48k(path: String) throws -> Data {
        guard let reader = OggOpusReader(path: path) else {
            throw DarkgramVoiceLabError.invalidSource
        }
        
        var decoded = Data()
        var pcmBuffer = [Int16](repeating: 0, count: self.opusFrameSizeSamples * 8)
        
        while true {
            let readSamples = pcmBuffer.withUnsafeMutableBufferPointer { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else {
                    return 0
                }
                return Int(reader.read(baseAddress, bufSize: Int32(buffer.count)))
            }
            if readSamples < 0 {
                throw DarkgramVoiceLabError.renderFailed
            } else if readSamples == 0 {
                break
            }
            
            pcmBuffer.withUnsafeBytes { rawBytes in
                if let baseAddress = rawBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                    decoded.append(baseAddress, count: readSamples * MemoryLayout<Int16>.size)
                }
            }
        }
        
        guard !decoded.isEmpty else {
            throw DarkgramVoiceLabError.emptyOutput
        }
        return decoded
    }
    
    private func slicePCM16Mono48k(data: Data, trimRange: Range<Double>?) throws -> Data {
        guard let trimRange else {
            return data
        }
        guard trimRange.upperBound > trimRange.lowerBound, trimRange.lowerBound >= 0 else {
            throw DarkgramVoiceLabError.invalidTrimRange
        }
        
        let totalFrames = data.count / self.bytesPerFrame
        let totalDuration = Double(totalFrames) / self.sampleRate
        let lowerBound = max(0.0, min(totalDuration, trimRange.lowerBound))
        let upperBound = max(lowerBound, min(totalDuration, trimRange.upperBound))
        
        let startFrame = Int(lowerBound * self.sampleRate)
        let endFrame = Int(upperBound * self.sampleRate)
        let startOffset = max(0, min(data.count, startFrame * self.bytesPerFrame))
        let endOffset = max(startOffset, min(data.count, endFrame * self.bytesPerFrame))
        return data.subdata(in: startOffset ..< endOffset)
    }
    
    private func makeInputBuffer(fromPCM16Mono48k data: Data) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: self.sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / self.bytesPerFrame)),
              let channelData = buffer.floatChannelData?.pointee else {
            throw DarkgramVoiceLabError.invalidSource
        }
        
        let frameCount = data.count / self.bytesPerFrame
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for index in 0 ..< frameCount {
                channelData[index] = Float(samples[index]) / Float(Int16.max)
            }
        }
        return buffer
    }
    
    private func renderProcessedPCM(
        inputBuffer: AVAudioPCMBuffer,
        settings: DarkgramVoiceLabSettingsSnapshot
    ) throws -> AVAudioPCMBuffer {
        let format = inputBuffer.format
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let expectedRate: Double
        if settings.preserveDuration {
            expectedRate = 1.0
        } else {
            expectedRate = max(0.25, min(4.0, pow(2.0, Double(settings.pitchCents) / 1200.0)))
        }
        let expectedOutputFrames = max(1, Int(ceil(Double(inputBuffer.frameLength) / expectedRate)))
        let renderFrameLimit = expectedOutputFrames + Int(self.maxRenderFrames) * 8
        let tapBufferSize = self.maxRenderFrames
        let lock = NSLock()
        let finishedSemaphore = DispatchSemaphore(value: 0)
        
        engine.attach(player)
        let processingNode: AVAudioNode
        
        if settings.preserveDuration {
            let timePitch = AVAudioUnitTimePitch()
            timePitch.pitch = Float(settings.pitchCents)
            timePitch.rate = 1.0
            engine.attach(timePitch)
            engine.connect(player, to: timePitch, format: format)
            processingNode = timePitch
        } else {
            let varispeed = AVAudioUnitVarispeed()
            varispeed.rate = Float(expectedRate)
            engine.attach(varispeed)
            engine.connect(player, to: varispeed, format: format)
            processingNode = varispeed
        }
        engine.connect(processingNode, to: engine.mainMixerNode, format: format)
        
        var renderedSamples: [Float] = []
        renderedSamples.reserveCapacity(renderFrameLimit)
        processingNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { buffer, _ in
            guard buffer.frameLength > 0, let renderedChannel = buffer.floatChannelData?.pointee else {
                return
            }
            lock.lock()
            let remainingCapacity = renderFrameLimit - renderedSamples.count
            if remainingCapacity > 0 {
                let safeFrameLength = min(Int(buffer.frameLength), remainingCapacity)
                let bufferPointer = UnsafeBufferPointer(start: renderedChannel, count: safeFrameLength)
                renderedSamples.append(contentsOf: bufferPointer)
            }
            lock.unlock()
        }
        
        engine.prepare()
        try engine.start()
        
        player.scheduleBuffer(inputBuffer, at: nil, options: []) {
            finishedSemaphore.signal()
        }
        player.play()

        let expectedDuration = Double(expectedOutputFrames) / self.sampleRate
        let timeoutSeconds = max(3.0, expectedDuration * 2.0 + 1.0)
        let timeout = DispatchTime.now() + .milliseconds(Int(timeoutSeconds * 1000.0))
        guard finishedSemaphore.wait(timeout: timeout) == .success else {
            processingNode.removeTap(onBus: 0)
            player.stop()
            engine.stop()
            throw DarkgramVoiceLabError.renderFailed
        }
        Thread.sleep(forTimeInterval: 0.12)
        
        processingNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        
        let finalRenderedSamples: [Float]
        lock.lock()
        finalRenderedSamples = renderedSamples
        lock.unlock()
        
        guard !finalRenderedSamples.isEmpty,
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(finalRenderedSamples.count)),
              let outputChannel = outputBuffer.floatChannelData?.pointee else {
            throw DarkgramVoiceLabError.emptyOutput
        }
        
        outputBuffer.frameLength = AVAudioFrameCount(finalRenderedSamples.count)
        for index in 0 ..< finalRenderedSamples.count {
            outputChannel[index] = finalRenderedSamples[index]
        }
        return outputBuffer
    }
    
    private func encodeOpus(
        fromPCM16Mono48kFloat buffer: AVAudioPCMBuffer,
        settings: DarkgramVoiceLabSettingsSnapshot
    ) throws -> DarkgramVoiceLabProcessedAudio {
        guard let channel = buffer.floatChannelData?.pointee else {
            throw DarkgramVoiceLabError.emptyOutput
        }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            throw DarkgramVoiceLabError.emptyOutput
        }
        
        let gain = max(0.25, min(2.0, Float(settings.outputGainPercent) / 100.0))
        let dataItem = TGDataItem()
        let writer = TGOggOpusWriter()
        guard writer.begin(with: dataItem) else {
            throw DarkgramVoiceLabError.renderFailed
        }
        let accumulator = DarkgramVoiceWaveformAccumulator()
        
        var processed = [Int16]()
        processed.reserveCapacity(frameCount)
        for index in 0 ..< frameCount {
            var sample = channel[index] * gain
            sample = max(-1.0, min(1.0, sample))
            processed.append(Int16(sample * Float(Int16.max)))
        }
        
        var encodingSucceeded = true
        processed.withUnsafeMutableBufferPointer { samples in
            accumulator.append(
                int16Samples: UnsafeBufferPointer(start: samples.baseAddress, count: samples.count)
            )
            if let baseAddress = samples.baseAddress {
                var offset = 0
                while offset < samples.count {
                    let chunkSampleCount = min(self.opusFrameSizeSamples, samples.count - offset)
                    let chunkPointer = UnsafeMutableRawPointer(baseAddress.advanced(by: offset)).assumingMemoryBound(to: UInt8.self)
                    if !writer.writeFrame(
                        chunkPointer,
                        frameByteCount: UInt(chunkSampleCount * MemoryLayout<Int16>.size)
                    ) {
                        encodingSucceeded = false
                        break
                    }
                    offset += chunkSampleCount
                }
            }
        }
        
        guard encodingSucceeded, writer.writeFrame(nil, frameByteCount: 0) else {
            throw DarkgramVoiceLabError.emptyOutput
        }
        
        return DarkgramVoiceLabProcessedAudio(
            compressedData: dataItem.data(),
            duration: writer.encodedDuration(),
            waveformBitstream: accumulator.makeBitstream()
        )
    }
}
