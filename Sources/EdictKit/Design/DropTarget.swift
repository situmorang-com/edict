//
//  DropTarget.swift
//  EdictKit — Design
//
//  Dropping a file on the window is not a new screen. It is a *state of the existing chassis*:
//  the deck dims, a machined opening appears where the lid would be, and one silkscreened
//  legend says what will happen. Nothing here invents a visual language — the plate is a
//  `PanelSurface(.plastic)` carrying a `RecessedWell(.display)`, exactly like the transport
//  block, and the refusal uses the same hollow-square-in-alert-ink vocabulary as the
//  attention banner and the "may be incomplete" flag.
//
//  Call-site shape:
//
//      MainWindow()
//          .dropTarget { urls in model.importQueue.enqueue(urls) }
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Metrics

/// Geometry that belongs to this component and is not a design token, written as multiples of
/// tokens so the relationship survives a token change.
private enum M {
    /// The plate is a hair wider than the VU meter's housing, so the two read as parts of the
    /// same machine rather than as a dialog laid over one.
    static let plateWidth = D.size.meterSize.width * 1.5          // 348
    /// The cassette slot. Three trough-heights: at two it read as an empty text field rather
    /// than as an aperture — checked in the render, not guessed.
    static let slotHeight = D.size.troughHeight * 3               // 18
    /// How far the machined opening is inset from the window's own edge.
    static let openingInset = D.space.md
    /// The refusal mark, matching `AttentionBanner`'s hollow square.
    static let markSize = D.size.troughHeight * 2                 // 12
}

// MARK: - ImportableMedia

/// What Edict will read from disk.
///
/// The list is deliberately explicit rather than just `[.audiovisualContent]`: the engine opens
/// files with `AVAssetReader`, which handles video containers as well as audio, and naming the
/// concrete types is what lets a drag be classified as valid or invalid *while it is still in
/// flight* — `DropInfo` can answer conformance questions but cannot read a URL.
public enum ImportableMedia {

    /// Accepted content types, widest first. `.audio` and `.movie` already cover the four
    /// concrete types after them; those are listed anyway because a provider that registers only
    /// `public.mp3` and no umbrella type still has to match.
    public static let contentTypes: [UTType] = [
        .audio,
        .movie,
        .mpeg4Movie,
        .quickTimeMovie,
        .mp3,
        .wav,
        .aiff,
        .mpeg4Audio,
    ]

    /// The same list in words, for the plate and the empty queue. Not generated from
    /// `contentTypes` — `localizedDescription` produces "MPEG-4 movie", which is longer and
    /// less recognisable than the extension a user actually sees in Finder.
    public static let plainFormatList = "MP3 · WAV · AIFF · M4A · MP4 · MOV"

    /// One plain sentence naming what the window takes. Used in more than one place, so it is
    /// written once.
    public static let plainDescription = "an audio or video file"

    /// Whether a concrete URL is something the engine can open.
    ///
    /// Authoritative, unlike the in-flight check: it asks the file system for the real content
    /// type and only falls back to the extension when the file cannot be stat'ed (a promised
    /// file, a URL for something not yet on disk).
    public static func accepts(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
        if values?.isDirectory == true { return false }
        if let type = values?.contentType { return conforms(type) }
        guard let byExtension = UTType(filenameExtension: url.pathExtension) else { return false }
        return conforms(byExtension)
    }

    private static func conforms(_ type: UTType) -> Bool {
        contentTypes.contains { type.conforms(to: $0) }
    }
}

// MARK: - DropPhase

/// What the window is currently being offered.
///
/// A separate value rather than a `Bool` because "a drag is over the window" and "the drag is
/// something we can use" are different facts, and the second one is the whole point: a target
/// that lights up for every drag and then silently swallows a PDF is worse than no target.
public enum DropPhase: Hashable, Sendable {
    /// No drag over the window.
    case idle
    /// A drag carrying files we can transcribe. `fileCount` is what the plate prints.
    case ready(fileCount: Int)
    /// A drag we will refuse. The cursor shows it too — see `DropProposal(.forbidden)`.
    case refused

    var isActive: Bool { self != .idle }
}

// MARK: - DropCurtain

/// The chassis in its drop state. Rendered as its own view, and `public`, so the offline layout
/// harness can rasterise all three phases — a state that only exists while a mouse button is
/// physically held down is otherwise unreviewable.
public struct DropCurtain: View {

    private let phase: DropPhase

    @Environment(\.edictIncreasedContrast) private var increasedContrast

    public init(_ phase: DropPhase) {
        self.phase = phase
    }

