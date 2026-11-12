# Quality at the frozen calculation time

Model policy `openaps-exponential+loopkit-cob/1.2.3` (and later) assesses uncertainty against
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

## Policy 1.3.0: results per category, no action-window history rule

Model policy `openaps-exponential+loopkit-cob/1.3.0` removes the requirement
that the screenshot covers the longer of DIA and carbohydrate absorption plus
delay. Earlier policies withheld all four results (`insufficientHistory`) for a
shorter screenshot; the reason code remains decodable for stored runs.

Each category is now released on its own data:

- **Basal IOB** needs gap-free, non-overlapping basal intervals from the start
  of the DIA window, or, when the screenshot is shorter than the DIA, from the
  first basal interval, which must begin within five minutes of the first
  observed instant. Interior gaps, overlaps and a path that does not reach the
  reference date still withhold it. Nothing is filled in.
- **Bolus IOB** and **active carbohydrates** need every event of their kind to
  have a known or confirmed amount. An unclassified event withholds both,
  because it can belong to either.
- **Total IOB** needs basal and bolus IOB.
- An invalid time axis withholds every category.

The app shows each released category even while another is withheld and gives
the reason on the withheld card. Decay charts and simulation still require all
categories.

Consequence, by the owner's decision: with a screenshot shorter than the action
window, insulin and carbohydrates delivered before the visible history are not
part of the result. Such a value is a lower bound of the modelled quantity, and
the app does not mark it.
