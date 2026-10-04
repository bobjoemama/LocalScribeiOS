# iPhone speech model and runtime decision

Researched **4 October 2026**. This record supersedes the earlier quality-only Ultra recommendation. Devesh confirmed **Phonon-2** is the new model and wants speed, memory pressure, recognition accuracy, storage and sustained hardware strain considered together. Download size is not resident memory; Mac throughput is not iPhone latency; running on Apple silicon does not establish iOS support. The first default Phonon-2 phone run is recorded separately below; broader model and encoder comparisons remain incomplete.

## Recommendation

Devesh approved **Phonon-2 through pinned FluidAudio 0.17.5 native Core ML with CPU/Neural Engine execution**. The first default-encoder device benchmark now demonstrates that accepted integration runs on the phone. Compare the default encoder against `sparse-g4`, with `sparse-g1` as the storage control. This is a recommendation for a measurable integration, **not a verified fastest/best phone default**. Select the shipped profile from actual iPhone 17 Pro Max results across all requested metrics. Do not add alternative runtimes merely to share one framework across models: the appropriate stacks differ below.

A custom Swift MLX port could preserve Fermion's smaller packed representation, but no ready iOS Fermion runtime was found. It is additional engineering and a foreground GPU path, rather than a proven phone optimization. Native Core ML already preserves the checkpoint's exact five-value weights. Thus conversion does not require accepting a different lower-accuracy checkpoint. [Core ML checkpoint and encoding](https://huggingface.co/FluidInference/phonon-2-coreml), [upstream supported runtimes](https://github.com/fermionresearch/phonon/blob/aec0d2b09cde0c0a517f93f3b3a79c7f891dbcd7/README.md)

## Phonon-2: complete encoding/backend combinations

All sizes below are exact required-file totals from pinned Hugging Face metadata, rounded to decimal MB. Shared decoder, joint, preprocessor and vocabulary require **36,948,214 bytes**. All variants need iOS 18+. ANE is Apple's Neural Engine; CPU still handles surrounding work. The timing column is the publisher's **M5 Pro encoder measurement per 15-second window**, not total dictation latency or phone performance.

| Encoder | Encoder MB / full bundle MB | Exact weight encoding | Published ANE time | Cold-start/backend concern |
| --- | ---: | --- | ---: | --- |
| `Encoder.mlmodelc` | 320.625 / 357.573 | Sparse mask; 6-bit palettes per 8 rows | 18.6 ms | First ANE preparation about 1 minute; cached afterward |
| `Encoder_sparse-g4.mlmodelc` | 246.514 / 283.462 | Sparse mask; 4-bit palettes per 4 rows | 24.3 ms | Phone first-load/memory unmeasured |
| `Encoder_sparse-g1.mlmodelc` | 175.746 / 212.695 | Sparse mask; 2-bit palettes per row | 70 ms | Smallest storage; more ANE palette work |
| `Encoder_lut3.mlmodelc` | 252.854 / 289.802 | Dense 3-bit palettes per row | 72 ms | Mac GPU load 0.7 s, encoder 16 ms |
| `Encoder_lut6.mlmodelc` | 469.909 / 506.857 | Dense 6-bit palettes per 8 rows | 18.6 ms | Mac GPU load 0.6 s, encoder 16 ms |

The sparse encoders reportedly incur about **150 seconds of CPU expansion on every GPU launch**; `.all` can choose that path. Use explicit `.cpuAndNeuralEngine` for the background dictation candidate. Dense LUT3 is the credible compact **foreground GPU** comparison if GPU support is desired. All five preserve the same learned `{0, ±lo, ±hi}` values; the publisher reports identical transcripts, including 2,620/2,620 LibriSpeech comparisons for two encoders. Smaller palettes are an encoding/storage choice, not new training. No published per-variant phone memory, power or thermal evidence was found; the project’s initial default-encoder measurements appear separately below. [Encoding and benchmark details](https://huggingface.co/FluidInference/phonon-2-coreml), [tagged integration study](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/Phonon2.md)

FluidAudio's paired M5 Pro full-LibriSpeech clean/other WER is Ultra **2.13/3.81%**, Phonon-2 **2.47/4.62%**, Redux **2.71/5.12%**. Phonon-2 is English-only. Its faster encoder does not prove lower total energy. The upstream model averages 5.21% on seven English sets and loses to its teacher on several while improving AMI/VoxPopuli; normalization/windowing differ from FluidAudio. These results support a real accuracy tradeoff, not a universal ranking for personal dictation. [Paired evaluation](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/Phonon2.md), [original checkpoint evaluation](https://huggingface.co/FermionResearch/Phonon-2)

### Fermion's 164 MB packed runtime versus a bespoke port

Inspected PyPI **fermion-research 0.2.9** without installing it: its 1,252,616-byte wheel has SHA-256 `68bd35b5f2ad397ab0202752ef3ea0e95dad64dc019af0f3baebdf5f95fe308e`. The shipped `packed_runtime.py` replaces five-value linears with **two native MLX 2-bit affine `quantized_matmul` planes**, group size 128, then sums them. It does not ship a special fused Metal kernel. Python MLX-audio supplies the Parakeet graph and decoding. CPU native binaries target Linux, Windows and macOS; no iOS slice/Swift package was found. C kernel sources were not found in the inspected repository/wheel, so the macOS library is not an iOS build input. [Published wheel](https://pypi.org/project/fermion-research/0.2.9/), [CPU platform documentation](https://github.com/fermionresearch/phonon/blob/aec0d2b09cde0c0a517f93f3b3a79c7f891dbcd7/docs/cpu.md)

A Swift MLX port would need the packed-container parser, exact two-plane linears, FastConformer graph, mel preprocessing and TDT decoding. A fused kernel would be new work requiring a correctness/performance comparison against those existing operations. The 164 MB archive alone establishes neither peak RAM nor iPhone suitability. Code is Apache-2.0; Phonon-2 weights are CC-BY-4.0. [Original model](https://huggingface.co/FermionResearch/Phonon-2), [engine repository](https://github.com/fermionresearch/phonon)

## Other models: recommend the stack separately

| Model | Existing relevant implementation | Recommendation and limits |
| --- | --- | --- |
| **Parakeet Ultra** | FluidAudio native Core ML, `.ultra`, **632,162,964 bytes**, iOS 17+, 25 languages | Use CPU/ANE as the quality comparison. Larger storage than Phonon-2; no paired phone RAM/energy result. Weights CC-BY-4.0; runtime Apache-2.0. |
| **Parakeet Redux** | FluidAudio native Core ML, `.redux`, **220,304,193 bytes**, iOS 18+, 25 languages | Benchmark ANE only if multilingual compactness matters; slow first preparation is a serious cost. Photon packed CPU kernels are worth investigating only when an actual iOS deliverable exists. |
| **Moonshine v2 Streaming** | Official `MoonshineVoice` Swift/XCFramework, minimal ONNX Runtime **CPU-only** | Use the official streaming CPU stack for its own comparison; start Small versus Medium. Do not assume a Core ML provider or old Moonshine-v1 conversions accelerate v2. English current models/runtime MIT. |
| **Qwen3-ASR 0.6B** | `soniqo/speech-swift`: MLX GPU; hybrid encoder/Core ML + MLX decoder; or full Core ML + Accelerate | For background work recommend the real all-Core-ML/no-MLX path. Treat 4-bit Swift MLX as a separate foreground comparison. Model/runtime Apache-2.0; conversion accuracy differs. |
| **Whisper** | MIT WhisperKit/Argmax native Core ML | Established alternative if the above leave an evidenced requirement gap. Existing Mac product removed Whisper; no reason to restore it based solely on familiarity. |
| **Canary-Qwen 2.5B** | Current Mac reference; official NVIDIA NeMo deployment | Keep as accuracy reference. No suitable demonstrated iOS stack found; parameter count alone does not establish the phone's limit. |

### Ultra and Redux

Moondream's **Photon** computes Redux directly from packed ternary weights; published Mac M2 results are 38× real time on CPU and 43× on GPU. The released API is Python `md.photon("moondream/parakeet-redux", device="cpu"/"mps")`; Ultra uses CUDA there. This is concrete model-specific optimization, but no iOS package/XCFramework was found and runtime redistribution/source terms remain unverified. Do not label free downloadable binaries open source. [Moondream release, 22 September](https://moondream.ai/blog/introducing-parakeet-redux-and-ultra), [Photon support](https://moondream.ai/photon/support)

FluidAudio's Redux ANE preparation can take several minutes on M-series Macs; its GPU path starts faster but cannot support ordinary background GPU work. These figures do not predict A19 timing. `speech-swift`'s existing Parakeet support and Argmax's OSS Whisper support do not demonstrate ready Ultra/Redux conversion/kernel support; architecture compatibility is insufficient evidence. [Redux integration](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/ParakeetRedux.md), [Ultra conversion](https://huggingface.co/FluidInference/parakeet-ultra-coreml), [speech-swift](https://github.com/soniqo/speech-swift), [Argmax OSS](https://github.com/argmaxinc/argmax-oss-swift)

### Moonshine v2

The official iOS package contains a static C++/ONNX Runtime XCFramework and Swift wrapper. Its optimized `.ort` graph uses fused CPU operators; the documented tiny encoder fragments into 59 partitions for Core ML. The shipped iOS minimal ORT 1.23 cannot compile that provider, and requesting it errors. Accelerating v2 through Core ML requires a different export/build and new measurements, not a configuration switch. [Execution-provider investigation](https://github.com/moonshine-ai/moonshine/blob/234f60faa0eb388b01cdf7e60aca232af37aefda/docs/execution-providers.md), [Swift package](https://github.com/moonshine-ai/moonshine-swift)

The Swift microphone interface is `MicTranscriber().onText {...}.onLine {...}`, followed by `try await mic.load()` and `try mic.start()`. The official physical-device harness is `scripts/test-mobile-latency.sh` and `examples/ios/StreamingLatency`. It measures completed-phrase latency on `two_cities.wav` fed faster than real time, not microphone delay, cold preparation, energy or resident memory. Published Medium/Small English WER averages 6.65/7.84% are across different datasets from FluidAudio; quantized versions score worse. [Quickstart](https://moonshine-voice.readthedocs.io/en/latest/quickstart/), [models](https://moonshine-voice.readthedocs.io/en/latest/models/available-models/), [benchmark definition](https://github.com/moonshine-ai/moonshine/blob/main/docs/using/benchmarks.md)

### Qwen3-ASR

Inspected `speech-swift` revision `1f54e56cf137078ed681a03e0955e777f7314610`. Its actual background-capable method is `CoreMLASRModel.transcribeWithoutMLX(audio:sampleRate:language:maxTokens:)`; ordinary `transcribe` still uses MLX arrays. Load through `CoreMLASRModel.fromPretrained(...)` with **both** `encoderComputeUnits` and `decoderComputeUnits` set to `.cpuAndNeuralEngine`, explicit cache and `offlineMode: true`. The encoder defaults to `.all`, so accepting defaults can choose GPU. The split stateful Core ML decoder and Accelerate mel path exist in code; a “Core ML” label alone does not establish GPU-free preprocessing. [Exact API and implementation](https://github.com/soniqo/speech-swift/blob/1f54e56cf137078ed681a03e0955e777f7314610/Sources/Qwen3ASR/CoreMLASRModel.swift)

Publisher Mac comparisons on 200 LibriSpeech samples: 4-bit MLX 2.2% WER/0.012 RTF versus Core ML INT8 3.02%/0.098 RTF. A repaired attention-mask conversion materially changed accuracy. Repeated-request MLX cache changes reduced final process footprint from 7.04 to 1.75 GiB while mean latency rose 17%; cold and sustained behavior matter. Neither benchmark is an iPhone Qwen result. The available iPhone16 Pro benchmark covers Parakeet EOU/Omnilingual, **not Qwen**. [Inference comparisons](https://github.com/soniqo/speech-swift/blob/1f54e56cf137078ed681a03e0955e777f7314610/docs/inference/qwen3-asr-inference.md), [cache experiment](https://github.com/soniqo/speech-swift/blob/1f54e56cf137078ed681a03e0955e777f7314610/docs/benchmarks/qwen3-asr.md), [phone scope](https://github.com/soniqo/speech-swift/blob/1f54e56cf137078ed681a03e0955e777f7314610/docs/benchmarks/ios-coreml.md)

The community Swift stack has more package dependencies than FluidAudio and shares MLX imports even in its Core ML module. Audit/pin them before adoption. Its explicit offline mode avoids model fetching; no account requirement was seen in those paths. By contrast TheStage's Qwen conversion explicitly requires online token initialization every process and fails offline startup, so it does not meet this requirement. [Swift manifest](https://github.com/soniqo/speech-swift/blob/1f54e56cf137078ed681a03e0955e777f7314610/Package.swift), [TheStage model card](https://huggingface.co/TheStageAI/Qwen3-ASR-0.6B)

### Integer-only mobile NPU work

**I-Parakeet**, September 2026, demonstrates why the entire model/runtime combination matters: integer-only Conformer on a Snapdragon/Qualcomm QNN phone reports 0.048 RTF and 612 MiB peak versus CPU FP16 0.36/1,517 MiB, with test-other WER increasing from 3.76 to 4.97%. It is Parakeet CTC, not Phonon-2 TDT. No downloadable iOS implementation/checkpoint was linked in the inspected paper; its calibration/static graphs cannot be assumed to transfer to Core ML/A19. Keep as optimization evidence, not an installable candidate. [Paper](https://arxiv.org/abs/2609.30846)

## Integration, integrity and attribution

The exact model revisions are in `Resources/model-integrity.json`. The file includes every required file from `Encoder.mlmodelc`, `Decoder.mlmodelc`, `JointDecisionv3.mlmodelc`, `Preprocessor.mlmodelc`, and `parakeet_vocab.json`, with sizes and publisher object hashes. Trees were requested at immutable revisions with Hugging Face's recursive API; each fit in one page, and pagination links were checked.

- Ultra: `95eaa59a39d4394f047a4dc5cce480388a60d1b6`.
- Phonon-2: `a812a0dfef205660787ef6234317ab79acf4d5d6`.
- Redux: `8c5ef97a29cd120dc76b354b3f22b7fec3b486f9`.

`sha256` is the raw-file SHA-256 for an LFS object. `gitBlobSHA1` is Git's blob object ID: hash `blob <byte count>\0` followed by file bytes, not just the file contents. These are integrity comparisons against publisher metadata, not independent signed provenance.

Pin FluidAudio to 0.17.5. Its normal ASR repositories default to Hugging Face `main`; set `ModelRegistry.revisionOverrides` before touching loaders, or use the pinned manifest to download into an app-owned version directory. Do downloading only during the explicit model download action, verify files, then use `AsrModels.loadLocal(from:version:)` for offline activation and dictation. `AsrModels.load(from:)` and `downloadAndLoad` can fetch/repair files and are unsuitable as a hidden dictation-time fallback. [Pinned model names](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Sources/FluidAudio/ModelNames.swift), [model registry](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Sources/FluidAudio/ModelRegistry.swift), [local loader](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift)

FluidAudio 0.17.5 has no external Swift package dependencies. It includes native clustering/task wrappers and, by default, a checksum-pinned NeMo text-processing binary. Swift 6.2's `traits: []` can omit that binary for an ASR-only package integration; older toolchains always link it. There is no installer, daemon or service activation in that package manifest. Its downloader contacts Hugging Face/CDN endpoints; recognition itself uses local Core ML. [Package manifest](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Package.swift), [Swift 6.2 manifest](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Package%40swift-6.2.swift)

Attribution must identify NVIDIA Parakeet, Moondream's Ultra/Redux modifications and Fermion Research's Phonon-2 modifications, link CC-BY-4.0, state Core ML conversion by FluidInference, and mark app changes. Preserve relevant model notices when distributing weights. FluidAudio remains Apache-2.0 with its own license/notice obligations. These licenses belong to the model/runtime; LocalScribe's source license does not replace them. [Ultra model license declaration](https://huggingface.co/moondream/parakeet-ultra), [Redux declaration](https://huggingface.co/moondream/parakeet-redux), [Phonon-2 notice](https://huggingface.co/FluidInference/phonon-2-coreml/blob/a812a0dfef205660787ef6234317ab79acf4d5d6/NOTICE), [FluidAudio license](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/LICENSE)

## Observed device run: default Phonon-2

The [initial benchmark artifact](benchmarks/phonon2-initial.json) records **4 October 2026**, physical `iPhone18,2`, iOS **27.2 (24B5089g)**, `DEBUG / Swift -O`, FluidAudio **0.17.5**, pinned default Phonon-2. It requests CPU + Neural Engine with GPU disabled. These are this project's observed results, separate from the publisher's Mac datasets above.

| Measurement | Observed result |
| --- | --- |
| Initial model preparation | **64.617 s**; app-process CPU time 1.743 s |
| Preparation process-footprint peak | **1.089 GB** |
| First transcription | **77.4 ms** for 5.855 s audio |
| Three warm transcriptions | **70.9 ms median**, 67.9–75.5 ms range |
| Process footprint after transcription | About **411 MB** |
| After model unload and 1 s settle | **42.5 MB** |
| Installed regular files | **357.726 MB logical**, **374.477 MB allocated**, excluding system compilation caches |
| Recognition | **0 errors / 17 reference words** on one LibriSpeech read-speech clip |

This first artifact uses schema 1, which did not record foreground lifecycle interruptions. Preparation elapsed time may include interruption or suspension; all timing remains preliminary until a controlled schema-2 rerun. The updated runner records lifecycle events, waits for foreground between operations and marks interrupted timing invalid. This verifies the default model's file-to-text integration, not personal dictation quality or microphone-to-keyboard latency. Repeated timing runs are not independent accuracy samples. “Cold” loading did not reset process, filesystem or Core ML caches; 50 ms memory sampling can miss brief peaks. Footprint includes the app/probe, not model weights alone. Thermal state changed from nominal to fair during preparation and remained fair; device activity/run conditions prevent attributing that change solely to the model.

Requested compute units do **not** prove actual ANE partitioning. Instruments tracing has not obtained the app process, so GPU/ANE utilization, energy and system memory pressure remain unmeasured. No airplane-mode startup, background microphone workflow or sustained thermal result is established by this artifact. The [g4/g1 checkpoint](benchmarks/phonon2-variants.json) is incomplete: g4 remained at loading after foreground was lost. Testing is paused pending phone availability; no g4/g1 performance result or encoder winner is selected.

## Device evidence needed before choosing the default

Measure complete stacks on the **same iPhone 17 Pro Max**, release build, airplane mode after download, same recordings and normalization. Include short dictation, names/technical terms, silence, noise and longer speech; keep the Mac Canary-Qwen transcripts as the quality reference. Do not run heavy Mac benchmarks while Devesh is using Control-Space dictation.

1. Record download bytes, installed files **and** additional Core ML cache growth. Separate first-ever compilation, fresh-process cached load and warm repeated inference. Save time to recording-ready, end-of-speech to final text, full processing time, and median/p95 over repeat runs.
2. Capture process physical footprint at idle/load/inference/peak/after unload; repeat 30 requests to expose retained buffers. File size and MLX cache limits are not process RAM. Record CPU time, Metal activity and actual Core ML execution with Instruments where available; requested compute units are not proof all work uses ANE.
3. Run a sustained session after cooldown, recording `ProcessInfo.thermalState`, latency drift, interruptions and memory warnings. Use Instruments energy/power evidence where available; battery percentage alone is a coarse observation, not watts. ANE use does not by itself prove lower power.
4. Exercise foreground/background, screen lock and return with real microphone/keyboard handoff. Apple prohibits scheduling new Metal work in ordinary background execution. CPU/ANE still need a legitimate audio/background lifecycle; backend selection alone does not grant indefinite execution. Verify offline cold launch without hidden download/token calls.

First compare Phonon-2 default/g4/g1 on ANE and Ultra on ANE. If all fail a required metric, compare Moonshine Small/Medium CPU and Qwen full Core ML; foreground MLX/dense-LUT GPU need a separate product-mode decision. Run the official Moonshine harness only after its dependency is authorized. Custom Fermion Swift/CPU ports, Moonshine-v2 Core ML and I-Parakeet-on-A19 require conversion/porting before they can be measured. No dependencies were installed for this research. [Apple background GPU rules](https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background), [Apple hardware specifications](https://www.apple.com/iphone-17-pro/specs/)

## Search and verification limits

X was used for discovery, but original Phonon-2 author [Manan Gupta's announcement](https://x.com/yoitsmanan/status/2104990913886031993) and FluidAudio-linked [EOU](https://x.com/sach1n/status/2003210626659680762)/[latency](https://x.com/y_earu/status/2038654262608064967) posts returned HTTP 403. Their claims/videos were not verified. Search engines and mirrors are discovery leads, not primary benchmark evidence. GitHub source, package artifacts, Hugging Face cards and the paper supplied the actionable evidence; this is not a comprehensive X timeline review.

Manifest hashes are publisher metadata, with the small non-LFS payloads independently compared to their Git blob IDs. The source-only investigation did not download or execute large weights; the later default Phonon-2 device benchmark downloaded and executed the pinned model as recorded above. Phonon-2 default, `phonon2-g4` and `phonon2-g1` are included in the integrity manifest at the same pinned revision. Variant files use canonical local `Encoder.mlmodelc` paths and explicit `remotePath` aliases to their source encoder directories. Small non-LFS variant payloads were independently verified in memory; shared files retain the already-verified metadata. The initial default run establishes execution and its recorded preparation/footprint/timing values. Comparative model/runtime suitability, reproducible cold loads, sustained energy, system pressure and personal WER remain open phone verification.
