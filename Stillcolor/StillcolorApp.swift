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
    @AppStorage("disableDithering") var disableDithering: Bool = true
    @AppStorage("disableUniformity2D") var disableUniformity2D: Bool = false
    @AppStorage("enableSoftwareDimming") var enableSoftwareDimming: Bool = false
    @AppStorage("softwareBrightness") var softwareBrightness: Double = 1.0
    @AppStorage("keepHardwareBrightnessAtMax") var keepHardwareBrightnessAtMax: Bool = false
    
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

                Toggle("Keep Hardware Brightness At Max", isOn: .init(
                    get: { keepHardwareBrightnessAtMax },
                    set: {
                        keepHardwareBrightnessAtMax = $0
                        if keepHardwareBrightnessAtMax {
                            Stillcolor.setHardwareBrightnessToMax()
                        }
                    }
                ))

                Button("Set Hardware Brightness To Max Now") {
                    Stillcolor.setHardwareBrightnessToMax()
                }

                Text("Uses Apple's display services to push the built-in panel back to full hardware brightness on demand, at launch, and after wake.")
                    .font(.caption)
                    .fontWeight(.thin)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)

                Divider()

                Toggle("Enable Software Dimming", isOn: .init(
                    get: { enableSoftwareDimming },
                    set: {
                        enableSoftwareDimming = $0
                        if enableSoftwareDimming {
                            Stillcolor.setHardwareBrightnessToMaxIfEnabled()
                        }
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

                Text("Keeps hardware brightness fixed high and dims the built-in display through a software filter.")
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
        }
        .menuBarExtraStyle(.window)
    }
}
