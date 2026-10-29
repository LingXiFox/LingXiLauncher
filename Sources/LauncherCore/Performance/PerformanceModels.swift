import Foundation

/// A process identity that includes the kernel start time, not just a reusable PID.
public struct ProcessIdentity: Codable, Sendable, Equatable {
    public let processIdentifier: Int32
    public let startTimeSeconds: Int64
    public let startTimeMicroseconds: Int32

    public init(processIdentifier: Int32, startTimeSeconds: Int64, startTimeMicroseconds: Int32) {
        self.processIdentifier = processIdentifier
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

public struct PerformanceHardwareProfile: Codable, Sendable, Equatable {
    public let modelIdentifier: String
    public let cpuModel: String
    public let architecture: String
    public let physicalCores: Int
    public let logicalCores: Int
    public let memoryBytes: UInt64
    public let operatingSystem: String
    public let gpuModel: String?
    public let gpuMemoryBytes: UInt64?

    public init(
        modelIdentifier: String,
        cpuModel: String,
        architecture: String,
        physicalCores: Int,
        logicalCores: Int,
        memoryBytes: UInt64,
        operatingSystem: String,
        gpuModel: String? = nil,
        gpuMemoryBytes: UInt64? = nil
    ) {
        self.modelIdentifier = modelIdentifier
        self.cpuModel = cpuModel
        self.architecture = architecture
        self.physicalCores = physicalCores
        self.logicalCores = logicalCores
        self.memoryBytes = memoryBytes
        self.operatingSystem = operatingSystem
        self.gpuModel = gpuModel
        self.gpuMemoryBytes = gpuMemoryBytes
    }
}

public struct ProcessResourceSample: Codable, Sendable, Equatable {
    /// Seconds since the observed process was started.
    public let offsetSeconds: Double
    public let cpuPercent: Double
    public let residentBytes: UInt64

    public init(offsetSeconds: Double, cpuPercent: Double, residentBytes: UInt64) {
        self.offsetSeconds = offsetSeconds
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
    }
}

public enum BenchmarkWorkload: String, Codable, CaseIterable, Sendable {
    case startup
    case resourceReload
    case worldLoad
    case chunkGeneration
    case render
}

public struct BenchmarkOptions: Codable, Sendable, Equatable {
    public var warmupRuns: Int
    public var measuredRuns: Int
    public var timeoutSeconds: TimeInterval
    public var sampleIntervalSeconds: TimeInterval
    public var quickPlayWorld: String?
    public var workloads: [BenchmarkWorkload]

    public init(
        warmupRuns: Int = 1,
        measuredRuns: Int = 3,
        timeoutSeconds: TimeInterval = 180,
        sampleIntervalSeconds: TimeInterval = 0.25,
        quickPlayWorld: String? = nil,
        workloads: [BenchmarkWorkload] = BenchmarkWorkload.allCases
    ) {
        self.warmupRuns = max(0, min(warmupRuns, 5))
        self.measuredRuns = max(1, min(measuredRuns, 10))
        self.timeoutSeconds = max(30, min(timeoutSeconds, 900))
        self.sampleIntervalSeconds = max(0.1, min(sampleIntervalSeconds, 5))
        self.quickPlayWorld = quickPlayWorld
        self.workloads = workloads
    }
}

public struct BenchmarkPhaseDurations: Codable, Sendable, Equatable {
    public var startupSeconds: Double?
    public var javaToMenuSeconds: Double?
    public var worldLoadSeconds: Double?
    public var resourceReloadSeconds: Double?
    public var totalSeconds: Double?

    public init(
        startupSeconds: Double? = nil,
        javaToMenuSeconds: Double? = nil,
        worldLoadSeconds: Double? = nil,
        resourceReloadSeconds: Double? = nil,
        totalSeconds: Double? = nil
    ) {
        self.startupSeconds = startupSeconds
        self.javaToMenuSeconds = javaToMenuSeconds
        self.worldLoadSeconds = worldLoadSeconds
        self.resourceReloadSeconds = resourceReloadSeconds
        self.totalSeconds = totalSeconds
    }
}

public struct BenchmarkFrameMetrics: Codable, Sendable, Equatable {
    public let minimum: Double
    public let average: Double
    public let maximum: Double
    public let sampleCount: Int

    public init(minimum: Double, average: Double, maximum: Double, sampleCount: Int) {
        self.minimum = minimum
        self.average = average
        self.maximum = maximum
        self.sampleCount = sampleCount
    }
}

public struct BenchmarkRunResult: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let index: Int
    public let startedAt: Date
    public let process: ProcessIdentity?
    public let exitCode: Int32
    public let exitReason: String
    public let phases: BenchmarkPhaseDurations
    public let averageCPUPercent: Double?
    public let maximumCPUPercent: Double?
    public let peakResidentBytes: UInt64?
    public let samples: [ProcessResourceSample]
    public let frameMetrics: BenchmarkFrameMetrics?
    public let frameMetricsUnavailableReason: String?
    public let logPath: String?
    public let renderer: String?
    public let evidence: [String]

    public init(
        id: UUID = UUID(),
        index: Int,
        startedAt: Date,
        process: ProcessIdentity?,
        exitCode: Int32,
        exitReason: String,
        phases: BenchmarkPhaseDurations,
        averageCPUPercent: Double?,
        maximumCPUPercent: Double?,
        peakResidentBytes: UInt64?,
        samples: [ProcessResourceSample],
        frameMetrics: BenchmarkFrameMetrics? = nil,
        frameMetricsUnavailableReason: String? = "Minecraft does not expose a stable frame counter to an external launcher process.",
        logPath: String? = nil,
        renderer: String? = nil,
        evidence: [String] = []
    ) {
        self.id = id
        self.index = index
        self.startedAt = startedAt
        self.process = process
        self.exitCode = exitCode
        self.exitReason = exitReason
        self.phases = phases
        self.averageCPUPercent = averageCPUPercent
        self.maximumCPUPercent = maximumCPUPercent
        self.peakResidentBytes = peakResidentBytes
        self.samples = samples
        self.frameMetrics = frameMetrics
        self.frameMetricsUnavailableReason = frameMetricsUnavailableReason
        self.logPath = logPath
        self.renderer = renderer
        self.evidence = evidence
    }
}

public struct BenchmarkAggregate: Codable, Sendable, Equatable {
    public let samples: Int
    public let startupMin: Double?
    public let startupAverage: Double?
    public let startupMax: Double?
    public let worldLoadMin: Double?
    public let worldLoadAverage: Double?
    public let worldLoadMax: Double?
    public let cpuAverage: Double?
    public let cpuMax: Double?
    public let residentPeakBytes: UInt64?
    public let frameMetrics: BenchmarkFrameMetrics?
    public let frameMetricsUnavailableReason: String?

