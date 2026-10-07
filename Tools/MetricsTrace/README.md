# Offline Instruments metrics

Use Apple Instruments to record Neural Engine or Metal activity on the paired iPhone, then save the chosen `.trace` locally. Device Developer Mode and a supported Instruments template are prerequisites for phone profiling; this tool does not enable either, launch an app or record a device. Inspect the trace in Instruments to identify the analysis window and confirm that the hardware activity lanes contain data.

```sh
python3 Tools/MetricsTrace/metrics_trace.py /path/to/Selected.trace \
  --start-ms 1000 --duration-ms 10000 --output /path/to/metricsReport1.json
```

An existing xctrace-exported `.xml` file can replace the trace argument. Traces with supported activity tables in multiple recording runs are rejected; export one chosen run to XML so independent time origins are not combined. The output must be a new file. Import that JSON through LocalScribe's Performance screen.

The tool invokes only the installed Xcode `xctrace export` executable, first with `--toc`, then with generated XPath expressions for discovered `ane-hw-intervals` and `metal-gpu-intervals` tables. Apple’s installed Instruments package documentation defines their start, duration and state columns. Availability and state formatting depend on the recording, platform and Instruments version; local schema documentation does not establish that a phone capture contains those fields. Unknown state labels fail rather than treating undocumented numeric codes as activity. The current supported explicit labels are listed in the script.

Active milliseconds are the union of explicit active/running/busy intervals, clipped to the supplied trace-relative window. Overlapping channels count once. Each counter requires the whole chosen window to lie within the earliest start and latest end of its exported interval rows, including explicit inactive rows. A window outside those bounds makes that counter unavailable; the import fails if neither counter covers it. This conservative edge check avoids interpreting unrecorded time as idle and can exclude legitimate idle capture edges. No verified capture-duration metadata is currently available, so the tool does not guess it from the activity rows or change the requested denominator. Duty cycle is `100 × active milliseconds / window milliseconds`. This measures time with recorded activity, not arithmetic throughput utilization, occupied cores, power or model-specific activity. Scope is the whole exported trace; other apps/system work can contribute. An absent table is unavailable, while a supported table containing only idle intervals yields zero recorded activity. An empty table is unavailable; exports with no supported interval rows are rejected. Verify capture completeness in Instruments before interpreting the result.

The version 1 JSON contract uses exactly these fields:

- `schemaVersion`: `1`
- `provenance`: `"trace-based (offline)"`
- `windowStartMs`, `durationMs`: finite, nonnegative start and positive duration
- `scope`: `"trace-wide; not attributed to LocalScribe"`
- `ane`, `gpu`: `null` when unavailable, otherwise `{"activeMs": number, "dutyCyclePercent": number}`
- `sourceSchemas`: recognized exported schema names
- `countersUnavailable`: explicit unavailable counter descriptions

Traces can contain private app/device data. Only start, duration and state contribute to the JSON; identity, event labels, channel names and file paths are excluded. Exported tables are held in a private temporary directory and removed after processing. xctrace exports entire selected tables before column filtering, so their temporary XML can still contain personal data. Nothing is uploaded, and full trace content is never printed. Stop/Quit cancellation terminates and reaps only this tool’s own xctrace child, then removes its temporary XML; an independently running Instruments session remains untouched. Treat both the original trace and any user-exported XML as personal data.

XML imports reject DTD/entity declarations, non-UTF-8 encoding, malformed references, unknown states and unsupported time types. A 64 MiB input/export budget and a 120-second per-command timeout bound offline processing; shorten/export a narrower recording if needed. These are import resource budgets, not recording limits.

Run focused tests with `python3 -m unittest discover -s Tools/MetricsTrace -p 'test_*.py'`. Tests use synthetic exports; no real phone trace has been captured or validated by this tool’s implementation checks.
