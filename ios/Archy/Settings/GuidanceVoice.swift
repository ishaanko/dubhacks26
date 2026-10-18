import SwiftUI
import AVFoundation
import Security

/// Proxy credentials are separate from the server-side xAI API key.
enum VoiceConnection {
    static let service = "com.dubhacks.archy.voice-proxy"
    static func token() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "proxy", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func saveToken(_ token: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "proxy"]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess }
        return status == errSecSuccess
    }
    static func clearToken() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "proxy"] as CFDictionary)
    }
    static func validURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty,
              host != "api.x.ai", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasSuffix("/narrate") else { return nil }
        return url
    }

    #if DEBUG
    private static var appliedOverrides = false
    /// Debug builds only: `-ArchyVoiceProxyURL <url> -ArchyVoiceTokenFile <path>` stores the token from that file
    /// in the Keychain and turns Grok on, so UI tests can exercise the live proxy without typing secrets.
    /// The token is never logged.
    static func applyLaunchOverrides() {
        guard !appliedOverrides else { return }
        appliedOverrides = true
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "ArchyVoiceTokenFile"),
              let url = defaults.string(forKey: "ArchyVoiceProxyURL"), validURL(url) != nil,
              let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 24, saveToken(token) else { return }
        defaults.set(url, forKey: "voice.proxyURL")
        defaults.set(true, forKey: "voice.grokEnabled")
    }
    #endif
}

/// Fetched Grok narration kept in Caches, so later sessions play instantly and offline.
enum VoiceCache {
    /// Bump together with a change to `narrationCatalog` text or the xAI voice in `services/voice/server.mjs`,
    /// so installed apps drop their saved audio.
    static let version = "2"

    private static var root: URL { URL.cachesDirectory.appending(path: "ArchyVoice", directoryHint: .isDirectory) }
    private static var directory: URL { root.appending(path: "v" + version, directoryHint: .isDirectory) }
    private static func file(_ script: String) -> URL {
        let safe = String(script.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" })
        return directory.appending(path: safe + ".mp3")
    }

    static func data(for script: String) -> Data? { try? Data(contentsOf: file(script)) }

    static func store(_ bytes: Data, for script: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? bytes.write(to: file(script), options: .atomic)
    }

    /// Removes audio saved under older catalog versions.
    static func purgeOldVersions() {
        let current = directory.lastPathComponent
        let old = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for url in old where url.lastPathComponent != current { try? FileManager.default.removeItem(at: url) }
    }
}

@MainActor @Observable
final class GuidanceVoice: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    /// A request budget long enough for a cold xAI render of the longest script.
    private static let patientTimeout: TimeInterval = 12
    nonisolated private static let maxAudioBytes = 2_097_152
    private static var prefetching: Set<String> = []
    private static var didPurge = false

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    /// The utterance or player now audible, so a late callback from a line that was cut off is ignored.
    private var line: AnyObject?
    private(set) var status = "On-device voice"

    /// True from the moment a line starts playing until it ends or `stop()` cuts it off.
    var isSpeaking: Bool { line != nil }

