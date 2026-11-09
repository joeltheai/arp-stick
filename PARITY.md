# JSFX → CLAP parity checklist

This maps the features of `arpstick-jsfx/ArpStick.jsfx` to this CLAP port.

| JSFX feature | CLAP location | Verification |
| --- | --- | --- |
| 128 chord slots × 8 voices | `src/model.zig` (`chord_notes`, `chord_vel`) | engine + host state tests |
| Per-voice velocity scaling 0–200% | `engine.chordTrigger` | "velocity scaling" test, JSFX T3 values |
| Voice locks / pedal tones | `model.lock_on`, `model.lock_note`; `engine.chordTrigger` | "velocity scaling, locks" test |
| Global chord transpose ±36 | parameter 2; `engine.chordTrigger` | transpose tests |
| MIDI latch | parameter 3; `engine.inputNoteOn/Off` | host latch test |
| Learn modes (record/single-slot/advanced/timer) | `engine.learnOn/learnCommit`; shared learn state | learn tests; UI learn button |
| Watch slots / remove unwatched | `Shared.watched_bits`; `model.removeUnwatched` | model tests; UI eye |
| Six chord sort modes | `model.sortSlots` | "sort" test, JSFX T19 values |
| Remove duplicates / 1–3 note chords | `model.removeDups`, `removeNNotes` | JSFX T21 values |
| Major/minor/suspend transforms | `model.makeThird` | JSFX T20 values |
| Note-prevent / match-chord transforms | `model.transformPrevent`, `transformMatch` | transform test |
| Populate empty slots | `model.populateEmpty` | populate test |
| 56-entry chord preset menu | `model.applyChordPreset`; editor menu | preset tests; GUI test |
| 12 patterns A–L, 8 lanes × 16 steps | `model.graph`, `engine.arpFire` | engine tests; GUI |
| NOTE lane: rests, numbered notes, 8 directional shapes, reset arrows | `engine.arpFire` | chord mode, shape/reset tests |
| RAND lane | `engine.arpFire` (random offset) | lane handling |
| OCT lane | `engine.arpFire` | JSFX T14 test |
| PITCH lane + 7 degree enables | `engine.arpFire`, `model.pen` | constraint/pitch tests |
| VEL lane 0–200% | `engine.arpFire` | gate/velocity test |
| GATE lane 0–100% (ties at 100) | `engine.arpFire` | JSFX T9 test |
| LATE lane ±100% | `engine.lateFrac` | timing tests |
| HARM lane ±12 | `engine.arpFire` | JSFX T15 test |
| Per-lane length 1–16 | `model.lane_len` | GUI length drag |
| Per-lane division 1–8 | `model.lane_div`, `engine.arpFire` | lane-division test |
| Chord inversion mode | `model.chord_mode` | JSFX T8-style test |
| Step mutes | `model.mute` | mute test |
| Retrigger | `model.retrig` | engine timing |
| Link lengths | `model.link` | GUI length drag |
| Swing 0–75% | `model.swing`, `engine.lateFrac` | swing test |
| Rate 16 bars … 1/2048 | `model.rate`, `engine.beginBlock` | rate labels/GUI |
| Free clock 0.05–40 Hz | `model.free_on/free_hz` | free-clock test |
| Automatic free clock while stopped | `engine.beginBlock` | free-clock test |
| Beat-timeline sync, seek, start/stop | `engine.beginBlock/tick` | synced-transport test |
| Note-block keys (pass/block/up/down) | `model.constraint`, `engine.constrain` | JSFX T13 test |
| Output channel input/1–16 | parameter 5 | host routing test |
| MIDI remote Ch 2/3 | `plugin.midiRemote` | host remote test |
| Polyphonic saw test tone | `engine.toneOn/Off/tick` | host audio test |
| Non-note MIDI passthrough, CC panic | `plugin.process`, `engine.control` | host CC test |
| Full state save/restore | `plugin.save/load`, `model.bytes/validate` | byte-for-byte state test |
| 960×640 industrial editor, graph, piano, menus | `src/ui/macos.m` | GUI test + `docs/editor.png` |
| MIDI import | `importMidiAtPath:` | GUI test with a generated SMF |

## Deliberate differences

- **Plugin format:** CLAP instead of REAPER JSFX. The MIDI and audio behavior is ported, but the host-facing shell, parameters and state are CLAP-native.
- **MIDI import source:** the JSFX reads REAPER `gmem` filled by `tools/import_midi_chords.lua`. The CLAP version imports a Standard MIDI File directly from the editor (same result: chords written to consecutive slots).
- **Editor:** a Cocoa view instead of a `gfx_*` canvas. Layout, controls, vocabulary and interaction model follow the JSFX.
- **Non-macOS:** hosts use their generic parameter UI; the engine, parameters and state are platform independent.
