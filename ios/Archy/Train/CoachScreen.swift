import SwiftUI
import AudioToolbox

/// Where a coach session is: idle before Start, a lead-in (the setup read aloud, then 3, 2, 1), then
/// alternating hold and rest until done.
enum CoachPhase: Hashable { case idle, ready, hold, rest, done }

/// The words, scripts and numbers that make one practice different from another.
struct CoachProgram {
    let roundName: String
    let idleTitle: String
    let idleDetail: String
    let readyDetail: String
    let holdTitle: String
    let restTitle: String
    let holdDetail: (Int) -> String
    let restDetail: (Int) -> String
    let safety: String
    let finishedFact: String
    let setup: (script: String, text: String)
    let hold: (script: String, text: String)
    let rest: (script: String, text: String)
    let complete: (script: String, text: String)

    func title(_ phase: CoachPhase) -> String {
        switch phase {
        case .idle: idleTitle
        case .ready: "Get ready"
        case .hold: holdTitle
        case .rest: restTitle
        case .done: ""
        }
    }

    func detail(_ phase: CoachPhase, round: Int) -> String {
        switch phase {
        case .idle: idleDetail
        case .ready: readyDetail
        case .hold: holdDetail(round)
        case .rest: restDetail(round)
        case .done: ""
        }
    }

    func narration(_ phase: CoachPhase) -> (script: String, text: String)? {
        switch phase {
        case .idle: nil
        case .ready: setup
        case .hold: hold
        case .rest: rest
        case .done: complete
        }
    }
}

/// The full-bleed coach: huge countdown in a ring, the movement diagram above it, one control below.
/// Both exercises are this screen with a different program, timeline and diagram.
struct CoachScreen<Session: PracticeTimeline, Diagram: View>: View {
    let program: CoachProgram
    @ViewBuilder let diagram: (CoachPhase, Int) -> Diagram

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("accessibility.voiceGuidance") private var narration = false
    @AppStorage("accessibility.audioCues") private var audioCues = false
    @State private var voice = GuidanceVoice()
    @State private var session: Session
    @State private var started: Bool
    @State private var running: Bool
    @State private var lead = 0
    /// True from Start until the setup script has been read to the end. The lead-in waits for it.
    @State private var briefing = false
    /// True while this coach is the one keeping the screen awake (see `keepAwake`).
    @State private var holdsScreenAwake = false

    private static var leadSeconds: Int { 3 }

    /// `session` and `running` let a debug launch drop straight into the middle of a practice.
    init(program: CoachProgram, session: Session = Session(), running: Bool = false,
         @ViewBuilder diagram: @escaping (CoachPhase, Int) -> Diagram) {
        self.program = program
        self.diagram = diagram
        _session = State(initialValue: session)
        _started = State(initialValue: running)
        _running = State(initialValue: running)
    }

    private var phase: CoachPhase {
        guard started else { return .idle }
        if lead > 0 { return .ready }
        switch session.step {
        case .hold: return .hold
        case .rest: return .rest
        case .done: return .done
        }
    }
    private var stepKey: String { "\(phase)-\(session.round)" }
    private var paused: Bool { started && !running && phase != .done }
    private var seconds: Int { phase == .ready ? lead : session.secondsRemaining }

    /// Fraction of the current step finished once the displayed second runs out.
    private var ringProgress: Double {
        switch phase {
        case .idle, .done: return 0
        case .ready: return briefing ? 0 : Double(Self.leadSeconds - lead + 1) / Double(Self.leadSeconds)
        case .hold, .rest: return Double(session.stepSeconds - session.secondsRemaining + 1) / Double(session.stepSeconds)
        }
    }

