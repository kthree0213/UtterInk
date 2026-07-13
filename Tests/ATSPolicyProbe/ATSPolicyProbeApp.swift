import Foundation
import UtterInkCore
import UtterInkServices

@main
struct ATSPolicyProbeApp {
    static func main() async {
        guard CommandLine.arguments.count == 2,
              let baseURL = URL(string: CommandLine.arguments[1]) else {
            print(DiagnosticCode.polishTransport.rawValue)
            return
        }

        let profile = ProviderProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
            title: "ATS Policy Probe",
            baseURL: baseURL,
            modelID: "ats-probe-model",
            policy: .loopbackHTTP
        )
        let result = await OpenAICompatibleClient(clock: SystemAppClock()).validate(
            profile: profile,
            credential: SessionSecret(utf8: "")
        )

        switch result {
        case .ready:
            print("ATS_LOOPBACK_PASS")
        case let .failed(code):
            print(code.rawValue)
        }
    }
}
