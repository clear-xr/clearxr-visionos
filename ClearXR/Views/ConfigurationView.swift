import SwiftUI
#if !targetEnvironment(simulator)
import FoveatedStreaming
#endif

struct ConfigurationView: View {
#if !targetEnvironment(simulator)
    @Environment(FoveatedStreamingSession.self) private var session
#endif

    @AppStorage("configPresetChoice") private var presetChoiceRawValue: String = ConfigurationPresetChoice.defaultChoice.rawValue
    @AppStorage("configRenderedResolution") private var renderedResolution: Int = ResolutionPreset.balanced.renderedResolution
    @AppStorage("configEncodedResolution") private var encodedResolution: Int = ResolutionPreset.balanced.encodedResolution
    @AppStorage("configFoveationInsetPercent") private var foveationInsetPercent: Int = Int(ResolutionPreset.balanced.foveationInsetRatio * 100)
    @AppStorage("configClearXRDefaultAppEnabled") private var clearXRDefaultAppEnabled: Bool = true
    @AppStorage("configAlphaTransparencyEnabled") private var alphaTransparencyEnabled: Bool = false

    @AppStorage("selectedEndpointHost") private var selectedEndpointHost: String = ""
    @AppStorage("selectedEndpointPort") private var selectedEndpointPort: Int = 55000

    @State private var isApplying = false
    @State private var isShowingApplyError = false
    @State private var applyErrorMessage: String?
    @State private var applySucceeded = false
    @State private var adjustmentWarning: String?
    @State private var isAutoAdjusting = false

