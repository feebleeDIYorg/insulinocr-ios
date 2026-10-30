# Physical-device OCR benchmark

`InsulinOCRDeviceBenchmark` runs the opt-in `DeviceAnalysisPerformanceTests` against the existing synthetic 2622×1206 fixture. Ordinary tests skip this benchmark; Simulator never satisfies the device latency gate.

Configure the development app privately, connect the target iPhone, and select the dedicated scheme and physical destination. Run only `InsulinOCRTests/DeviceAnalysisPerformanceTests`, with parallel testing disabled. Existing app data is retained; this test never imports, resets or exports cases.

Twenty sequential native analysis requests use a new engine per request, retaining the first sample. The JSON XCTest attachment reports all wall-clock durations measured with monotonic system uptime, the nearest-rank P95, maximum, dimensions and algorithm versions. P95 must be at most ten seconds. This measures OCR analysis, excluding Share, diagnostic rendering, persistence and activity calculation. It is a synthetic workload; real-image performance and the complete device flow require separate evidence.

Keep the complete device result bundle and build logs private: they can contain device and deployment identifiers. Only the synthetic attachment may be considered for publication after review. Do not add signing profiles, private configuration or screenshots to this repository.