    public init(
        samples: Int,
        startupMin: Double?,
        startupAverage: Double?,
        startupMax: Double?,
        worldLoadMin: Double?,
        worldLoadAverage: Double?,
        worldLoadMax: Double?,
        cpuAverage: Double?,
        cpuMax: Double?,
        residentPeakBytes: UInt64?,
        frameMetrics: BenchmarkFrameMetrics?,
        frameMetricsUnavailableReason: String?
    ) {
        self.samples = samples
        self.startupMin = startupMin
        self.startupAverage = startupAverage
        self.startupMax = startupMax
        self.worldLoadMin = worldLoadMin
        self.worldLoadAverage = worldLoadAverage
        self.worldLoadMax = worldLoadMax
        self.cpuAverage = cpuAverage
        self.cpuMax = cpuMax
        self.residentPeakBytes = residentPeakBytes
        self.frameMetrics = frameMetrics
        self.frameMetricsUnavailableReason = frameMetricsUnavailableReason
    }
}

public struct BenchmarkReport: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let instanceID: String
    public let minecraftVersion: String
    public let loader: String
    public let hardware: PerformanceHardwareProfile
    public let options: BenchmarkOptions
    public let runs: [BenchmarkRunResult]
    public let aggregate: BenchmarkAggregate
    public let notes: [String]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        instanceID: String,
        minecraftVersion: String,
        loader: String,
        hardware: PerformanceHardwareProfile,
        options: BenchmarkOptions,
        runs: [BenchmarkRunResult],
        aggregate: BenchmarkAggregate,
        notes: [String] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.instanceID = instanceID
        self.minecraftVersion = minecraftVersion
        self.loader = loader
        self.hardware = hardware
        self.options = options
        self.runs = runs
        self.aggregate = aggregate
        self.notes = notes
    }
}

public struct JVMRecommendation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let heapMiB: Int
    public let jvmArguments: [String]
    public let rationale: String
    public let expectedEffect: String
    public let risk: String

    public init(
        id: String,
        title: String,
        heapMiB: Int,
        jvmArguments: [String],
        rationale: String,
        expectedEffect: String,
        risk: String
    ) {
        self.id = id
        self.title = title
        self.heapMiB = heapMiB
        self.jvmArguments = jvmArguments
        self.rationale = rationale
        self.expectedEffect = expectedEffect
        self.risk = risk
    }
}

public struct AppliedPerformanceProfile: Codable, Sendable, Equatable {
    public let instanceID: String
    public let heapMiB: Int?
    public let jvmArguments: [String]
    public let sourceRecommendationID: String?
    public let appliedAt: Date
    public let baselineReportID: UUID?

    public init(
        instanceID: String,
        heapMiB: Int?,
        jvmArguments: [String],
        sourceRecommendationID: String?,
        appliedAt: Date = Date(),
        baselineReportID: UUID? = nil
    ) {
        self.instanceID = instanceID
        self.heapMiB = heapMiB
        self.jvmArguments = jvmArguments
        self.sourceRecommendationID = sourceRecommendationID
        self.appliedAt = appliedAt
        self.baselineReportID = baselineReportID
    }
}

/// Injectable game-process boundary for deterministic benchmark tests. Production uses the
/// real LaunchService path; tests provide fixed run results without launching Minecraft.
public protocol BenchmarkProcessRunning: Sendable {
    func run(instance: Instance, options: BenchmarkOptions, index: Int) async throws -> BenchmarkRunResult
}

public protocol BenchmarkTimeSource: Sendable {
    func now() -> Date
}

public struct SystemBenchmarkClock: BenchmarkTimeSource {
    public init() {}
    public func now() -> Date { Date() }
}

public enum BenchmarkError: Error, LocalizedError, Sendable {
    case invalidInstance(String)
    case launchBusy
    case timedOut
    case cancelled
    case noMeasuredRuns
    case unsafeArgument(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInstance(let value): return "Invalid benchmark instance: \(value)"
        case .launchBusy: return "Another game process is already running"
        case .timedOut: return "Benchmark timed out"
        case .cancelled: return "Benchmark cancelled"
        case .noMeasuredRuns: return "No measured benchmark runs completed"
        case .unsafeArgument(let value): return "Unsafe JVM argument: \(value)"
        }
    }
}