    override init() {
        super.init()
        synthesizer.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVAudioSession.interruptionNotification,
                                               object: AVAudioSession.sharedInstance())
        if !Self.didPurge { Self.didPurge = true; VoiceCache.purgeOldVersions() }
        #if DEBUG
        VoiceConnection.applyLaunchOverrides()
        #endif
    }

    /// Personalized quiz/history text always stays on-device.
    func read(_ text: String) {
        stop(); status = "On-device voice"
        speakLocally(text)
    }

    /// Only a public, fixed script ID is sent to the optional proxy. Never user text.
    /// Plays saved audio instantly. Otherwise fetches it (patiently), or for a `timed` cue, which would be
    /// late by the time it arrived, speaks the fallback on-device right away. Pair timed cues with `prefetch`.
    func readScript(_ script: String, fallback: String, timed: Bool = false) {
        stop()
        guard let connection = Self.connection() else {
            status = "Grok is off, using on-device voice"
            speakLocally(fallback)
            return
        }
        if let bytes = VoiceCache.data(for: script), play(bytes) { status = "Grok voice (saved)"; return }
        if timed {
            status = "Grok not ready, using on-device voice"
            speakLocally(fallback)
            return
        }
        status = "Loading Grok voice"
        task = Task {
            do {
                let bytes = try await Self.fetch(script, from: connection.url, token: connection.token, timeout: Self.patientTimeout)
                try Task.checkCancellation()
                guard UserDefaults.standard.bool(forKey: "voice.grokEnabled") else { throw VoiceError.unavailable }
                VoiceCache.store(bytes, for: script)
                guard play(bytes) else { throw VoiceError.unavailable }
                status = "Grok voice"
            } catch {
                guard !Task.isCancelled else { return }
                status = "Grok unavailable, using on-device voice"
                speakLocally(fallback)
            }
        }
    }

    /// Downloads scripts into the on-disk cache ahead of time, so `readScript` plays them instantly.
    /// Does nothing when Grok is off or a script is already saved. Keeps running after `stop()`.
    func prefetch(_ scripts: [String]) {
        guard let connection = Self.connection() else { return }
        let missing = scripts.filter { VoiceCache.data(for: $0) == nil && !Self.prefetching.contains($0) }
        guard !missing.isEmpty else { return }
        Self.prefetching.formUnion(missing)
        Task {
            await withTaskGroup(of: (String, Data?).self) { group in
                for script in missing {
                    group.addTask { (script, try? await Self.fetch(script, from: connection.url, token: connection.token, timeout: Self.patientTimeout)) }
                }
                for await (script, bytes) in group {
                    if let bytes { VoiceCache.store(bytes, for: script) }
                    Self.prefetching.remove(script)
                }
            }
        }
    }

    func stop() { task?.cancel(); task = nil; line = nil; player?.stop(); player = nil; synthesizer.stopSpeaking(at: .immediate) }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { ended(utterance) }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { ended(utterance) }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { ended(player) }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) { ended(player) }

    /// A call or alarm pauses playback with no finish callback, so an interruption ends the line for good.
    @objc nonisolated private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor in self.stop() }
    }

    /// AVFoundation may call back off the main thread; only the current line clears `isSpeaking`.
    nonisolated private func ended(_ object: AnyObject) {
        let id = ObjectIdentifier(object)
        Task { @MainActor in
            if let line, ObjectIdentifier(line) == id { self.line = nil }
        }
    }

    private struct Connection: Sendable { let url: URL; let token: String }

    private static func connection() -> Connection? {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "voice.grokEnabled"),
              let url = VoiceConnection.validURL(defaults.string(forKey: "voice.proxyURL") ?? ""),
              let token = VoiceConnection.token(), token.count >= 24 else { return nil }
        return Connection(url: url, token: token)
    }

    nonisolated private static func fetch(_ script: String, from url: URL, token: String, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["script_id": script])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        // Bound response memory even if a configured proxy is misbehaving.
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "audio/mpeg", response.expectedContentLength <= maxAudioBytes else { throw VoiceError.unavailable }
        var bytes = Data()
        for try await byte in stream {
            guard bytes.count < maxAudioBytes else { throw VoiceError.unavailable }
            bytes.append(byte)
        }
        guard !bytes.isEmpty else { throw VoiceError.unavailable }
        return bytes
    }

    private func play(_ bytes: Data) -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            let audio = try AVAudioPlayer(data: bytes)
            audio.delegate = self
            player = audio
            guard audio.play() else { return false }
            line = audio
            return true
        } catch { return false }
    }

    private func speakLocally(_ text: String) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        // Default rate and pitch: the voice quality matters far more than tweaking them.
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestLocalVoice()
        line = utterance
        synthesizer.speak(utterance)
    }

    /// The highest-quality installed English voice (premium, then enhanced, then compact), preferring en-US.
    /// Novelty and Eloquence voices are skipped.
    private static func bestLocalVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.hasPrefix("en") && !$0.identifier.contains("speech.synthesis.voice") && !$0.identifier.contains("eloquence")
        }
        let best = english.max { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality.rawValue < rhs.quality.rawValue }
            return lhs.language != "en-US" && rhs.language == "en-US"
        }
        return best ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    private enum VoiceError: Error { case unavailable }
}

