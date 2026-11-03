import SwiftUI
import VoxlocalCore

/// Display preferences the overlay reads; toggled from the menu.
@MainActor
@Observable
final class OverlaySettings {
    var showPill: Bool { didSet { save() } }
    var showCaret: Bool { didSet { save() } }
    var showPartialText: Bool { didSet { save() } }

    init() {
        let d = UserDefaults.standard
        showPill = d.object(forKey: "overlay.showPill") as? Bool ?? true
        showCaret = d.object(forKey: "overlay.showCaret") as? Bool ?? true
        showPartialText = d.object(forKey: "overlay.showPartialText") as? Bool ?? true
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(showPill, forKey: "overlay.showPill")
        d.set(showCaret, forKey: "overlay.showCaret")
        d.set(showPartialText, forKey: "overlay.showPartialText")
    }
}

/// Where the pill sits inside its taller, transparent panel: against the caret side, so it
/// stays snug under (or over) the caret whether it has one row or two.
@MainActor
@Observable
final class OverlayPlacement {
    var belowCaret = true
}

/// The floating pill: a status row, plus the live transcript underneath while you speak.
struct OverlayView: View {
    let state: DictationState
    let settings: OverlaySettings
    let placement: OverlayPlacement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) { statusRow }
                .frame(height: 16)
            if let text = liveText {
                LiveTextView(text: text)
                    .frame(width: OverlayLayout.maxPillWidth - 24, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: OverlayLayout.maxPillWidth)
        .fixedSize()
        .background(.regularMaterial, in: shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: placement.belowCaret ? .top : .bottom)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.phase)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: liveText == nil)
    }

    /// One row reads as a capsule; two rows as a rounded rectangle with the same corners.
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 15, style: .continuous) }

    /// Transcript text to show under the status row, if any.
    private var liveText: String? {
        guard settings.showPartialText, !state.partialText.isEmpty else { return nil }
        switch state.phase {
        case .listening, .transcribing: return state.partialText
        default: return nil
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch state.phase {
        case .idle:
            EmptyView()
        case .listening:
            PulsingDot(color: .red, reduceMotion: reduceMotion)
            LevelMeter(level: state.level)
            Text("Listening")
        case .transcribing:
            Image(systemName: "waveform").foregroundStyle(.secondary)
            Text("Transcribing…")
        case .polishing:
            if reduceMotion {
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Text("Polishing…")
            Image(systemName: "icloud.and.arrow.up")
                .foregroundStyle(.secondary)
                .help("Transcript text was sent to Claude")
                .accessibilityLabel("Sent to Claude")
        case .pasted(let raw):
            Image(systemName: raw ? "checkmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(raw ? .orange : .green)
            Text(raw ? "Pasted raw" : "Pasted")
        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message)
                .truncationMode(.tail)
                .frame(maxWidth: OverlayLayout.maxPillWidth - 60, alignment: .leading)
        }
    }
}

/// The newest words of the transcript, up to two lines: settled words in the secondary
/// color, the last few (still likely to change) fainter.
private struct LiveTextView: View {
    let text: String

    var body: some View {
        let parts = DictationState.liveParts(DictationState.tail(text, limit: OverlayLayout.liveTextCharacters))
        (Text(parts.settled.isEmpty ? "" : parts.settled + " ").foregroundStyle(.secondary)
            + Text(parts.tentative).foregroundStyle(.tertiary))
            .font(.system(size: 12))
            .lineLimit(2)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .accessibilityLabel("Live transcript: \(text)")
    }
}

/// The small dot drawn just right of the caret while a dictation is active.
struct CaretDotView: View {
    let state: DictationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PulsingDot(color: color, reduceMotion: reduceMotion)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var color: Color {
        switch state.phase {
        case .listening: return .red
        case .polishing: return .purple
        case .pasted(let raw): return raw ? .orange : .green
        case .error: return .yellow
        default: return .accentColor
        }
    }
}

enum OverlayLayout {
    static let maxPillWidth: CGFloat = 320
    /// Tall enough for the status row plus two lines of live text, with room for the shadow.
    static let pillPanelSize = CGSize(width: 340, height: 84)
    /// How much of the newest transcript the pill shows (about two lines).
    static let liveTextCharacters = 90
    static let dotPanelSize = CGSize(width: 16, height: 16)
}

private struct PulsingDot: View {
    let color: Color
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            dot(pulse: 0)
        } else {
            // Time-driven rather than @State-driven, so it needs no SwiftUI macros.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                dot(pulse: (sin(t * .pi / 0.6) + 1) / 2)
            }
        }
    }

    private func dot(pulse: Double) -> some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(1 + 0.35 * pulse)
            .opacity(1 - 0.45 * pulse)
    }
}

private struct LevelMeter: View {
    let level: Float
    private let bars = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                let threshold = Float(i) / Float(bars)
                Capsule()
                    .fill(level > threshold ? Color.primary.opacity(0.85) : Color.primary.opacity(0.2))
                    .frame(width: 3, height: 6 + CGFloat(i) * 2.5)
            }
        }
        .frame(height: 18)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}
