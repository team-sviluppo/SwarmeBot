// The drivers this engine has. Anything else in config.json becomes an
// unavailable shadow instance (Registry.notYetPortedReason).
import HarnessCore

public enum HarnessDrivers {
    @MainActor public static var all: [ProviderDriver] {
        [LocalEndpointDriver(), ClaudeDriver(), GrokDriver(), CodexDriver(), PiDriver(), AntigravityDriver(), BoxAgentDriver(), DeepSeekHarnessDriver()] + ACPHarnesses.all.map(ACPDriver.init)
    }
}