/// Reading, narration and optional Grok voice proxy settings. Shown as a sheet from onboarding and the tabs.
struct GuidanceSettingsView: View {
    @AppStorage("accessibility.voiceGuidance") private var automaticNarration = false
    @AppStorage("accessibility.readingFriendly") private var readingFriendly = false
    @AppStorage("accessibility.audioCues") private var audioCues = false
    @AppStorage(MeasurementUnit.storageKey) private var lengthUnit = MeasurementUnit.localeDefault()
    @AppStorage("voice.grokEnabled") private var grokEnabled = false
    @AppStorage("voice.proxyURL") private var savedURL = ""
    private enum ConnectionField: Hashable { case url, token }
    @FocusState private var focusedField: ConnectionField?
    @State private var hasSavedToken = false
    @State private var proxyURL = ""
    @State private var proxyToken = ""
    @State private var error: String?
    @State private var voice = GuidanceVoice()
    @Environment(\.dismiss) private var dismiss
    private var configured: Bool { VoiceConnection.validURL(savedURL) != nil && hasSavedToken }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Read steps aloud", isOn: $automaticNarration)
                    Toggle("Reading-friendly type", isOn: $readingFriendly)
                    Toggle("Audio cues", isOn: $audioCues)
                    Picker("Length units", selection: $lengthUnit) {
                        ForEach(MeasurementUnit.allCases) { Text($0.symbol).tag($0) }
                    }
                    .accessibilityIdentifier("settings.units")
                }
                .listRowBackground(Color.surface)

                Section {
                    Toggle("Grok voice", isOn: $grokEnabled)
                        .disabled(!configured)
                        .accessibilityIdentifier("settings.grok")
                    Button {
                        voice.readScript("welcome", fallback: "Welcome to Archy. Let's take this one step at a time.")
                    } label: {
                        HStack {
                            Text("Test voice")
                            Spacer()
                            Text(voice.status).font(.footnote).foregroundStyle(.inkTertiary)
                        }
                    }
                    .accessibilityIdentifier("settings.testVoice")
                } header: {
                    sectionHeader("Voice")
                } footer: {
                    Text("Grok sends only fixed instruction IDs to your service. Your answers, photos and audio stay on this iPhone.\n\nFor a more natural on-device voice, download an Enhanced or Premium voice in iOS Settings, Accessibility, Spoken Content.")
                }
                .listRowBackground(Color.surface)

                Section {
                    TextField("https://your-service/narrate", text: $proxyURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focusedField, equals: .url)
                        .accessibilityIdentifier("settings.proxyURL")
                    SecureField("Access token", text: $proxyToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .token)
                        .accessibilityIdentifier("settings.proxyToken")
                    Button("Save", action: saveConnection)
                    Button("Remove", role: .destructive, action: removeConnection)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.negative)
                    }
                } header: {
                    sectionHeader("Voice proxy")
                } footer: {
                    Text("The token is stored in Keychain. Keep the xAI key on your server.")
                }
                .listRowBackground(Color.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { voice.stop(); dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }.accessibilityIdentifier("settings.keyboardDone")
                }
            }
            .onAppear { proxyURL = savedURL; proxyToken = VoiceConnection.token() ?? ""; hasSavedToken = proxyToken.count >= 24 }
            .onChange(of: grokEnabled) { _, _ in voice.stop() }
            .onDisappear { voice.stop() }
        }
        .archyScreen()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.medium)).textCase(nil).foregroundStyle(.inkSecondary)
    }

    private func saveConnection() {
        let text = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoiceConnection.validURL(text) != nil, proxyToken.count >= 24 else {
            error = "Needs an HTTPS /narrate URL and a token of 24+ characters."
            return
        }
        guard VoiceConnection.saveToken(proxyToken) else { error = "Couldn't save the token to Keychain."; return }
        savedURL = text; hasSavedToken = true; grokEnabled = false; error = nil
    }

    private func removeConnection() {
        voice.stop()
        grokEnabled = false; savedURL = ""; proxyURL = ""; proxyToken = ""
        VoiceConnection.clearToken(); hasSavedToken = false; error = nil
    }
}
