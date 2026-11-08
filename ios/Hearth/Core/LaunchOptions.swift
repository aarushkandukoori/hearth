// Developer launch arguments, parsed once. Example:
//   xcrun devicectl device process launch --console --device <id> com.aarushkandukoori.hearth -HearthBenchmark 1

import Foundation

struct LaunchOptions: Sendable {
    static let shared = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)

    /// "mock", "pie" or nil (automatic).
    var engine: String?
    /// Pie artifact (.metal.zt) file name to load instead of the chosen catalog model.
    var modelFile: String?
    var benchmark = false
    var uiTour = false
    /// With -HearthUITour: also save the window about 10 times a second to Documents/tour/footage (trailer footage).
    var footage = false
    var reset = false
    var skipOnboarding = false
    var seedDemo = false
    var verbose = false

    /// Developer runs keep Documents/hearth-console.log for `ios/scripts/device.sh pull`. Normal use doesn't.
    var writesLogFile: Bool { verbose || benchmark || uiTour }

    init(arguments: [String]) {
        func value(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        func flag(_ name: String) -> Bool {
            guard let v = value(name) else { return false }
            return v == "1" || v.lowercased() == "yes" || v.lowercased() == "true"
        }
        engine = value("-HearthEngine")
        modelFile = value("-HearthModel")
        benchmark = flag("-HearthBenchmark")
        uiTour = flag("-HearthUITour")
        footage = flag("-HearthFootage")
        reset = flag("-HearthReset")
        skipOnboarding = flag("-HearthSkipOnboarding")
        seedDemo = flag("-HearthSeedDemo")
        verbose = flag("-HearthVerbose")
    }
}
