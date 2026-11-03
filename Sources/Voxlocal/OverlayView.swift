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

/// The floating pill. It stays centered in its (transparent, click-through) panel.
struct OverlayView: View {
    let state: DictationState
    let settings: OverlaySettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .frame(maxWidth: OverlayLayout.maxPillWidth)
        .fixedSize(horizontal: true, vertical: false)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: state.phase)
    }

    @ViewBuilder private var content: some View {
        switch state.phase {
        case .idle:
            EmptyView()
        case .listening:
            PulsingDot(color: .red, reduceMotion: reduceMotion)
            LevelMeter(level: state.level)
            Text("Listening")
        case .transcribing:
            Image(systemName: "waveform").foregroundStyle(.secondary)
            if settings.showPartialText, !state.partialText.isEmpty {
                Text(DictationState.tail(state.partialText))
                    .foregroundStyle(.secondary)
                    .truncationMode(.head)
                    .frame(maxWidth: OverlayLayout.maxPillWidth - 60, alignment: .leading)
            } else {
                Text("Transcribing…")
            }
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
    static let pillPanelSize = CGSize(width: 340, height: 44)
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
