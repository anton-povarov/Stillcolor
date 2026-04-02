# Software Dimming

## Purpose

Stillcolor now supports a two-layer brightness workflow intended for users who want to control the built-in panel brightness directly while also being able to reduce perceived brightness in software:

1. Set built-in display hardware brightness with a persisted slider.
2. Apply software dimming through the display transfer pipeline.

This is aimed at reducing reliance on lower hardware brightness levels, which may matter for users sensitive to PWM or other panel behavior.

## Current Scope

The implementation currently targets the built-in display only.

It does **not** attempt to:

- disable PWM directly
- disable mini-LED local dimming
- replace Apple display presets or color profiles
- manage external display brightness

## User Configuration Assumptions

The feature was developed and tested assuming:

- `Automatically adjust brightness`: off
- `True Tone`: off
- `Night Shift`: off during validation
- hardware brightness is intended to remain stable while using software dimming
- display preset remains user-controlled, with `Apple XDR Display (P3-1600 nits)` used as the baseline during development

Those settings matter because the feature depends on a stable hardware brightness baseline. If macOS is allowed to keep changing brightness or display characteristics underneath the app, software dimming becomes inconsistent.

## Research Findings

### Stillcolor Baseline

Before this work, Stillcolor only did two IOKit property writes:

- `enableDither`
- `uniformity2D`

It had no brightness control path and no display transfer manipulation.

### BetterDisplay Findings

BetterDisplay’s public docs and discussions were useful mainly for narrowing the problem correctly.

Key findings:

- BetterDisplay distinguishes between Apple hardware brightness control and software dimming.
- Its PWM-oriented guidance is effectively: keep hardware brightness high, dim in software.
- It documents color-table based software dimming as the preferred software dimming path.
- For Apple XDR / mini-LED MacBook displays, it does not claim guaranteed PWM elimination. The benefit is presented as limited or device-dependent.

That led to two practical conclusions for Stillcolor:

1. The high-feasibility feature is software dimming, not panel hacking.
2. If automatic hardware brightness restore is added, it needs to use the same control plane as real Apple brightness control, not arbitrary registry writes.

### Failed Hardware Brightness Path

The first implementation attempt wrote the `brightness` property on `AppleARMBacklight` through `IORegistryEntrySetCFProperty`.

That approach failed for real user-facing brightness control:

- the property write succeeded
- registry values changed
- the actual panel brightness did not change in a meaningful way

Conclusion:

- on current Apple Silicon macOS, that registry property is not the correct authoritative user brightness control path for the internal display

### What Actually Worked

The validated hardware path is the private `DisplayServices` SPI:

- `DisplayServicesGetBrightness`
- `DisplayServicesSetBrightness`
- optionally `DisplayServicesCanChangeBrightness`

These functions were tested in a standalone probe and confirmed to:

- read current built-in brightness
- set brightness to a lower value
- read back the changed value
- restore brightness to the original value

That is the path now used by the app.

## Final Implementation

### Software Dimming

Software dimming is implemented in [`Stillcolor/Stillcolor.swift`](./Stillcolor/Stillcolor.swift) using the Core Graphics display transfer pipeline.

Behavior:

- enumerate built-in displays with `CGGetOnlineDisplayList`
- capture the original transfer baseline once per display
- prefer full transfer-table capture with `CGGetDisplayTransferByTable`
- fall back to transfer-formula capture with `CGGetDisplayTransferByFormula`
- scale the baseline by the selected software brightness value
- apply dimming with:
  - `CGSetDisplayTransferByTable`, or
  - `CGSetDisplayTransferByFormula`
- restore the original baseline when dimming is disabled or the app quits

Why this design:

- using the existing transfer baseline preserves the active display profile more faithfully than constructing an arbitrary new curve
- table-based scaling is safer than formula-only scaling when a display already has a non-trivial ColorSync pipeline

### Hardware Brightness Control

Hardware brightness control is implemented in [`Stillcolor/Stillcolor.swift`](./Stillcolor/Stillcolor.swift) by dynamically loading:

- `/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices`

The app resolves the SPI symbols at runtime with `dlopen` / `dlsym` instead of statically linking against the private framework.

Behavior:

- load `DisplayServices` lazily
- resolve `DisplayServicesSetBrightness`
- resolve `DisplayServicesGetBrightness`
- resolve `DisplayServicesCanChangeBrightness` if available
- enumerate built-in displays
- clamp the requested hardware brightness to the app's safe slider range
- for each supported built-in display, call `DisplayServicesSetBrightness(displayID, value)`

Why dynamic loading is used:

- it keeps the codepath explicit and isolated
- it avoids adding a direct build-time dependency on a private framework
- it allows clean failure logging if Apple changes or removes the SPI

### Sandboxing Requirement For Signed Runs