    public var body: some View {
        ZStack {
            if phase.isActive {
                D.surface.scrim
                    .ignoresSafeArea()

                // The lid, opened. A rounded opening drawn with `recessedEdge` (dark on top,
                // light underneath) inset from the window's own corner radius, so the whole face
                // reads as a hatch rather than as a dialog with a border.
                RoundedRectangle(cornerRadius: D.radius.chassis, style: .continuous)
                    .strokeBorder(
                        D.surface.recessedEdge,
                        lineWidth: increasedContrast ? D.border.heavy : D.border.bezel
                    )
                    .padding(M.openingInset)

                plate
            }
        }
        .allowsHitTesting(false)
        .transition(.opacity)
        .animation(D.motion.panel, value: phase)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(!phase.isActive)
        .accessibilityLabel(headline)
        .accessibilityValue(caption)
    }

    // MARK: The plate

    /// `.painted`, not `.plastic`. A matte black insert is the right material for a control block,
    /// but the plate sits on top of `D.surface.scrim` — which is near-black in *both* appearances —
    /// and in the dark appearance the render showed a black plate on a black ground, held together
    /// only by its contact shadow. A painted panel is the one material that is lighter than the
    /// scrim in both appearances, so the plate reads as lit while the chassis behind it is dimmed.
    private var plate: some View {
        PanelSurface(material: .painted, inset: D.space.md) {
            VStack(alignment: .leading, spacing: D.space.md) {
                slot

                // The legend sits in a lit display window, which is what makes `displayInk` the
                // correct ink for it without the call site choosing a colour.
                RecessedWell(fill: .display, radius: D.radius.tight, inset: D.space.sm) {
                    HStack(spacing: D.space.sm) {
                        if phase == .refused {
                            Rectangle()
                                .strokeBorder(D.color.alert, lineWidth: D.border.medium)
                                .frame(width: M.markSize, height: M.markSize)
                        }
                        legend
                        Spacer(minLength: 0)
                    }
                }

                VStack(alignment: .leading, spacing: D.space.xs) {
                    Text(caption)
                        .typeStyle(D.type.explain)
                        .foregroundStyle(D.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    // The accepted formats are a printed spec line, not part of the sentence:
                    // inline, the list wrapped mid-way through ("MP3 ·" / "WAV · AIFF · …"), which
                    // reads as a typo.
                    SilkscreenLabel(ImportableMedia.plainFormatList, weight: .tiny)
                        .silkscreenDecorative()
                }
            }
        }
        .frame(width: M.plateWidth)
        .shadow(D.shadow.hud)
    }

    /// The slot a cassette would go into: an empty display well, full width, two troughs tall.
    /// It carries no text and no glyph — the aperture is the affordance.
    private var slot: some View {
        RecessedWell(fill: .display, radius: D.radius.tight, inset: 0) {
            Color.clear.frame(height: M.slotHeight)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var legend: some View {
        switch phase {
        case .refused:
            // Built by hand rather than with `SilkscreenLabel`, which fixes its own ink: this is
            // the one silkscreen line in the app that is printed in the alert colour.
            Text(headline)
                .typeStyle(D.type.silkscreenHeading)
                .foregroundStyle(D.color.alert)
                .lineLimit(1)
                .dynamicTypeSize(.large)
        default:
            SilkscreenLabel(headline, weight: .heading)
        }
    }

    // MARK: Strings

    /// Natural case; `D.type.silkscreenHeading` does the shouting (spec §0.2), which is also what
    /// keeps VoiceOver from spelling it out letter by letter.
    private var headline: String {
        switch phase {
        case .idle, .ready(1): "Drop to transcribe"
        case .ready(let count): "Drop \(count) files to transcribe"
        case .refused: "Not audio or video"
        }
    }

    private var caption: String {
        switch phase {
        case .refused:
            return "Edict reads \(ImportableMedia.plainDescription). Folders and other documents "
                + "cannot be opened."
        default:
            return "The transcript lands in HISTORY, not at the cursor."
        }
    }
}

// MARK: - DropTarget

/// Makes the whole window a target for audio and video files.
///
/// Applied once, to the window's root, rather than to the import pane: a user who has just
/// dropped a recording on a dictation app is not going to select the right rail stop first, and
/// a target that only exists on one pane is a target the user cannot find.
public struct DropTarget: ViewModifier {

    private let isEnabled: Bool
    private let onFiles: ([URL]) -> Void

    @State private var phase: DropPhase = .idle

    /// - Parameters:
    ///   - isEnabled: `false` refuses everything and draws nothing. For a window that cannot
    ///     accept work yet — no speech model, say.
    ///   - onFiles: the accepted URLs, in the order the drag carried them. Only files that pass
    ///     `ImportableMedia.accepts(_:)` are delivered; the rest are dropped silently, because
    ///     the refusal has already been shown on the plate and in the cursor.
    public init(isEnabled: Bool = true, onFiles: @escaping ([URL]) -> Void) {
        self.isEnabled = isEnabled
        self.onFiles = onFiles
    }

    public func body(content: Content) -> some View {
        content
            .overlay { DropCurtain(phase) }
            // `.fileURL` is in the list, not just the media types: a drag we intend to *refuse*
            // has to reach us in the first place, and a target registered for audio alone never
            // hears about the PDF. Classification then happens in `dropUpdated`.
            .onDrop(
                of: ImportableMedia.contentTypes + [.fileURL],
                delegate: MediaDropDelegate(
                    isEnabled: isEnabled,
                    phase: $phase,
                    onFiles: onFiles
                )
            )
    }
}

public extension View {
    /// Makes this view a drop target for audio and video files. See `DropTarget`.
    func dropTarget(isEnabled: Bool = true, onFiles: @escaping ([URL]) -> Void) -> some View {
        modifier(DropTarget(isEnabled: isEnabled, onFiles: onFiles))
    }
}

// MARK: - The delegate

/// `DropDelegate` rather than `dropDestination(for: URL.self)`, for one reason: `dropDestination`
/// reports only *whether* a drag is over the view, so an invalid drag is indistinguishable from a
/// valid one until the user has already let go. The delegate gets a `DropInfo`, which can answer
/// `hasItemsConforming(to:)` mid-flight — and it can return
/// `DropProposal(operation: .forbidden)`, which is what puts the system's own refusal cursor
/// under the pointer instead of a promise Edict would then break.
///
/// `DropDelegate` is `@MainActor` in the SDK, so every method here is main-actor isolated and the
/// `@Binding` write is legal without any hopping.
private struct MediaDropDelegate: DropDelegate {

    let isEnabled: Bool
    @Binding var phase: DropPhase
    let onFiles: ([URL]) -> Void

    /// Always `true` when enabled — even for a drag we mean to refuse. Returning `false` here
    /// would take the window out of the drag session entirely, and then there is nothing to draw
    /// the refusal on.
    func validateDrop(info: DropInfo) -> Bool { isEnabled }

    func dropEntered(info: DropInfo) {
        phase = classify(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let next = classify(info)
        // Written unconditionally would re-publish the same value on every mouse move; SwiftUI
        // coalesces, but the animation attached to `phase` restarts, which reads as a flicker.
        if next != phase { phase = next }
        return DropProposal(operation: next == .refused ? .forbidden : .copy)
    }

    func dropExited(info: DropInfo) {
        phase = .idle
    }

    func performDrop(info: DropInfo) -> Bool {
        phase = .idle
        guard isEnabled, classify(info) != .refused else { return false }

        let providers = info.itemProviders(for: ImportableMedia.contentTypes + [.fileURL])
        guard !providers.isEmpty else { return false }
        load(providers, then: onFiles)
        return true
    }

    // MARK: Classification

    private func classify(_ info: DropInfo) -> DropPhase {
        guard isEnabled else { return .refused }
        guard info.hasItemsConforming(to: ImportableMedia.contentTypes) else { return .refused }
        let count = info.itemProviders(for: ImportableMedia.contentTypes).count
        return .ready(fileCount: max(count, 1))
    }

    // MARK: Reading the URLs

    /// Resolves each provider to a file URL, in order, then delivers the ones the engine can
    /// actually open.
    ///
    /// Sequential rather than a `TaskGroup`: a drag is a handful of files, and order is what the
    /// user sees in the queue. `loadObject(ofClass: URL.self)` is used instead of
    /// `loadItem(forTypeIdentifier:)` because it hands back a `Sendable` `URL` — the `NSURL` the
    /// raw item API produces is not `Sendable` and cannot legally cross back to the main actor
    /// under Swift 6.
    @MainActor
    private func load(_ providers: [NSItemProvider], then deliver: @escaping ([URL]) -> Void) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                guard let url = await Self.fileURL(from: provider) else { continue }
                guard ImportableMedia.accepts(url) else {
                    Log.data.notice("Refused a dropped file that is not audio or video.")
                    continue
                }
                // A drag of several files arrives as one provider per file, so the only duplicates
                // here are a genuine double-registration of the same URL.
                if !urls.contains(url) { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            deliver(urls)
        }
    }

    /// The provider's file URL, or `nil` if it could not be read.
    ///
    /// `loadObject` calls back on an arbitrary queue, so the only thing captured by its handler is
    /// the continuation — everything main-actor isolated stays outside it.
    @MainActor
    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let error {
                    Log.data.error(
                        "Could not read a dropped file's URL: \(error.localizedDescription, privacy: .public)"
                    )
                }
                continuation.resume(returning: url)
            }
        }
    }
}

// MARK: - Previews

#Preview("Drop — ready") {
    Color.clear
        .frame(width: D.size.windowMin.width, height: D.size.windowMin.height)
        .background(D.surface.deckPaint)
        .overlay { DropCurtain(.ready(fileCount: 1)) }
}

#Preview("Drop — refused") {
    Color.clear
        .frame(width: D.size.windowMin.width, height: D.size.windowMin.height)
        .background(D.surface.deckPaint)
        .overlay { DropCurtain(.refused) }
        .preferredColorScheme(.dark)
}
