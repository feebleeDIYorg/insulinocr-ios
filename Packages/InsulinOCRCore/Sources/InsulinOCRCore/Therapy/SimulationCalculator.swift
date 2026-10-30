import Foundation

public enum SimulationCalculator {
    public static func applying(
        events: [SimulationEvent],
        to data: EffectiveTherapyData
    ) -> EffectiveTherapyData {
        var boluses = data.boluses
        var carbohydrates = data.carbohydrates
        for event in events {
            switch event {
            case .bolus(let insulin): boluses.append(insulin)
            case .carbohydrate(let carbohydrate): carbohydrates.append(carbohydrate)
            }
        }
        return EffectiveTherapyData(
            basalSegments: data.basalSegments,
            boluses: boluses.sorted { $0.date < $1.date },
            carbohydrates: carbohydrates.sorted { $0.date < $1.date },
            glucoseSamples: data.glucoseSamples,
            unresolvedIssues: data.unresolvedIssues,
            sourceAnalysisRunID: data.sourceAnalysisRunID,
            sourceCorrectionRevisionID: data.sourceCorrectionRevisionID,
            observedHistoryMinutes: data.observedHistoryMinutes
        )
    }
}
