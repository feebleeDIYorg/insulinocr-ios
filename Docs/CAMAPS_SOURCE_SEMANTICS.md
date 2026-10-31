# Source semantics and outstanding ground truth

Reviewed source: [CamAPS FX User Instructions](https://s3-eu-west-1.amazonaws.com/camdiab.user.manual/user_manual_fx_mmoll_commercial.pdf), revision dated 2026-07-06, printed pages 42–43, “Detailed Graph”.

The manufacturer describes sensor glucose, delivered insulin, usual pre-programmed basal, meals, boluses and Auto mode status in the graph. Its legend distinguishes delivered insulin from usual basal. The described horizontal gray band is the visual glucose target range. The graph can be moved backward and forward in time.

These sections do not establish the temporal sampling convention of basal values in an exported text reference. They also do not establish an exact capture-time coordinate for a vertical gray suffix or justify treating an occluded/trailing basal segment as delivered insulin. Such interpretations remain unverified; this source alone cannot approve a forward-hold/backward-hold ground-truth model or a missing-history extrapolation.

Retain independent time calibration and completeness gates until stronger evidence is available. For basal validation, obtain documented reference semantics or two independent screenshot-interval annotations before claiming the release accuracy thresholds. Selecting the interpretation with the lowest measured error is not validation. Personal annotations and source images stay outside this repository.
