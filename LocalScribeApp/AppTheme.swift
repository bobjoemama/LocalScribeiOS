import SwiftUI

/// Semantic colors adapt to the app’s effective appearance.
enum AppTheme {
    static let canvas = Color("Canvas")
    static let surface = Color("Surface")
    static let surfaceInset = Color("SurfaceInset")
    static let surfaceRaised = Color("SurfaceRaised")
    static let ink = Color("Ink")
    static let inkSecondary = Color("InkSecondary")
    static let inkTertiary = Color("InkTertiary")
    static let separator = Color("Separator")
    static let separatorStrong = Color("SeparatorStrong")
    static let controlBorder = Color("ControlBorder")
    static let onAccent = Color("OnAccent")
    static let focus = Color("Focus")
    static let recording = Color("Recording")
    static let onRecording = Color("OnRecording")
    static let recordingSoft = Color("RecordingSoft")
    static let success = Color("Success")
    static let successSoft = Color("SuccessSoft")
    static let warning = Color("Warning")
    static let warningSoft = Color("WarningSoft")
    static let error = Color("Error")
    static let errorSoft = Color("ErrorSoft")
    static let chartCPU = Color("ChartCPU")
    static let chartMemory = Color("ChartMemory")
    static let chartGPU = Color("ChartGPU")
    static let accent = Color("AccentColor")
}

extension View {
    func scribeForm() -> some View {
        scrollContentBackground(.hidden).background(AppTheme.canvas).tint(AppTheme.accent)
    }
}