    var body: some View {
        ZStack {
            if phase == .done {
                CoachCompletion(fact: program.finishedFact) { dismiss() }
                    .transition(.opacity.combined(with: reduceMotion ? .identity : .scale(scale: 0.96)))
            } else {
                coach.transition(.opacity)
            }
        }
        .animation(Motion.playful.reduced(reduceMotion), value: phase == .done)
        .archyScreen()
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: stepKey) { _, _ in phase != .done }
        .task(id: running && !briefing) {
            guard running, !briefing else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard running, scenePhase == .active else { return }
                keepAwake(true)
                advance()
                if phase == .done { running = false; return }
            }
        }
        // The setup finished, or read aloud was turned off, while running: start the 3-2-1.
        .onChange(of: running && briefing && !voice.isSpeaking) { _, heard in if heard { briefing = false } }
        .onChange(of: running, initial: true) { _, value in keepAwake(value) }
        .onChange(of: scenePhase) { _, value in if value != .active { stop() } }
        .onChange(of: narration) { _, enabled in if enabled { prefetchCues() } else { voice.stop() } }
        .onAppear { if narration { prefetchCues() } }
        .onDisappear { stop(); keepAwake(false) }
    }

    private var coach: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    topBar
                    CoachSegments(total: Session.rounds, completed: started ? session.round - 1 : 0, started: started)
                        .padding(.top, Space.sm)
                    Spacer(minLength: Space.lg)
                    diagram(phase, session.round)
                        .animation(Motion.smooth.reduced(reduceMotion), value: stepKey)
                        .frame(height: 170)
                    Spacer(minLength: Space.lg)
                    ring
                    Spacer(minLength: Space.lg)
                    instruction
                    Spacer(minLength: Space.lg)
                    control
                    Text(program.safety)
                        .font(.footnote)
                        .foregroundStyle(.inkTertiary)
                        .padding(.top, Space.md)
                        .padding(.bottom, Space.sm)
                }
                .padding(.horizontal, Space.page)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.medium)).frame(width: 44, height: 44)
            }
            .buttonStyle(.archyGhost)
            .foregroundStyle(.inkSecondary)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("coach.close")
            Spacer()
            Text("\(program.roundName) \(session.round) of \(Session.rounds)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.inkSecondary)
                .contentTransition(.numericText())
                .animation(Motion.snappy.reduced(reduceMotion), value: session.round)
            Spacer()
            CoachSoundMenu()
        }
    }

    private var ring: some View {
        ZStack {
            CoachRing(progress: ringProgress).id(stepKey).transition(.opacity)
            MetricText(value: Double(seconds), style: .giant)
        }
        .frame(width: 224, height: 224)
        .opacity(paused ? 0.4 : 1)
        .animation(Motion.smooth.reduced(reduceMotion), value: stepKey)
        .animation(Motion.snappy.reduced(reduceMotion), value: paused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(seconds) seconds")
    }

    private var instruction: some View {
        ZStack {
            VStack(spacing: Space.sm) {
                Text(program.title(phase)).display(.title)
                Text(program.detail(phase, round: session.round))
                    .font(.body).foregroundStyle(.inkSecondary)
            }
            .multilineTextAlignment(.center)
            .id(stepKey)
            .transition(reduceMotion ? .opacity : .step)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .top)
        .animation(Motion.smooth.reduced(reduceMotion), value: stepKey)
    }

    private var control: some View {
        Button(action: toggle) {
            Label(running ? "Pause" : started ? "Resume" : "Start", systemImage: running ? "pause.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
                .animation(Motion.snappy.reduced(reduceMotion), value: running)
        }
        .buttonStyle(.archyPrimary)
        .accessibilityIdentifier(running ? "coach.pause" : "coach.start")
    }

    private func toggle() {
        if running { stop(); return }
        if !started {
            started = true
            lead = Self.leadSeconds
            briefing = narration
            announce()
        } else if briefing {
            announce() // Paused mid-setup: read it again from the top.
        }
        running = true
    }

    private func advance() {
        let before = phase
        if lead > 0 { lead -= 1 } else { session.tick() }
        if phase != before { announce() }
    }

    private func stop() { running = false; voice.stop() }

    /// Hands-free practice keeps the screen from locking while it runs. The flag is app-wide and Scan sets
    /// it while a model builds, so the coach only clears it when it set it, and takes it back if it was cleared.
    private func keepAwake(_ awake: Bool) {
        let app = UIApplication.shared
        if awake, !app.isIdleTimerDisabled {
            app.isIdleTimerDisabled = true
            holdsScreenAwake = true
        } else if !awake, holdsScreenAwake {
            app.isIdleTimerDisabled = false
            holdsScreenAwake = false
        }
    }

    /// Saves every cue for this session up front. Cues are timed, so they play from the cache or not at all.
    private func prefetchCues() {
        voice.prefetch([program.setup, program.hold, program.rest, program.complete].map(\.script))
    }

    private func announce() {
        if audioCues { AudioServicesPlaySystemSound(1104) }
        guard narration, let line = program.narration(phase) else { return }
        voice.readScript(line.script, fallback: line.text, timed: true)
    }
}

/// The speaker menu with read aloud and sound cues. It has no inputs and owns its settings, so the
/// coach's once-a-second countdown never rebuilds it while it is open.
private struct CoachSoundMenu: View {
    @AppStorage("accessibility.voiceGuidance") private var narration = false
    @AppStorage("accessibility.audioCues") private var audioCues = false

    var body: some View {
        Menu {
            Toggle("Read aloud", isOn: $narration)
            Toggle("Sound cues", isOn: $audioCues)
        } label: {
            Image(systemName: narration || audioCues ? "speaker.wave.2" : "speaker.slash")
                .font(.body.weight(.medium)).frame(width: 44, height: 44)
        }
        .foregroundStyle(.inkSecondary)
        .accessibilityLabel("Sound")
        .accessibilityValue(narration || audioCues ? "On" : "Off")
        .accessibilityIdentifier("coach.sound")
    }
}

/// Determinate countdown ring. Mount it afresh for each step (via `.id`) so it sweeps from empty.
private struct CoachRing: View {
    let progress: Double
    @State private var shown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().stroke(Color.line2, lineWidth: 6)
            Circle().trim(from: 0, to: shown)
                .stroke(Color.ink, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(shown > 0 ? 1 : 0)
        }
        .animation(reduceMotion ? Motion.fade : .linear(duration: 1), value: shown)
        .onAppear { shown = progress }
        .onChange(of: progress) { _, value in shown = value }
    }
}