Signed sandboxed builds need an explicit mach lookup exception for the XPC service used by Apple's brightness stack:

- `com.apple.security.temporary-exception.mach-lookup.global-name`
  - `com.apple.backlightd`

Without that entitlement, Xcode-run or any other signed sandboxed launch path will fail with an error similar to:

- `The connection to service named com.apple.backlightd was invalidated`
- `Sandbox restriction`

This did not show up in earlier unsigned command-line builds because `CODE_SIGNING_ALLOWED=NO` prevents the app sandbox from being enforced in the same way.

### UI

The menu bar UI in [`Stillcolor/StillcolorApp.swift`](./Stillcolor/StillcolorApp.swift) now includes:

- a persisted `Hardware Brightness` slider
- `Set Hardware Brightness To Max Now`
- `Enable Software Dimming`
- a real `Software Brightness` slider
- `Reset Software Brightness`
- `Re-capture Dimming Baseline`

Important behavior details:

- hardware brightness is stored in app preferences and restored on launch, wake, and display reconfiguration
- `Set Hardware Brightness To Max Now` sets the hardware slider to `100%` and immediately applies it
- `Reset Software Brightness` resets the slider to `100%` without disabling software dimming
- `Re-capture Dimming Baseline` is intended for cases where the user changes display preset or color profile while the app is running

### Reapplication Lifecycle

Display settings are reapplied on:

- app launch
- display reconfiguration
- wake from sleep

Software dimming is also restored on app termination to avoid leaving the transfer tables modified after quit.

## Implementation Intricacies

### Why the Real Slider Needed a Window-Style MenuBarExtra

The default menu-style `MenuBarExtra` is too limited for a proper slider interaction. The app uses the window-style presentation so the brightness slider behaves like a real continuous control.

### Why Baseline Re-Capture Exists

Display presets, color profiles, and other system display state changes can rewrite the display transfer pipeline while Stillcolor is running.

If the user changes those settings after launch, Stillcolor’s cached baseline may no longer reflect the system’s current state. Re-capture lets the app rebuild its baseline from the new current transfer configuration.

### Why Built-In Display Only

The user problem here is specifically the MacBook Pro internal XDR panel. Restricting the implementation to built-in displays:

- avoids extra edge cases
- avoids interfering with external monitors
- keeps the feature aligned with the intended eye-strain use case

### Why the App Still Uses IOKit for Other Features

Stillcolor now has two different technical paths:

- IOKit property writes for dithering and `uniformity2D`
- Core Graphics + DisplayServices for brightness-related behavior

That split is intentional. The original framebuffer tweaks and brightness control live on different layers of the display stack and do not share a single reliable API.

## Validation Performed

The work was validated in three stages:

1. Build validation with `xcodebuild`.
2. Standalone probing for hardware brightness SPI behavior.
3. Manual runtime testing in the app.

Verified outcomes:

- the app launches and menu opens
- software brightness slider works
- launch-at-login remains functional
- quitting the app restores undimmed output
- hardware brightness control works correctly using the DisplayServices path

## Known Limitations

### Private API Risk

`DisplayServicesSetBrightness` is private Apple API.

That means:

- it may change across macOS releases
- it may stop working without warning
- it may have App Store implications if distribution goals change

### Software Dimming Tradeoffs

Transfer-table dimming can still introduce:

- visible banding
- reduced effective tonal precision
- more noticeable artifacts if dithering is disabled at the same time

### PWM Is Not Proven Eliminated

This feature should not be described as a direct PWM disable.

What it does is:

- let the app restore a stable hardware brightness level
- shift brightness reduction into software

That may help some users, but the exact flicker behavior of mini-LED MacBook Pro panels is device- and mode-dependent.

### System Features Can Still Compete

If the user re-enables:

- auto brightness
- True Tone
- Night Shift

the results may become inconsistent because macOS will again be changing display state underneath the app.

## Recommended User Flow

1. Disable auto brightness, True Tone, and Night Shift.
2. Set the `Hardware Brightness` slider to the level you want restored automatically.
3. Use `Set Hardware Brightness To Max Now` if you want to jump straight to `100%`.
4. Enable `Enable Software Dimming`.
5. Adjust the software brightness slider to comfort.
6. If display preset or color profile changes, use `Re-capture Dimming Baseline`.

## Future Work

Reasonable next improvements:

- per-display software dimming support for external monitors
- more robust UX around current hardware brightness state
- optional status text indicating whether hardware brightness restore succeeded
- calibration of the software brightness curve for better low-end usability
- additional recovery behavior if another process or macOS rewrites display transfer state unexpectedly

Not recommended without strong evidence:

- trying to disable PWM directly
- trying to disable mini-LED local dimming through undocumented framebuffer hacks

Those paths are substantially riskier and were intentionally not pursued for this implementation.
