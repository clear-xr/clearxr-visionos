import Foundation

enum ResolutionPreset: String, CaseIterable, Identifiable {
    case eureka
    case clear
    case clearPerformance
    case balanced
    case performance

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .eureka:
            "Eureka"
        case .clear:
            "Clear"
        case .clearPerformance:
            "Clear Performance"
        case .balanced:
            "Balanced"
        case .performance:
            "Performance"
        }
    }

    var renderedResolution: Int {
        switch self {
        case .eureka:
            8000
        case .clear:
            6608
        case .clearPerformance:
            6400
        case .balanced:
            5440
        case .performance:
            4000
        }
    }

    var foveationInsetRatio: Double {
        switch self {
        case .eureka:
            0.50
        case .clear:
            0.40
        case .clearPerformance, .performance:
            0.20
        case .balanced:
            0.40
        }
    }

    var encodedResolution: Int {
        Int((Double(renderedResolution) * foveationInsetRatio).rounded())
    }
}

enum ConfigurationPresetChoice: String, CaseIterable, Identifiable {
    case eureka
    case clear
    case clearPerformance
    case balanced
    case performance
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .eureka:
            "Eureka"
        case .clear:
            "Clear"
        case .clearPerformance:
            "Clear Performance"
        case .balanced:
            "Balanced"
        case .performance:
            "Performance"
        case .custom:
            "Custom"
        }
    }

    var preset: ResolutionPreset? {
        switch self {
        case .eureka:
            .eureka
        case .clear:
            .clear
        case .clearPerformance:
            .clearPerformance
        case .balanced:
            .balanced
        case .performance:
            .performance
        case .custom:
            nil
        }
    }

    static let defaultChoice: ConfigurationPresetChoice = .balanced
}

struct StreamConfigurationMessage: Encodable, Sendable {
    let RenderedResolution: Int
    let EncodedResolution: Int
    let FoveationInsetRatio: Double
    let DefaultAppEnabled: Bool
    let AlphaTransparencyEnabled: Bool
}
