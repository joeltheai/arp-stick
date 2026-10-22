# Arp Stick

A tiny CLAP MIDI effect written in **Zig 0.16.0**, with a basic native macOS editor. Play a root note to generate a chord or ascending arpeggio.

## Work on the UI without a DAW

```sh
zig build preview
```

Opens a standalone window with the exact same editor as the CLAP plugin. The four controls update local preview parameters; this preview produces no audio or MIDI and does not install anything into your plugin folders. Close the window or press Command-Q to quit.

For automatic rebuilds on save (requires Python 3):

```sh
python3 scripts/preview-macos.py
```

The watcher reopens only the preview when a source file changes. Stop it with Ctrl-C. If a build fails, fix the error and save again. Edit `src/ui/macos.m` for layout and native controls; `src/ui.zig` connects that view to the Zig parameter labels. There are no web, JUCE, or Qt dependencies. The Cocoa view uses a small Objective-C bridge compiled by Zig.

The custom editor is currently macOS only, fixed at 480 × 340 logical points. Other platforms retain the host's generic parameter UI. Preview controls do not test a DAW's embedding behavior; check the installed CLAP in your target hosts as well.

## Build and install on macOS

Requires Zig 0.16.0 and Xcode command line tools. CLAP 1.2.9 headers are included; no framework download or C++ build is needed.

```sh
./scripts/install-macos.sh
```

This builds for your Mac's native architecture, signs the local bundle with an ad hoc signature, and copies it to `~/Library/Audio/Plug-Ins/CLAP/ArpStick.clap`.

For a development build only, run `zig build`. The bundle is at `zig-out/ArpStick.clap`. Restart REAPER after installing a new build so it unloads the previous library.

## Try it in REAPER

1. Restart REAPER or rescan plugins in **Preferences → Plug-ins → LV2/CLAP**. Search the FX browser for **Arp Stick**.
2. Add a track. Insert **Arp Stick** first, then **ReaSynth** (or another MIDI synth) after it on the same track.
3. Drag `examples/roots.mid` onto that track and press Play. It contains four long root notes and should produce repeating major arpeggios by default.
4. Open Arp Stick's FX window to see its custom editor and change the four parameters. REAPER's **UI** button can switch to the host's generic controls if desired.
5. For live playing, arm the track, choose your MIDI keyboard as input, and enable input monitoring. REAPER's virtual MIDI keyboard also works when the track's input includes it.

Or load `examples/setup-demo.lua` through **Actions → Show action list → New action → Load ReaScript**, then run it. It creates a new project tab with Arp Stick, ReaSynth, and the example notes already set up. Press Play.

Arp Stick produces MIDI and passes existing stereo audio through. It needs a downstream instrument to make sound. The original root notes are replaced with generated notes; do not enable an additional dry MIDI path around the effect.

## Controls

- **Mode:** Chord sustains the generated chord until you release the root; Arp plays the generated notes in ascending pitch order.
- **Chord:** Major (0, 4, 7), Minor (0, 3, 7), Sus2 (0, 2, 7), or Octave (0, 12), in semitones above each held root.
- **Rate:** quarter, eighth, or sixteenth notes at the host tempo. If no tempo is supplied, it uses 120 BPM.
- **Octaves:** one or two. The second setting repeats the chord an octave higher; duplicate pitches merge.

Defaults are Arp, Major, 1/8, and one octave. Gate length is fixed at 75%. Input velocity and MIDI channel are preserved. Project save/restore and parameter automation are supported. MIDI CC and pitch bend messages pass through; CC120/123 also clear held roots. Stopping host playback releases generated notes.

This first version starts its arp pattern when you press a key and restarts when held keys or parameters change. The rate follows tempo; its phase is not locked to the project's beat grid. There is no latch, chord learning, scale detection, custom pattern editor, MPE, MIDI 2, or SysEx support yet. Note ports use MIDI 1 events. Sustain CC is passed to the downstream synth rather than used to latch the arp.

## Checks and code

```sh
zig build test
```

Runs Zig engine tests and a small C test host that loads the actual Zig shared library through the official CLAP ABI. Checks chord overlap, arp timing across blocks, note release, output backpressure, MIDI channel preservation, automation, transport stop, audio passthrough, plugin discovery, and state round-trip with partial stream reads/writes.

`src/engine.zig` contains the MIDI generator. `src/plugin.zig` contains the CLAP adapter, ports, parameters, state, and exported entry point. Processing uses fixed arrays and performs no heap allocation or locking. The engine and CLAP adapter are Zig; the macOS editor uses an Objective-C bridge to Cocoa.

On macOS, `zig build test-ui` checks the actual plugin editor in a small Cocoa host, including embedding, all four controls, parameter gestures, automation back to the UI, and closing/recreating the editor. It requires a macOS desktop session. `src/ui/macos.m` provides the shared native view; `src/preview.zig` runs it with local parameters. UI changes cross to the plugin through a fixed queue; AppKit is never called from audio processing.

Upstream CLAP headers and their MIT license are in `vendor/clap/`. See its README for the pinned version and include-guard compatibility patch.
