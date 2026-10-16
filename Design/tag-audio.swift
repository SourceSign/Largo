// Converts an audio file to AAC (.m4a) with title, artist and cover art.
//
//   swift Design/tag-audio.swift <input> <output.m4a> <title> <artist> <cover.png>
import AVFoundation

let a = CommandLine.arguments
func item(_ id: AVMetadataIdentifier, _ value: Any, type: String? = nil) -> AVMetadataItem {
    let m = AVMutableMetadataItem()
    m.identifier = id
    m.value = value as? NSCopying & NSObjectProtocol
    if let type { m.dataType = type }
    return m
}
let export = AVAssetExportSession(asset: AVURLAsset(url: URL(fileURLWithPath: a[1])),
                                  presetName: AVAssetExportPresetAppleM4A)!
export.outputURL = URL(fileURLWithPath: a[2])
export.outputFileType = .m4a
export.metadata = [
    item(.commonIdentifierTitle, a[3] as NSString),
    item(.commonIdentifierArtist, a[4] as NSString),
    item(.commonIdentifierArtwork, try! Data(contentsOf: URL(fileURLWithPath: a[5])) as NSData,
         type: kCMMetadataBaseDataType_PNG as String),
]
try? FileManager.default.removeItem(at: export.outputURL!)
let done = DispatchSemaphore(value: 0)
export.exportAsynchronously { done.signal() }
done.wait()
print(export.status == .completed ? "Wrote \(a[2])" : "Failed: \(export.error.map { "\($0)" } ?? "unknown")")
