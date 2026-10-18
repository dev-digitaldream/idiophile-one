import SwiftUI

/// What happens to the signal, step by step, read live from the engine and the device.
struct AudioPathView: View {
    @Environment(AmpModel.self) private var amp

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let report = amp.player.audioPath()
            VStack(alignment: .leading, spacing: 18) {
                verdict(report.verdict)
                if report.stages.isEmpty {
                    Text("Nothing is playing.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(report.stages.enumerated()), id: \.element.id) { i, stage in
                            StageRow(stage: stage, isLast: i == report.stages.count - 1)
                        }
                    }
                }
                Divider()
                verification
                Divider()
                resolution
                Text("Steps after Core Audio — the driver and the DAC itself — are outside the app and are not measured.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(width: 460, alignment: .leading)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func verdict(_ verdict: AudioPathReport.Verdict) -> some View {
        let (icon, color, title, detail): (String, Color, String, String) = switch verdict {
        case .verifiedBitPerfect:
            ("checkmark.seal.fill", .green, "Bit-perfect, verified",
             "The samples reaching Core Audio were compared with the file: identical.")
        case .bitPerfectConditions:
            ("checkmark.circle", .green, "Bit-perfect conditions met",
             "Every step is transparent. Verify to compare the samples themselves.")
        case .altered(let causes):
            ("waveform.path.ecg", .orange, "The signal is modified",
             "By: " + causes.joined(separator: ", ") + ".")
        case .notVerifiable(let why):
            ("questionmark.circle", .secondary, "Not verified", why + ".")
        case .idle:
            ("pause.circle", .secondary, "Idle", "Play something to see its path.")
        }
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 28)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if amp.player.outputDevice?.transportName == "Built-in", case .altered = verdict {} else if amp.player.outputDevice?.transportName == "Built-in" {
                    Text("The built-in speakers then apply their own processing: use an external DAC for a bit-perfect chain.")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private var resolution: some View {
        let record = amp.resolutionRecord.flatMap { $0.url == amp.player.currentURL ? $0.report : nil }
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("True resolution").font(.headline)
                if let r = record {
                    let (text, color) = Self.describe(r)
                    Text(text).font(.caption).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
                    if let cutoff = r.cutoffHz {
                        Text(String(format: "Content ends near %.1f kHz (the file allows up to %.1f kHz)", cutoff / 1000, r.nyquist / 1000))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if r.verdict != .silent {
                        Text(String(format: "Content reaches the top of the band (%.1f kHz)", r.nyquist / 1000))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let used = r.effectiveBits {
                        Text(r.depthIsPadded
                             ? "Uses \(used) of the file's \(r.claimedBits ?? used) bits: padded"
                             : "Uses \(used) bits")
                            .font(.caption).foregroundStyle(r.depthIsPadded ? .orange : .secondary)
                    }
                } else {
                    Text(amp.player.isRadio ? "Not available for live streams"
                         : "Spectrum and bit usage of this file, compared with what its header claims")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button {
                amp.scanResolution()
            } label: {
                if amp.isScanningResolution { ProgressView().controlSize(.small) } else { Text("Scan") }
            }
            .disabled(amp.isScanningResolution || amp.player.currentURL == nil || amp.player.isRadio)
        }
    }

    private static func describe(_ r: ResolutionReport) -> (String, Color) {
        switch r.verdict {
        case .fullBand: ("Genuine: content fills the file's bandwidth", .green)
        case .upsampled(let from):
            (String(format: "Upsampled: content looks like a %.1f kHz source", from / 1000), .orange)
        case .lossySignature(let cutoff):
            (String(format: "Lossy-origin signature: low-pass at %.1f kHz, typical of MP3/AAC encoders", cutoff / 1000), .orange)
        case .limited(let cutoff):
            (String(format: "Band-limited at %.1f kHz: may be the recording itself", cutoff / 1000), .secondary)
        case .silent: ("Nothing to measure (silence)", .secondary)
        }
    }

    @ViewBuilder private var verification: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sample comparison").font(.headline)
                if let error = amp.verificationError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else if let record = amp.player.lastVerification, record.url == amp.player.currentURL {
                    let r = record.report
                    Text(r.isIdentical
                         ? "\(r.frames) frames × \(r.channels) ch identical at \(r.sourceBits)-bit"
                         : String(format: "%d samples differ (largest %.1f dBFS)", r.differingSamples, r.maxErrorDBFS ?? 0))
                        .font(.caption).foregroundStyle(r.isIdentical ? .green : .orange)
                    Text(record.path == amp.player.signalPath
                         ? "Checked \(record.date.formatted(date: .omitted, time: .shortened)) with the current settings"
                         : "Settings changed since: verify again")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(amp.player.isRadio ? "Not available for live streams" : "Not run for this track")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                amp.verifyBitPerfect()
            } label: {
                if amp.isVerifying { ProgressView().controlSize(.small) } else { Text("Verify") }
            }
            .disabled(amp.isVerifying || amp.player.currentURL == nil || amp.player.isRadio)
        }
    }
}

private struct StageRow: View {
    let stage: AudioPathStage
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 20, height: 20)
                if !isLast {
                    Rectangle().fill(.secondary.opacity(0.3)).frame(width: 1.5).frame(minHeight: 18)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(stage.title).font(.callout.weight(.semibold))
                Text(stage.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
    }

    private var icon: String {
        switch stage.state {
        case .transparent: "checkmark.circle.fill"
        case .alters: "exclamationmark.triangle.fill"
        case .info: "circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var color: Color {
        switch stage.state {
        case .transparent: .green
        case .alters: .orange
        case .info: .secondary
        case .unknown: .gray
        }
    }
}
