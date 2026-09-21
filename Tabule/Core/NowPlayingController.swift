import AVFoundation
import Foundation
import MediaPlayer

/// Appka se tváří jako přehrávač, aby dostávala tlačítka z hodinek
/// (AVRCP play/pause/next/previous) i na pozadí — bez toho by iOS
/// vzdálené ovládání appce vůbec nedoručil (zadání, bod 6).
///
/// Mapování (Ondrovo zadání, neověřeno na skutečných hodinkách):
///   play → ANO, previousTrack → NE, nextTrack → POKRAČUJ, pause → POZDĚJI.
///
/// Potřebuje `AVAudioSession(.playback)` aktivní s reálně hrajícím (byť
/// tichým) zvukem — jinak systém `MPRemoteCommandCenter` handlery
/// nedoručuje. Ticho se přehrává jako nekonečně smyčkovaný PCM buffer
/// (`AVAudioPlayerNode` + `.loops`), takže appka nepotřebuje žádný
/// zvukový soubor v bundle.
@MainActor
final class NowPlayingController {
    static let shared = NowPlayingController()

    /// Zavolá se při každém stisku, s českým názvem akce (ANO/NE/POKRAČUJ/POZDĚJI).
    /// Nastavuje ho vlastník WebBridge, aby to šlo předat do cockpitu i na Hub.
    var naStisk: ((String) -> Void)?

    /// Zavolá se při změně `jinaHudbaHraje` — appka podle toho může ukázat
    /// v UI/cockpitu „tlačítka na hodinkách teď ovládají hudbu".
    var naZmenuJinehoZvuku: ((Bool) -> Void)?

    /// Když `true`, jiná appka (Spotify apod.) právě hraje a **má** vzdálené
    /// ovládání — iOS doručí AVRCP povely z hodinek jí, ne nám. Snažit se
    /// je přebírat nemá smysl, jen to ukázat v UI (doplněk k zadání).
    private(set) var jinaHudbaHraje = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// `true`, jakmile jednou proběhlo `attach`/`connect` — díky tomu jde
    /// `engine.stop()`/`engine.start()` opakovat (přerušení, obnova) bez
    /// rizika "node already attached" při druhém sestavení grafu.
    private var grafPripraven = false
    private var tichyBuffer: AVAudioPCMBuffer?
    private var spusteno = false
    private var preruseniPozorovatel: NSObjectProtocol?
    private var tichySignalPozorovatel: NSObjectProtocol?

    private init() {}

    func nastavSePriStartu() {
        nastavAudioSession()
        nastavRemoteCommands()
        nastavNowPlayingInfo()
        sledujCiziZvuk()
        aktualizujJinouHudbu()
    }

    /// Vypne tichý zvuk i vzdálené ovládání — používá se v režimu „Šetřit"
    /// (appka pak nedostává tlačítka z hodinek přes MPRemoteCommandCenter,
    /// jen BLE notify přímo od hodinek). Viz README, „Baterie a dva režimy".
    func zastav() {
        guard spusteno else { return }
        player.stop()
        engine.stop() // zachová attach/connect grafu, jen zastaví IO — start() ho pak jen znovu spustí
        spusteno = false
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.removeTarget(nil)
        c.pauseCommand.removeTarget(nil)
        c.nextTrackCommand.removeTarget(nil)
        c.previousTrackCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if let preruseniPozorovatel { NotificationCenter.default.removeObserver(preruseniPozorovatel) }
        if let tichySignalPozorovatel { NotificationCenter.default.removeObserver(tichySignalPozorovatel) }
        preruseniPozorovatel = nil
        tichySignalPozorovatel = nil
    }

    // MARK: - Cizí zvuk (Spotify apod.) — doplněk k zadání