    private let configManager = ServerConfigurationManager()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Preset", selection: selectedPresetBinding) {
                    ForEach(ConfigurationPresetChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.menu)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Rendered Width")
                        .font(.headline)
                    TextField("Rendered Width", value: $renderedResolution, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .disabled(!isCustomPreset)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Encoded Width")
                        .font(.headline)
                    TextField("Encoded Width", value: $encodedResolution, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .disabled(!isCustomPreset)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Foveation Inset")
                        Spacer()
                        Text("\(foveationInsetPercent)%")
                            .fontWeight(.semibold)
                    }
                    Slider(value: foveationInsetBinding, in: 10...100, step: 5)
                    Text("Encoded width is enforced from the rendered width and inset ratio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable Clear XR default app", isOn: $clearXRDefaultAppEnabled)
                    Toggle("Enable alpha transparency", isOn: $alphaTransparencyEnabled)
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                if let adjustmentWarning {
                    Text(adjustmentWarning)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }

                if let validationError {
                    Text(validationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let endpointDescription {
                    Text("Target endpoint: \(endpointDescription)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Target endpoint unavailable. Connect manually or set bonjour host/port.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await applyConfiguration() }
                } label: {
                    Text(isApplying ? "Applying..." : "Apply Configuration")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canApply)

                Text(applySucceeded ? "Configuration sent.  Restart your session!" : "Warning: Session will need to restart")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .font(.caption2)
                    .foregroundStyle(applySucceeded ? .green : .secondary)
            }
            .navigationTitle("Configuration")
            .padding()
            .onAppear {
                applySucceeded = false
                normalizeStoredState()
            }
            .onChange(of: renderedResolution) {
                guard isCustomPreset, !isAutoAdjusting else { return }
                adjustFromRenderedInput(showWarning: true)
            }
            .onChange(of: encodedResolution) {
                guard isCustomPreset, !isAutoAdjusting else { return }
                adjustFromEncodedInput(showWarning: true)
            }
            .onChange(of: foveationInsetPercent) {
                guard !isAutoAdjusting else { return }
                adjustFromRenderedInput(showWarning: isCustomPreset)
            }
            .alert("Failed to apply configuration", isPresented: $isShowingApplyError) {
                Button("OK") { }
            } message: {
                Text(applyErrorMessage ?? "Unknown error")
            }
        }
    }

    private var selectedPresetBinding: Binding<ConfigurationPresetChoice> {
        Binding {
            ConfigurationPresetChoice(rawValue: presetChoiceRawValue) ?? .defaultChoice
        } set: { newValue in
            presetChoiceRawValue = newValue.rawValue
            if let preset = newValue.preset {
                applyPreset(preset)
            }
        }
    }

    private var foveationInsetBinding: Binding<Double> {
        Binding {
            Double(foveationInsetPercent)
        } set: { newValue in
            foveationInsetPercent = Int(newValue)
        }
    }

    private var isCustomPreset: Bool {
        (ConfigurationPresetChoice(rawValue: presetChoiceRawValue) ?? .defaultChoice) == .custom
    }

    private var isSessionConnected: Bool {
#if targetEnvironment(simulator)
        true
#else
        session.status == .connected
#endif
    }

    private var validationError: String? {
        guard renderedResolution > 0, encodedResolution > 0 else {
            return "Resolutions must be greater than zero."
        }
        guard renderedResolution % 16 == 0, encodedResolution % 16 == 0 else {
            return "Rendered and encoded widths must be divisible by 16."
        }
        guard let exactEncoded = exactEncodedWidth(forRendered: renderedResolution, ratioPercent: foveationInsetPercent),
              exactEncoded == encodedResolution else {
            return "Encoded width must match the foveation percentage of rendered width exactly."
        }
        return nil
    }

    private var canApply: Bool {
        !isApplying && validationError == nil && resolvedEndpoint != nil && isSessionConnected
    }

    private var endpointDescription: String? {
        guard let endpoint = resolvedEndpoint else { return nil }
        return "\(endpoint.host):\(endpoint.port)"
    }

    private var resolvedEndpoint: (host: String, port: Int)? {

        return (selectedEndpointHost, selectedEndpointPort)
    }

    private var payload: StreamConfigurationMessage {
        #if targetEnvironment(simulator)
        let sessionID = "simulator-session"
        #else
        let sessionID = String(describing: ObjectIdentifier(session))
        #endif

        return StreamConfigurationMessage(
            RenderedResolution: renderedResolution,
            EncodedResolution: encodedResolution,
            FoveationInsetRatio: Double(foveationInsetPercent) / 100.0,
            DefaultAppEnabled: clearXRDefaultAppEnabled,
            AlphaTransparencyEnabled: alphaTransparencyEnabled
        )
    }

    private func normalizeStoredState() {
        guard let selectedChoice = ConfigurationPresetChoice(rawValue: presetChoiceRawValue) else {
            // Only reset to default when stored value is invalid/missing.
            presetChoiceRawValue = ConfigurationPresetChoice.defaultChoice.rawValue
            applyPreset(.balanced)
            return
        }

        if selectedChoice == .custom {
            adjustFromRenderedInput(showWarning: false)
        } else {
            // Preserve persisted preset values; do not overwrite on each view appearance.
            adjustmentWarning = nil
        }
    }

    private func applyPreset(_ preset: ResolutionPreset) {
        isAutoAdjusting = true
        renderedResolution = preset.renderedResolution
        foveationInsetPercent = Int(preset.foveationInsetRatio * 100)
        encodedResolution = preset.encodedResolution
        isAutoAdjusting = false
        adjustFromRenderedInput(showWarning: false)
    }

    private func exactEncodedWidth(forRendered rendered: Int, ratioPercent: Int) -> Int? {
        guard ratioPercent > 0 else { return nil }
        let numerator = rendered * ratioPercent
        guard numerator % 100 == 0 else { return nil }
        let encoded = numerator / 100
        guard encoded % 16 == 0 else { return nil }
        return encoded
    }

    private func normalizedMultipleOf16(_ value: Int) -> Int {
        max(16, value - (value % 16))
    }

    private func nextValidPairForRendered(atOrBelow renderedTarget: Int) -> (rendered: Int, encoded: Int)? {
        let start = normalizedMultipleOf16(max(renderedTarget, 16))
        var rendered = start
        while rendered >= 16 {
            if let encoded = exactEncodedWidth(forRendered: rendered, ratioPercent: foveationInsetPercent) {
                return (rendered, encoded)
            }
            rendered -= 16
        }
        return nil
    }

    private func nextValidPairForEncoded(atOrBelow encodedTarget: Int) -> (rendered: Int, encoded: Int)? {
        guard foveationInsetPercent > 0 else { return nil }
        let upperRendered = Int((Double(encodedTarget) * 100.0 / Double(foveationInsetPercent)).rounded(.down))
        let start = normalizedMultipleOf16(max(upperRendered, 16))

        var rendered = start
        while rendered >= 16 {
            if let encoded = exactEncodedWidth(forRendered: rendered, ratioPercent: foveationInsetPercent),
               encoded <= encodedTarget {
                return (rendered, encoded)
            }
            rendered -= 16
        }
        return nil
    }

    private func setPair(_ rendered: Int, _ encoded: Int, warning: String?) {
        isAutoAdjusting = true
        renderedResolution = rendered
        encodedResolution = encoded
        isAutoAdjusting = false
        adjustmentWarning = warning
    }

    private func adjustFromRenderedInput(showWarning: Bool) {
        guard let pair = nextValidPairForRendered(atOrBelow: renderedResolution) else {
            adjustmentWarning = "No valid rendered/encoded pair found for current ratio."
            return
        }

        let warning: String?
        if showWarning && (pair.rendered != renderedResolution || pair.encoded != encodedResolution) {
            warning = "Requested values cannot satisfy \(foveationInsetPercent)% while keeping widths divisible by 16. Using next lower valid pair: rendered \(pair.rendered), encoded \(pair.encoded)."
        } else {
            warning = nil
        }
        setPair(pair.rendered, pair.encoded, warning: warning)
    }

    private func adjustFromEncodedInput(showWarning: Bool) {
        guard let pair = nextValidPairForEncoded(atOrBelow: encodedResolution) else {
            adjustmentWarning = "No valid rendered/encoded pair found for current ratio."
            return
        }

        let warning: String?
        if showWarning && (pair.rendered != renderedResolution || pair.encoded != encodedResolution) {
            warning = "Requested values cannot satisfy \(foveationInsetPercent)% while keeping widths divisible by 16. Using next lower valid pair: rendered \(pair.rendered), encoded \(pair.encoded)."
        } else {
            warning = nil
        }
        setPair(pair.rendered, pair.encoded, warning: warning)
    }

    private func applyConfiguration() async {
#if targetEnvironment(simulator)
        applySucceeded = true
        return
#else
        guard let endpoint = resolvedEndpoint else { return }
        guard validationError == nil else { return }

        isApplying = true
        applySucceeded = false
        defer {
            isApplying = false
        }

        do {
            try await configManager.sendConfiguration(payload, host: endpoint.host, port: endpoint.port)
            applySucceeded = true
        } catch {
            applyErrorMessage = error.localizedDescription
            isShowingApplyError = true
        }
#endif
    }
}

#Preview(windowStyle: .automatic, traits: .fixedLayout(width: 580, height: 860)) {
    ConfigurationView()
}
