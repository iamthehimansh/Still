import CoreMedia

/// A shared clip period keeps audio and video aligned even when their last
/// samples have different durations or the reader has queued a future loop.
enum MediaLoopTiming {
    static func position(at time: CMTime, duration: CMTime) -> (sourceTime: CMTime, offset: CMTime) {
        guard time.isNumeric, time >= .zero, duration.isNumeric, duration > .zero else {
            return (.zero, .zero)
        }
        let loop = floor(time.seconds / duration.seconds)
        let offset = CMTimeMultiplyByFloat64(duration, multiplier: loop)
        return (CMTimeSubtract(time, offset), offset)
    }

    static func offset(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sample }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil,
                                                    entriesNeededOut: &count) == noErr, count > 0 else { return nil }
        var timing = Array(repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing,
                                                    entriesNeededOut: nil) == noErr else { return nil }
        // Preserve each sample's duration. The total duration of a PCM buffer is
        // not the duration of each audio frame inside it.
        for index in timing.indices {
            if timing[index].presentationTimeStamp.isNumeric {
                timing[index].presentationTimeStamp = CMTimeAdd(timing[index].presentationTimeStamp, offset)
            }
            if timing[index].decodeTimeStamp.isNumeric {
                timing[index].decodeTimeStamp = CMTimeAdd(timing[index].decodeTimeStamp, offset)
            }
        }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                                   sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                                   sampleBufferOut: &result) == noErr else { return nil }
        return result
    }
}
