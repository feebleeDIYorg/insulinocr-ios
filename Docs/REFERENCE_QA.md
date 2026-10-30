# Offline reference comparison

Build the native analysis CLI in Release and analyze a screenshot independently
of its reference export. Keep original data and every generated result in an
ignored directory such as `PrivateFixtures`.

```sh
swift run -c release --package-path Packages/InsulinOCRCore insulinocr-analyze PrivateFixtures/case.png PrivateFixtures/case.analysis.json
python3 Scripts/compare_reference.py PrivateFixtures/case.analysis.json PrivateFixtures/reference.txt PrivateFixtures/case.qa.json --timezone Europe/Zurich
python3 -m unittest discover -s Scripts -p 'test_*.py' -v
```

The reference export is read only by the comparison tool. It never calibrates
or supplies missing values to OCR. The tool reads the documented mmol/L, U,
U/h and gram sections and interprets local export timestamps in the explicit
IANA timezone. Verify the screenshot's capture timestamp before interpreting
results; import-time fallback is not a valid clinical time anchor.

Matching uses a 150-second tolerance, maximizes one-to-one matches, then
minimizes their total time error. Glucose matching preserves chronological
order; event matching permits simultaneous types in any input order.
Duplicated observations cannot
inflate recall. Unknown numeric values are excluded from numeric matches and
remain in the observed denominator. Classified event stems match the same
reference kind; unclassified stems match geometry only. Unmatched detections
and unknown amounts are reported separately, so a zero wrong-known-amount
count alone never proves event acceptance.

Unmatched known amounts are counted explicitly. Reference events within 150
seconds of capture are retained in all denominators and separately flagged for
boundary review: an exported event may not yet be visible in the screenshot.
This flag does not excuse a missed visible stem or automatically pass a gate.

Basal error is weighted by overlap duration. Uncovered time and overlapping
OCR intervals are not silently filled. **The initial reference interpretation
holds each exported rate forward until the next row.** Confirm whether the
export represents interval starts, interval ends or aggregated delivery before
using this metric as a release gate. The script does not issue release approval.

The manufacturer's [CamAPS FX User Instructions](https://s3-eu-west-1.amazonaws.com/camdiab.user.manual/user_manual_fx_mmoll_commercial.pdf)
(2026-07-06 revision, page 44) describe text export but do not define interval
start/end or aggregation semantics in that export description. Do not infer
those semantics solely by choosing whichever comparison yields the lowest MAE.

Reports include input SHA-256 hashes, algorithm version, timezone and tolerance.
Results cover only the declared screenshot interval. Reference completeness,
timestamp accuracy, matching assumptions and full corpus/hold-out evaluation
remain separate acceptance requirements. CI tests use synthetic values only.

## Clock provenance

OCR clock labels determine graph dates independently of frozen capture. Invalid
clocks retain raw geometry for private QA but block all activity values. Never
interpret relative fallback dates as trusted timestamps.