    /// Dva nezávislé signály: skutečné **přerušení** audio session (např.
    /// telefonát, appka bez `mixWithOthers`) a **hint**, že jiná appka
    /// hraje jako „primární" zvuk, i když nás nepřerušila (typický případ
    /// Spotify + naše `mixWithOthers` ticho — obě zvukové session běží
    /// vedle sebe, ale AVRCP z hodinek dostane ta, kterou iOS považuje za
    /// aktuální „now playing" appku).
    private func sledujCiziZvuk() {
        guard preruseniPozorovatel == nil else { return }
        preruseniPozorovatel = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.zpracujPreruseni(note) }
        }
        tichySignalPozorovatel = NotificationCenter.default.addObserver(
            forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.zpracujTichySignal(note) }
        }
    }

    private func zpracujPreruseni(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            nastavJinouHudbu(true)
        case .ended:
            // Přerušení skončilo — znovu se přihlásit o now-playing (obnovit
            // tiché ticho i MPRemoteCommandCenter), ať appka zase dostává tlačítka.
            nastavAudioSession()
            nastavRemoteCommands()
            nastavNowPlayingInfo()
            nastavJinouHudbu(false)
        @unknown default:
            break
        }
    }

    private func zpracujTichySignal(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: typeRaw) else { return }
        nastavJinouHudbu(type == .begin)
    }

    private func aktualizujJinouHudbu() {
        let session = AVAudioSession.sharedInstance()
        nastavJinouHudbu(session.secondaryAudioShouldBeSilencedHint || session.isOtherAudioPlaying)
    }

    private func nastavJinouHudbu(_ hraje: Bool) {
        guard hraje != jinaHudbaHraje else { return }
        jinaHudbaHraje = hraje
        naZmenuJinehoZvuku?(hraje)
    }

    private func nastavAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // Bez aktivní audio session nepřijdou tlačítka na pozadí —
            // appka dál funguje, jen bez vzdáleného ovládání. Nefatální.
        }
        spustTicho()
    }

    /// Nekonečně smyčkovaný tichý PCM buffer — drží audio session živou,
    /// aby systém doručoval MPRemoteCommandCenter i na pozadí. Skutečné
    /// ticho (samé nuly), ne hudba — co nejmenší buffer (0,25 s, 8 kHz
    /// mono), který se donekonečna smyčkuje, aby zabíral minimum paměti
    /// i CPU (zadání, doplněk o baterii). Kategorie `.playback` +
    /// `mixWithOthers`, ať appka nepřeruší hudbu ani hovor.
    private func spustTicho() {
        guard !spusteno else { return }
        if !grafPripraven {
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let frameCount: AVAudioFrameCount = 2000 // 0,25 s ticha
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
            buffer.frameLength = frameCount
            if let ch = buffer.floatChannelData {
                for i in 0..<Int(frameCount) { ch[0][i] = 0 }
            }
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.0
            tichyBuffer = buffer
            grafPripraven = true
        }
        guard let buffer = tichyBuffer else { return }
        do {
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: [.loops], completionHandler: nil)
            player.play()
            spusteno = true
        } catch {
            // Nefatální — appka jede dál, tlačítka na pozadí ale nemusí chodit.
        }
    }

    /// Idempotentní — smí se volat vícekrát (po každém konci přerušení),
    /// nejdřív odregistruje staré cíle, ať se `stisk()` nevolá vícekrát
    /// za jeden stisk po opakovaných přerušeních.
    private func nastavRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.removeTarget(nil)
        c.pauseCommand.removeTarget(nil)
        c.nextTrackCommand.removeTarget(nil)
        c.previousTrackCommand.removeTarget(nil)
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true

        c.playCommand.addTarget { [weak self] _ in self?.stisk("ANO"); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.stisk("NE"); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.stisk("POKRAČUJ"); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.stisk("POZDĚJI"); return .success }
    }

    private func nastavNowPlayingInfo() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = "Tabule na zápěstí"
        info[MPMediaItemPropertyArtist] = "Baklažán"
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info[MPMediaItemPropertyPlaybackDuration] = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
    }

    private func stisk(_ akce: String) {
        naStisk?(akce)
    }
}
