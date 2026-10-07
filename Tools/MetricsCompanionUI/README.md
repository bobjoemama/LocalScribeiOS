# LocalScribe Metrics for Mac

Run `./build_local.sh` after preparing the sibling MetricsCompanion Python environment. The build creates `out/LocalScribe Metrics.app` and embeds absolute paths to this checkout's collector, trace tool and isolated Python interpreter. Rebuild if the checkout moves. Signing and installation are separate steps.

In **Live USB**, refresh, explicitly select your connected iPhone, paste the fresh connection code shown in LocalScribe, then start. Keep the iPhone app open. Stop or quit ends the owned collector process. Connection codes remain in memory only and pass through stdin.

In **Trace report**, open Instruments to record a trace, choose the trace bundle or XML export, enter the start and duration in seconds, and save a new JSON report. Import that report on the iPhone. The interval report describes the selected recording window across the trace; supported counters depend on the recording. An existing report is never overwritten.

The app uses one child process at a time and performs no dependency installation, pairing, recording, privileged setup, or automatic update. Dependency diagnostics are drained and discarded; the window displays fixed status messages.
