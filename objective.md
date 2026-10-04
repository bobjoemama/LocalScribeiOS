# LocalScribe iOS objective

Build an open-source native iOS LocalScribe with local speech recognition and a polished dictation app and keyboard. Research current models and model-specific runtimes using primary GitHub, Hugging Face, platform and announcement evidence. Evaluate speed, word error rate, download/installed size, process RAM, CPU/GPU/Neural Engine work and sustained thermal/energy costs on Devesh's iPhone 17 Pro Max.

Accepted design direction: minimalist Apple-style controls, standard readable typography, clear functional labels, meaningful symbols only, and proper light/dark modes on both platforms. Remove decorative slogans, redundant headings and subtitles. Preserve useful actions such as dictating, choosing a model, copying and sharing. The earlier editorial UI candidate is superseded.

Phonon-2 is the model Devesh saw. He approved pinned FluidAudio 0.17.5 Core ML integration and iPhone provisioning/installation using the existing developer team. Runtime implementations must remain replaceable. Phone performance, rather than Mac benchmarks or model size alone, determines the selected profile.

Improve the existing Mac LocalScribe UI while preserving the working installation, application identity, stored data, local model runtime and uninterrupted Control–Space dictation. Devesh subsequently authorized rebuilding and replacing the Mac app, deleting the old installed bundle, and committing/pushing both projects. Restart only LocalScribe for this update; do not restart macOS. Preserve all user data, model files and shortcut settings.

The model research and its evidence live in `docs/MODEL_RESEARCH.md`. Remaining delivery work and verification status live in `tasklist.md`.
