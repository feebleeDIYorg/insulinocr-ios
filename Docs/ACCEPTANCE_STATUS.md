# Development acceptance checklist

This repository contains source code and explicitly synthetic fixtures only.
Personal screenshots, reference exports, annotations, case archives and private
QA results stay outside version control. No real-image accuracy claim is made.

Before distribution, validate complete event recognition, basal/glucose accuracy,
model boundaries, physical-device performance, multi-device CloudKit behavior,
production schema, privacy declarations and an actual TestFlight device run.
Freeze extraction parameters before evaluating a private hold-out.

Synthetic validation includes the numerical oracle matrix, source completeness,
real operating-system sharing, correction, reanalysis, simulation, cold reopening
and an independently verified QA export. See UI_QA.md and THERAPY_VALIDATION.md.
