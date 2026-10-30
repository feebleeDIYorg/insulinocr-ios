import Foundation

/// Piecewise-linear absorption velocity integrated into a smooth remaining-carbohydrate curve.
public enum CarbohydrateAbsorptionModel {
    public static let delayMinutes = 10.0
    public static let riseTransition = 0.15
    public static let fallTransition = 0.50

    public static func remainingGrams(
        grams: Double,
        minutes: Double,
        absorptionDurationMinutes: Double
    ) -> Double {
        guard grams.isFinite,
              grams > 0,
              minutes.isFinite,
              absorptionDurationMinutes.isFinite,
              absorptionDurationMinutes > 0 else {
            return 0
        }

        let normalizedTime = (minutes - delayMinutes) / absorptionDurationMinutes
        if normalizedTime <= 0 { return grams }
        if normalizedTime >= 1 { return 0 }

        let scale = 2 / (1 + fallTransition - riseTransition)
        let absorbedFraction: Double
        if normalizedTime < riseTransition {
            absorbedFraction = 0.5 * scale
                * normalizedTime * normalizedTime / riseTransition
        } else if normalizedTime < fallTransition {
            absorbedFraction = scale * (normalizedTime - 0.5 * riseTransition)
        } else {
            let tailTime = normalizedTime - fallTransition
            absorbedFraction = scale * (
                fallTransition - 0.5 * riseTransition
                    + tailTime * (1 - 0.5 * tailTime / (1 - fallTransition))
            )
        }

        return grams * min(1, max(0, 1 - absorbedFraction))
    }
}
