import SwiftUI

struct AboutView: View {
    var body: some View {
        Form {
            Section("LocalScribe") {
                Text("Apache License 2.0").foregroundStyle(.secondary)
                documentLink("App license", resource: "LocalScribe-LICENSE")
            }
            Section("FluidAudio") {
                Text("Speech inference runtime by Fluid Inference. Apache License 2.0.")
                    .foregroundStyle(.secondary)
                documentLink("Runtime license", resource: "FluidAudio-LICENSE")
                sourceLink("FluidAudio source", "https://github.com/FluidInference/FluidAudio")
            }
            Section("Speech models") {
                Text("Phonon-2, Ultra and Redux use Creative Commons Attribution 4.0 and derive from NVIDIA’s Parakeet TDT 0.6B v3. Core ML conversions are by Fluid Inference.")
                    .foregroundStyle(.secondary)
                sourceLink("Original NVIDIA model", "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3")
                NavigationLink("Parakeet Ultra") {
                    ModelCreditsView(name: "Parakeet Ultra", credit: "Post-training by Moondream. Core ML conversion by Fluid Inference.", original: "https://huggingface.co/moondream/parakeet-ultra", conversion: "https://huggingface.co/FluidInference/parakeet-ultra-coreml")
                }
                NavigationLink("Phonon-2") {
                    ModelCreditsView(name: "Phonon-2", credit: "Quantization-aware retraining by Fermion Research. Core ML conversion and exact-weight encoder variants by Fluid Inference.", original: "https://huggingface.co/FermionResearch/Phonon-2", conversion: "https://huggingface.co/FluidInference/phonon-2-coreml")
                }
                NavigationLink("Parakeet Redux") {
                    ModelCreditsView(name: "Parakeet Redux", credit: "Ternary retraining by Moondream. Core ML conversion by Fluid Inference.", original: "https://huggingface.co/moondream/parakeet-redux", conversion: "https://huggingface.co/FluidInference/parakeet-redux-coreml")
                }
                documentLink("CC BY 4.0 license", resource: "CC-BY-4.0")
                sourceLink("CC BY 4.0 online", "https://creativecommons.org/licenses/by/4.0/")
            }
            Section("Parakeet Realtime") {
                Text("Licensed by NVIDIA Corporation under the NVIDIA Open Model License")
                    .foregroundStyle(.secondary)
                documentLink("Model license", resource: "parakeet-eou-320ms-LICENSE")
                documentLink("Model attribution", resource: "parakeet-eou-320ms-NOTICE")
                sourceLink("Original model", "https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1")
                sourceLink("Core ML conversion", "https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml")
            }
            Section {
                documentLink("Third-party notices", resource: "THIRD_PARTY_NOTICES")
            } footer: {
                Text("LocalScribe downloads the converted model files without retraining their weights. Each model retains its own license and attribution.")
            }
        }.navigationTitle("About & credits").navigationBarTitleDisplayMode(.inline)
    }

    private func sourceLink(_ title: String, _ address: String) -> some View {
        Link(title, destination: URL(string: address)!)
    }
    private func documentLink(_ title: String, resource: String) -> some View {
        NavigationLink(title) { BundledLegalDocument(title: title, resource: resource) }
    }
}

private struct ModelCreditsView: View {
    let name: String
    let credit: String
    let original: String
    let conversion: String
    var body: some View {
        Form {
            Section {
                Text(credit)
                Text("Creative Commons Attribution 4.0").foregroundStyle(.secondary)
                Link("Original model", destination: URL(string: original)!)
                Link("Core ML model", destination: URL(string: conversion)!)
            }
        }.navigationTitle(name).navigationBarTitleDisplayMode(.inline)
    }
}

private struct BundledLegalDocument: View {
    let title: String
    let resource: String
    private var text: String {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: resource, withExtension: "txt", subdirectory: "legal")
                ?? bundle.url(forResource: resource, withExtension: "txt")
                ?? bundle.url(forResource: resource, withExtension: "md", subdirectory: "legal")
                ?? bundle.url(forResource: resource, withExtension: "md"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return "This document could not be opened. About & credits includes links to the original licenses and model documentation."
        }
        return content
    }
    var body: some View {
        ScrollView {
            Text(text).font(.body.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}
