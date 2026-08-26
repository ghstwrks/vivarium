import Foundation
import Testing

@testable import Vivarium

@Suite("What a failure exits with")
struct ExitStatusTests {
    /// Every stage, and whether a failure there is a statement about the guest
    /// (exit 1) or about Vivarium's ability to produce one (exit 70).
    ///
    /// Listed rather than derived: which side a stage falls on is a decision,
    /// and a new stage should be made here deliberately rather than inherited
    /// from whichever branch of a `switch` it happened to land in.
    static let expected: [(stage: VivStage, code: Int32)] = [
        (.preflight, ExitStatus.infrastructure),
        (.bundlePreparation, ExitStatus.infrastructure),
        (.restoreImage, ExitStatus.infrastructure),
        (.installation, ExitStatus.infrastructure),
        (.templateSnapshot, ExitStatus.infrastructure),
        (.runConfiguration, ExitStatus.infrastructure),
        (.codeStaging, ExitStatus.infrastructure),
        (.harvest, ExitStatus.infrastructure),
        (.cleanup, ExitStatus.infrastructure),
        (.provisioning, ExitStatus.testFailure),
        (.addressDiscovery, ExitStatus.testFailure),
        (.sshReadiness, ExitStatus.testFailure),
        (.sshCommand, ExitStatus.testFailure),
        (.testExecution, ExitStatus.testFailure),
        (.guestShutdown, ExitStatus.testFailure),
        (.virtioFSValidation, ExitStatus.testFailure),
        (.artifactAttach, ExitStatus.testFailure),
        (.artifactValidation, ExitStatus.testFailure),
        (.acceptance, ExitStatus.testFailure),
    ]

    @Test("each stage exits with the status its subject earns", arguments: expected)
    func classifiesEachStage(_ entry: (stage: VivStage, code: Int32)) {
        #expect(ExitStatus.of(VivError(entry.stage, "failed")) == entry.code)
    }

    @Test("every stage is accounted for")
    func coversEveryStage() {
        // A stage added without a line above would otherwise take whichever
        // exit code its switch branch gave it, unreviewed.
        let listed = Set(Self.expected.map(\.stage.rawValue))
        let all = Set(VivStage.allCases.map(\.rawValue))
        #expect(all.subtracting(listed).isEmpty)
    }

    @Test("an error that is not Vivarium's own exits 70")
    func classifiesForeignError() {
        struct Unexpected: Error {}
        #expect(ExitStatus.of(Unexpected()) == ExitStatus.infrastructure)
    }

    @Test("a wrapped guest failure exits 70, because run did not reach its question")
    func classifiesWrappedGuestFailure() {
        // The same error means different things to the two commands: for
        // `selftest` the guest is the subject, for `run` it is the apparatus.
        let guestFailure = VivError(.sshReadiness, "the guest never answered")
        #expect(ExitStatus.of(guestFailure) == ExitStatus.testFailure)
        #expect(ExitStatus.of(InfrastructureFailure(guestFailure)) == ExitStatus.infrastructure)
    }

    @Test("a wrapped error still describes what actually went wrong")
    func wrappingKeepsTheDescription() {
        let guestFailure = VivError(.sshReadiness, "the guest never answered")
        #expect(
            VivError.describe(InfrastructureFailure(guestFailure))
                == VivError.describe(guestFailure)
        )
    }
}

@Suite("How a failure reads")
struct VivErrorDescriptionTests {
    @Test("the stage, the message, and the hints are all in the description")
    func describesEverything() {
        let error = VivError(
            .harvest,
            "Nothing matched logs/**/*.",
            inspectionHints: ["ls -la Shared/artifacts"]
        )
        let text = error.description
        #expect(text.contains("[harvest]"))
        #expect(text.contains("Nothing matched logs/**/*."))
        #expect(text.contains("inspect: ls -la Shared/artifacts"))
    }

    @Test("an underlying error is reported with its domain and code")
    func describesUnderlying() {
        // `localizedDescription` routinely omits both for the NSErrors
        // Virtualization raises, which is what this rendering exists for.
        let underlying = NSError(domain: "VZErrorDomain", code: 5, userInfo: nil)
        let text = VivError(.installation, "The restore failed.", underlying: underlying).description
        #expect(text.contains("VZErrorDomain"))
        #expect(text.contains("code 5"))
    }
}
