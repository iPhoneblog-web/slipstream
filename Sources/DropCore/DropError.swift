import Foundation

/// Every way a job can fail, with the sentence the user reads. Short and plain, in German.
public enum DropError: Error, Equatable, Sendable {
    case notAVideo
    case noVideoTrack
    case cannotDecodeVideo(codec: String)
    case cannotDecodeAudio(codec: String)
    case protected
    case destinationUnavailable(path: String)
    case readFailed(String)
    case writeFailed(String)
    case checkFailed(String)
    case cancelled

    public var message: String {
        switch self {
        case .notAVideo:
            return "Das ist keine Videodatei."
        case .noVideoTrack:
            return "Die Datei hat keine Videospur."
        case .cannotDecodeVideo(let codec):
            return "Dieses Videoformat (\(codec)) kann der Mac nicht lesen."
        case .cannotDecodeAudio(let codec):
            return "Den Ton (\(codec)) kann der Mac nicht lesen."
        case .protected:
            return "Die Datei ist kopiergeschützt."
        case .destinationUnavailable(let path):
            return "Der Zielordner ist nicht erreichbar: \(path)"
        case .readFailed(let detail):
            return "Lesen fehlgeschlagen: \(detail)"
        case .writeFailed(let detail):
            return "Schreiben fehlgeschlagen: \(detail)"
        case .checkFailed(let detail):
            return "Die fertige Datei ist fehlerhaft: \(detail)"
        case .cancelled:
            return "Abgebrochen."
        }
    }
}

extension DropError {
    /// The extension protocol's error code (docs/extension-protocol.md, "Error codes").
    public var code: String {
        switch self {
        case .notAVideo, .noVideoTrack: return "not-a-video"
        case .cannotDecodeVideo, .cannotDecodeAudio, .protected: return "cannot-decode"
        case .checkFailed: return "check-failed"
        case .cancelled, .destinationUnavailable, .readFailed, .writeFailed: return "internal"
        }
    }
}

extension DropError: LocalizedError {
    public var errorDescription: String? { message }
}
