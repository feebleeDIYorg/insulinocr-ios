# Capture marker and observed therapy

The solid neutral capture rule separates historical therapy from the shaded future panel. Native analysis 1.11.0 records its bounds in the optional `layout.captureMarkerBounds` field. Earlier runs without this field remain decodable.

Detection requires a narrow, continuous neutral rule, a historical light basal background on the left and future shading on the right. A normal gridline, right chart axis, or ambiguous pair of boundaries is insufficient. A confirmed marker overrides the old minimum usable chart width, including when the marker precedes the chart midpoint.

Basal, glucose and event geometry stop at the marker's **left** edge. Event pill crops and candidate text also stop there. Axis labels remain calibration evidence; future therapy never contributes to extracted values.

The marker's paint width has no duration. If the basal path actually reaches its past edge, that terminal interval ends at capture time. This requires an independently valid time axis whose clock at the marker's far edge agrees with capture time within one minute. Provenance records this endpoint interpretation. A gap before the marker is not extended, a missing marker does not authorize extension, and an inconsistent clock continues to block calculations.

A recognized chart with less than one hour of observed history remains analyzable when its full chart window is supported. History completeness is evaluated independently; future delivery is never used to satisfy DIA or carbohydrate history requirements.

Regression coverage uses generated pixels, including a deliberately different future basal rate and future event stem. Private screenshots and case-specific results are not repository fixtures.
