# Licenses and attribution

LocalScribe iOS source is distributed under the Apache License 2.0 in `LICENSE`. This license does not replace the licenses governing downloaded models or linked dependencies. LocalScribe's changes include the native app/keyboard, protected storage, local installation verification, model-profile selection and performance measurements.

FluidAudio 0.17.5 is by FluidInference and its contributors, licensed [Apache-2.0](https://github.com/FluidInference/FluidAudio/blob/v0.17.5/LICENSE). The pinned package includes native wrappers and its own binary/text-normalization resources; retain its applicable license and notices when redistributing a build.

Downloaded speech weights are derivatives of [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), distributed under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/):

- [Phonon-2](https://huggingface.co/FermionResearch/Phonon-2): Fermion Research's English five-value quantization-aware retraining, converted to Core ML by [FluidInference](https://huggingface.co/FluidInference/phonon-2-coreml). The three app profiles select exact-weight encoder encodings; LocalScribe does not retrain the weights. See the [pinned upstream notice](https://huggingface.co/FluidInference/phonon-2-coreml/blob/a812a0dfef205660787ef6234317ab79acf4d5d6/NOTICE) for Fermion's changes and training-data attribution.
- [Parakeet Ultra](https://huggingface.co/moondream/parakeet-ultra) and [Parakeet Redux](https://huggingface.co/moondream/parakeet-redux): Moondream modifications of NVIDIA Parakeet, converted to Core ML by FluidInference. LocalScribe uses those conversions without retraining.

Models are downloaded from publishers rather than included in this source repository. Preserve each publisher's LICENSE/NOTICE files and training-data attribution if redistributing model weights. Immutable revisions, paths and hashes are recorded in `Resources/model-integrity.json`.
