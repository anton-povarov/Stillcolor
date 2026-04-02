//
//  StillcolorApp.swift
//  Stillcolor
//
//  Created by Abdullah Arif on 25/02/2024.
//

import SwiftUI
import LaunchAtLogin

@main
struct StillcolorApp: App {
    private static let hardwareBrightnessPollingInterval = 0.1
    private static let hardwareBrightnessPollingEpsilon = 0.01

    @AppStorage("disableDithering") var disableDithering: Bool = true
    @AppStorage("disableUniformity2D") var disableUniformity2D: Bool = false
    @AppStorage("enableSoftwareDimming") var enableSoftwareDimming: Bool = false
    @AppStorage("hardwareBrightness") var hardwareBrightness: Double = 1.0
    @AppStorage("softwareBrightness") var softwareBrightness: Double = 1.0

    @State private var hardwareBrightnessPollingTimer: Timer?
    
    let detector = ScreenDetector()
    
    init() {
        detector.addObservers()
        Stillcolor.applyCurrentPreferences()
    }
    
    var body: some Scene {
        MenuBarExtra(
            "Stillcolor",
            systemImage: "\(disableDithering  ? "livephoto.slash" : "livephoto")"
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Disable Dithering", isOn: .init(
                    get: { disableDithering },
                    set: {
                        disableDithering = $0
                        Stillcolor.enableDisableDithering(disableDithering)
                    }
                ))
                
                Toggle("Disable uniformity2D", isOn: .init(
                    get: { disableUniformity2D },
                    set: {
                        disableUniformity2D = $0
                        Stillcolor.enableDisableUniformity2D(disableUniformity2D)
                    }
                ))
                
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Hardware Brightness")
                        Spacer()
                        Text("\(Int(hardwareBrightness * 100))%")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: .init(
                        get: { hardwareBrightness },
                        set: {
                            hardwareBrightness = $0
                            Stillcolor.setHardwareBrightness(hardwareBrightness)
                        }
                    ), in: 0.05...1.0)
                }

                Button("Set Hardware Brightness To Max Now") {
                    hardwareBrightness = 1.0
                    Stillcolor.setHardwareBrightness(hardwareBrightness)
                }

                Text("Uses Apple's display services to restore the built-in panel brightness you choose here on launch, wake, and display changes.")
                    .font(.caption)
                    .fontWeight(.thin)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)

                Divider()

                Toggle("Enable Software Dimming", isOn: .init(
                    get: { enableSoftwareDimming },
                    set: {
                        enableSoftwareDimming = $0
                        Stillcolor.enableDisableSoftwareDimming(enableSoftwareDimming, brightness: softwareBrightness)
                    }
                ))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Software Brightness")
                        Spacer()
                        Text("\(Int(softwareBrightness * 100))%")
                            .foregroundColor(.secondary)
                    }

                    Slider(value: .init(
                        get: { softwareBrightness },
                        set: {
                            softwareBrightness = $0
                            if enableSoftwareDimming {
                                Stillcolor.setSoftwareBrightness(softwareBrightness)
                            }
                        }
                    ), in: 0.05...1.0)
                    .disabled(!enableSoftwareDimming)
                }

                Text("Lets you keep hardware brightness stable and dim the built-in display further through a software filter.")
                    .font(.caption)
                    .fontWeight(.thin)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)

                Button("Reset Software Brightness") {
                    softwareBrightness = 1.0
                    if enableSoftwareDimming {
                        Stillcolor.setSoftwareBrightness(softwareBrightness)
                    } else {
                        Stillcolor.restoreSoftwareDimming()
                    }
                }

                Button("Re-capture Dimming Baseline") {
                    Stillcolor.recaptureSoftwareDimmingBaseline(
                        brightness: enableSoftwareDimming ? softwareBrightness : nil
                    )
                }

                Text("Use this after changing display preset or color profile while the app is running.")
                    .font(.caption)
                    .fontWeight(.thin)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)

                Text("(Experimental) Stop built-in display from\nusing lower brightness levels around the edges")
                    .font(.caption)
                    .fontWeight(.thin)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
                
                Divider()
                LaunchAtLogin.Toggle()
                Divider()
                
                Button("Quit Stillcolor") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(12)
            .frame(width: 320)
            .onAppear {
                syncHardwareBrightnessFromDisplay()
                startHardwareBrightnessPolling()
            }
            .onDisappear {
                stopHardwareBrightnessPolling()
            }
        }
        .menuBarExtraStyle(.window)
    }

    private func startHardwareBrightnessPolling() {
        guard hardwareBrightnessPollingTimer == nil else {
            return
        }

        hardwareBrightnessPollingTimer = Timer.scheduledTimer(withTimeInterval: Self.hardwareBrightnessPollingInterval, repeats: true) { _ in
            syncHardwareBrightnessFromDisplay()
        }
    }

    private func stopHardwareBrightnessPolling() {
        hardwareBrightnessPollingTimer?.invalidate()
        hardwareBrightnessPollingTimer = nil
    }

    private func syncHardwareBrightnessFromDisplay() {
        guard let currentBrightness = Stillcolor.currentHardwareBrightnessValue() else {
            return
        }

        guard abs(currentBrightness - hardwareBrightness) > Self.hardwareBrightnessPollingEpsilon else {
            return
        }

        hardwareBrightness = currentBrightness
    }
}
