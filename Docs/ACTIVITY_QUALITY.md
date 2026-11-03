# Quality at the frozen calculation time

Model policy `openaps-exponential+loopkit-cob/1.2.3` assesses uncertainty against
the saved reference date and the selected action durations. It does not change
the insulin or carbohydrate formulas.

The contextual reducer can exclude an uncertain event from calculation blockers
only when all reported event issues are localized, its geometry is reliable,
the clock was explicitly validated, its date
lies within the calibrated screenshot interval, and it is older than the entire
applicable action window. The window includes 2.5 minutes of event-assignment
uncertainty plus one minute of clock uncertainty. Carbohydrates also include the
model's ten-minute absorption delay. Unclassified events and inconsistent units
use the longer insulin/carbohydrate window.

Raw observations, warnings and correction revisions remain unchanged. The
effective export lists `inactiveUncertainObservationIDs` for audit. An optional
`activityAssessment` binds that projection to the reference date, DIA and
carbohydrate duration. A different date or duration requires reduction from the
raw run again; simulations and forecast copies retain this context.

Missing clock evidence prevents uncertainty from being discounted. Invalid clocks,
unlocalized warnings, recent unknown amounts, unknown events and incomplete
observed basal coverage still block the current calculation. A historical raw coverage issue can cease to block activity only
when the complete selected DIA is actually covered without gaps or overlaps.
No missing interval is replaced with zero or an assumed rate.

Older payloads without these optional fields continue to decode. The legacy
reducer remains conservative and does not expire uncertainty without explicit
calculation context. Raw OCR release acceptance and full-case QA remain separate
from a complete activity window.
