import Foundation

/// Clean-room implementation of the exponential insulin action model described by OpenAPS.
public enum InsulinActivityModel {
    public static func remainingUnits(
        units: Double,
        minutes: Double,
        durationMinutes: Double,
        peakMinutes: Double
    ) -> Double {
        guard units.isFinite,
              units > 0,
              minutes.isFinite,
              durationMinutes.isFinite,
              peakMinutes.isFinite,
              durationMinutes > 0,
              peakMinutes > 0,
              peakMinutes * 2 < durationMinutes,
              minutes >= 0,
              minutes < durationMinutes else {
            return 0
        }
        if minutes == 0 { return units }

        let tau = peakMinutes
            * (1 - peakMinutes / durationMinutes)
            / (1 - 2 * peakMinutes / durationMinutes)
        let a = 2 * tau / durationMinutes
        let scale = 1 / (1 - a + (1 + a) * exp(-durationMinutes / tau))
        let polynomial = minutes * minutes / (tau * durationMinutes)
            - (1 - a) * (minutes / tau + 1)
        let fraction = 1 - scale
            * (polynomial * exp(-minutes / tau) + 1 - a)

        return min(units, max(0, units * fraction))
    }
}
