# October 7 iPhone redesign captures

These 65 native iPhone 17 Pro Max simulator images use the production SwiftUI
views with DEBUG simulator-only fixtures: 31 states/pages per appearance and
Dictate/Models/Settings at accessibility-extra-large (AX3). The badge identifies
synthetic text, installation/preparation states and saved records. The inert
engine rejects recognition/download/loading; there is no microphone, clipboard,
real model or phone data. The fixture code is excluded from physical builds.

Performance charts/readouts sample the simulator process genuinely. They are
not iPhone hardware measurements or evidence of a model's speed/memory use.

Coverage: Dictate idle/preparing/recording/finishing/done/error, Models normal/
downloading/failed, History, Library, Dictionary, Snippets, Notes, all four
editors, discard/save-error/reset dialogs, Settings, Action Button/Keyboard
setup, Performance, Accuracy, developer profiling, measurement details, Saved
data, About and Usage. Native keyboard-host, Dynamic Island and system Share
presentation are not captured here. Widget Xcode phase previews are in source.

Capture entry point: launch the simulator bundle with `--design-preview`,
`--preview-appearance light|dark`, plus `--preview-tab`, `--preview-state`,
`--preview-library` or `--preview-destination`; see DesignPreview.swift. Dialog
fixtures use `--preview-dialog`. Allow launch transitions to finish before
capturing; early black/faded frames are not layout evidence.

The AX3 pass exposed truncation in the live performance strip. Accessibility
sizes now stack/wrap metrics. Required Form captions and readout values use
explicit semantic colors. `contrast-report.json` contains actual asset/CSS
pair checks; it does not establish VoiceOver or whole-UI contrast by itself.