/// One thin segment per rep or hold: finished in ink, current softer, upcoming faint.
private struct CoachSegments: View {
    let total: Int
    let completed: Int
    let started: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index < completed ? Color.ink : index == completed && started ? Color.inkSecondary : Color.line2)
                    .frame(height: 4)
            }
        }
        .animation(Motion.snappy.reduced(reduceMotion), value: completed)
        .accessibilityHidden(true)
    }
}

/// The rare finish moment: a brand ring closes around a check with a playful spring and a success tap.
struct CoachCompletion: View {
    let fact: String
    let onDone: () -> Void
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Space.xl) {
            Spacer()
            ZStack {
                Circle().stroke(Color.line2, lineWidth: 6)
                Circle().trim(from: 0, to: appeared ? 1 : 0)
                    .stroke(Color.brand, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checkmark")
                    .font(.system(size: 72, weight: .semibold))
                    .foregroundStyle(.ink)
                    .scaleEffect(appeared || reduceMotion ? 1 : 0.9)
                    .opacity(appeared ? 1 : 0)
                    .symbolEffect(.bounce, value: appeared)
            }
            .frame(width: 200, height: 200)
            .accessibilityHidden(true)
            VStack(spacing: Space.sm) {
                Text("Nice work").display(.hero)
                Text(fact).font(.body).foregroundStyle(.inkSecondary)
            }
            .multilineTextAlignment(.center)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduceMotion ? 0 : 10)
            Spacer()
            Button("Done", action: onDone)
                .buttonStyle(.archyPrimary)
                .accessibilityIdentifier("coach.done")
                .padding(.bottom, Space.sm)
        }
        .padding(.horizontal, Space.page)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .sensoryFeedback(.success, trigger: appeared) { _, shown in shown }
        .onAppear { withAnimation(Motion.playful.reduced(reduceMotion)) { appeared = true } }
    }
}
