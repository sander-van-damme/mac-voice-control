import AVFoundation
import VoiceCore

/// 16 kHz mono AAC-LC at 24 kbit/s, wrapped in ADTS for standalone playback.
/// Encodes only utterances already segmented for local ASR; never writes original PCM to disk.
enum DebugAudio {
    static func record(_ samples: [Float], utteranceID: String) {
        DebugLog.shared.capture("speech.audio",estimatedBytes:samples.count * MemoryLayout<Float>.size,
            ext:"aac",fields:["utterance_id":utteranceID,"sample_rate":"16000","bit_rate":"24000",
                              "duration_seconds":String(Double(samples.count)/16000)]) { try encode(samples) }
    }
    static func encode(_ samples: [Float]) throws -> Data {
        guard !samples.isEmpty, samples.count <= 16_000 * 16,
              let pcm = AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:16000,channels:1,interleaved:false),
              let aac = AVAudioFormat(settings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:16000,
                  AVNumberOfChannelsKey:1,AVEncoderBitRateKey:24000]),
              let converter = AVAudioConverter(from:pcm,to:aac),
              let input = AVAudioPCMBuffer(pcmFormat:pcm,frameCapacity:AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0] else { throw VoiceError("Cannot prepare debug audio encoding.") }
        input.frameLength = AVAudioFrameCount(samples.count)
        converter.bitRate = 24000
        let output = AVAudioCompressedBuffer(format:aac,packetCapacity:32,maximumPacketSize:max(8192,converter.maximumOutputPacketSize))
        var position = 0, data = Data()
        for _ in 0..<512 {
            var error: NSError?
            let status = converter.convert(to:output,error:&error) { requested,state in
                guard position < samples.count else { state.pointee = .endOfStream; return nil }
                let count = min(Int(requested),samples.count-position)
                input.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { channel.update(from:$0.baseAddress!.advanced(by:position),count:count) }
                position += count; state.pointee = .haveData; return input
            }
            if let error { throw error }
            guard status != .error else { throw VoiceError("Debug AAC conversion failed.") }
            if let descriptions = output.packetDescriptions {
                for index in 0..<Int(output.packetCount) {
                    let packet = descriptions[index], length = Int(packet.mDataByteSize) + 7
                    guard length < 8192 else { throw VoiceError("Debug AAC packet is too large.") }
                    // AAC-LC profile=1, 16 kHz frequency index=8, mono channel config=1.
                    data.append(contentsOf:[0xff,0xf1,0x60,UInt8(0x40 | (length >> 11)),
                        UInt8((length >> 3) & 0xff),UInt8(((length & 7) << 5) | 0x1f),0xfc])
                    data.append(output.data.advanced(by:Int(packet.mStartOffset)).assumingMemoryBound(to:UInt8.self),count:Int(packet.mDataByteSize))
                }
            }
            if status == .endOfStream {
                guard !data.isEmpty else { throw VoiceError("Debug AAC conversion returned no audio.") }
                return data
            }
        }
        throw VoiceError("Debug AAC conversion did not finish.")
    }
}
