/// What system audio to capture: everything the Mac plays, or one app's audio.
enum SystemAudioTarget: Hashable {
    case allAudio
    case app(bundleID: String, name: String)

    /// The speaker label for this source in multi-source transcripts.
    var label: String {
        switch self {
        case .allAudio: "System audio"
        case .app(_, let name): name
        }
    }
}
