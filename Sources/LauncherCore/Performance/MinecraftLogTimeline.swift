import Foundation

/// Timings extracted from a Minecraft client log. These are observations, not invented
/// estimates: every phase is present only when the corresponding log evidence exists.
public struct MinecraftLogTimeline: Sendable, Equatable {
    public let firstTimestampSeconds: Double?
    public let menuSeconds: Double?
    public let resourceReloadSeconds: Double?
    public let worldLoadSeconds: Double?
    public let worldLoadPercentSamples: [Int]
    public let renderer: String?
    public let evidence: [String]

    public init(
        firstTimestampSeconds: Double? = nil,
        menuSeconds: Double? = nil,
        resourceReloadSeconds: Double? = nil,
        worldLoadSeconds: Double? = nil,
        worldLoadPercentSamples: [Int] = [],
        renderer: String? = nil,
        evidence: [String] = []
    ) {
        self.firstTimestampSeconds = firstTimestampSeconds
        self.menuSeconds = menuSeconds
        self.resourceReloadSeconds = resourceReloadSeconds
        self.worldLoadSeconds = worldLoadSeconds
        self.worldLoadPercentSamples = worldLoadPercentSamples
        self.renderer = renderer
        self.evidence = evidence
    }

    public static func parse(_ text: String) -> MinecraftLogTimeline {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var first: Double?
        var previous: Double?
        var dayOffset: Double = 0
        var menu: Double?
        var resourceStart: Double?
        var resourceEnd: Double?
        var worldStart: Double?
        var worldEnd: Double?
        var percents: [Int] = []
        var renderer: String?
        var evidence: [String] = []

        for line in lines {
            guard let time = timestampSeconds(in: line) else { continue }
            var absolute = time + dayOffset
            if let last = previous, absolute + 1 < last {
                // Logs span midnight; a backwards jump is interpreted as the next day.
                dayOffset += 86_400
                absolute = time + dayOffset
            }
            if first == nil { first = absolute }
            previous = absolute
            let offset = absolute - (first ?? absolute)

            let lower = line.lowercased()
            if menu == nil, lower.contains("sound engine started") {
                menu = offset
                evidence.append(line.trimmingCharacters(in: .whitespaces))
            }
            if lower.contains("reloading resourcemanager") {
                resourceStart = offset
                evidence.append(line.trimmingCharacters(in: .whitespaces))
            } else if resourceStart != nil, resourceEnd == nil, lower.contains("created:") {
                resourceEnd = offset
            }
            if lower.contains("preparing spawn area") {
                if worldStart == nil { worldStart = offset }
                if let percent = percentValue(in: line) {
                    if !percents.contains(percent) { percents.append(percent) }
                    if percent >= 100 { worldEnd = offset }
                }
                evidence.append(line.trimmingCharacters(in: .whitespaces))
            }
            if renderer == nil {
                if lower.contains("backend library:") || lower.contains("opengl version") || lower.contains("gl_renderer") {
                    renderer = line.trimmingCharacters(in: .whitespaces)
                }
            }
        }

        return MinecraftLogTimeline(
            firstTimestampSeconds: first,
            menuSeconds: menu,
            resourceReloadSeconds: resourceStart.flatMap { start in resourceEnd.map { max(0, $0 - start) } },
            worldLoadSeconds: worldStart.flatMap { start in worldEnd.map { max(0, $0 - start) } },
            worldLoadPercentSamples: percents,
            renderer: renderer,
            evidence: Array(evidence.prefix(12))
        )
    }

    private static func timestampSeconds(in line: String) -> Double? {
        guard let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]") else { return nil }
        let value = line[line.index(after: open)..<close]
        let parts = value.split(separator: ":")
        guard parts.count >= 2,
              let hour = Double(parts[0]),
              let minute = Double(parts[1]) else { return nil }
        let secondPart = parts[2].split(separator: ".").first.map(String.init) ?? "0"
        guard let second = Double(secondPart) else { return nil }
        return hour * 3600 + minute * 60 + second
    }

    private static func percentValue(in line: String) -> Int? {
        guard let range = line.range(of: "Preparing spawn area:") else { return nil }
        let tail = line[range.upperBound...]
        var digits = ""
        for character in tail {
            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }
}
