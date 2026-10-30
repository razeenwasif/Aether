import AVFoundation
import Foundation

/// Play's sound: what a run's events and its animations' cues play, and each
/// area's music, crossfaded as the player goes from one area to another —
/// from the game's own `.wav`, `.mp3` and `.m4a` files. Proton's
/// `game-audio.js`, on AVFoundation. Sound never touches the run, so a muted
/// run and a loud one are the same run.
@MainActor
final class GameAudio {
    /// How many of one sound may sound at once; another takes the oldest's place.
    static let voices = 4
    /// Seconds music takes to fade out and in.
    static let fade: TimeInterval = 1.2

    var root: URL?
    var effects: Float = 0.8 { didSet { level() } }
    var musicVolume: Float = 0.6 { didSet { level() } }
    var muted = false { didSet { level() } }

    /// Each file read once (none for one that won't play).
    private var data: [String: Data?] = [:]
    /// Each file's voices sounding now.
    private var sounding: [String: [AVAudioPlayer]] = [:]
    /// The music playing: its file and its player.
    private(set) var playing: (key: String, player: AVAudioPlayer?)?

    private func bytes(_ key: String) -> Data? {
        if let hit = data[key] { return hit }
        let read = root.flatMap { try? Data(contentsOf: $0.appending(path: key)) }
        data[key] = read
        return read
    }

    /// Files read before they're needed.
    func preload(_ keys: [String]) {
        for key in keys { _ = bytes(key) }
    }

    /// A file played once.
    func play(_ key: String) {
        guard !muted, effects > 0, let bytes = bytes(key), let player = try? AVAudioPlayer(data: bytes) else { return }
        var list = sounding[key, default: []].filter(\.isPlaying)
        if list.count >= Self.voices { list.removeFirst().stop() }
        player.volume = effects
        player.play()
        list.append(player)
        sounding[key] = list
    }

    /// `key` as the music, looping, faded in as what played fades out; none
    /// fades it out. The same music again goes on as it was.
    func music(_ key: String?) {
        let key = key ?? ""
        if playing?.key == key { return }
        if let was = playing?.player {
            was.setVolume(0, fadeDuration: Self.fade)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fade) { was.stop() }
        }
        guard !key.isEmpty, let bytes = bytes(key), let player = try? AVAudioPlayer(data: bytes) else {
            playing = (key, nil)
            return
        }
        player.numberOfLoops = -1
        player.volume = 0
        player.play()
        player.setVolume(muted ? 0 : musicVolume, fadeDuration: Self.fade)
        playing = (key, player)
    }

    /// The volumes or the mute changed.
    private func level() {
        playing?.player?.volume = muted ? 0 : musicVolume
        for list in sounding.values { for p in list { p.volume = muted ? 0 : effects } }
    }

    /// The music ended at once, and every sound.
    func stop() {
        playing?.player?.stop()
        playing = nil
        for list in sounding.values { for p in list { p.stop() } }
        sounding = [:]
    }

    /// Everything read forgotten, for another game.
    func forget() {
        stop()
        data = [:]
    }
}
