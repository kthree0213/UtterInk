import Foundation

extension IdentityExporter {
    @discardableResult
    static func validateProvenance(inputs: IdentityInputPaths) throws -> ValidatedProvenance {
        let data = try SecureFileReader.readRegularFile(
            at: inputs.provenanceFile,
            limit: 64 * 1_024,
            displayName: "provenance.json"
        )
        try validateJSONShape(data)

        let document: ProvenanceDocument
        do {
            document = try JSONDecoder().decode(ProvenanceDocument.self, from: data)
        } catch {
            throw IdentityExporterError.invalidInput("provenance JSON is malformed")
        }

        guard document.schemaVersion == 1,
              document.brand == "UtterInk",
              document.reviewDate == "2026-07-14",
              document.artifacts.count == ArtifactContract.all.count else {
            throw IdentityExporterError.invalidInput("provenance header or artifact count mismatch")
        }

        var seenIDs = Set<String>()
        var seenPaths = Set<String>()
        var seenHashes = Set<String>()
        var validated: [ValidatedProvenance.Artifact] = []

        for (artifact, contract) in zip(document.artifacts, ArtifactContract.all) {
            try rejectMissingOrProvisionalFields(artifact)
            guard artifact.matches(contract) else {
                throw IdentityExporterError.invalidInput("provenance rights or lock mismatch")
            }
            guard isSafeRepositoryPath(artifact.path),
                  seenIDs.insert(artifact.id).inserted,
                  seenPaths.insert(artifact.path).inserted,
                  seenHashes.insert(artifact.sha256).inserted else {
                throw IdentityExporterError.invalidInput("provenance identifiers must be unique and relative")
            }

            let artifactURL = inputs.repositoryRoot.appendingPathComponent(artifact.path)
            if artifact.publicDistribution {
                let bytes = try SecureFileReader.readRegularFile(
                    at: artifactURL,
                    limit: 2 * 1_024 * 1_024,
                    displayName: artifact.id
                )
                guard sha256(bytes) == artifact.sha256 else {
                    throw IdentityExporterError.invalidInput("public identity input SHA-256 mismatch")
                }
            } else {
                if let bytes = try SecureFileReader.readRegularFileIfPresent(
                    at: artifactURL,
                    limit: 32 * 1_024 * 1_024,
                    displayName: artifact.id
                ) {
                    guard sha256(bytes) == artifact.sha256 else {
                        throw IdentityExporterError.invalidInput("local review input SHA-256 mismatch")
                    }
                }
            }

            validated.append(.init(
                id: artifact.id,
                repositoryPath: artifact.path,
                sha256: artifact.sha256,
                publicDistribution: artifact.publicDistribution
            ))
        }
        return ValidatedProvenance(artifacts: validated)
    }

    private static func validateJSONShape(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw IdentityExporterError.invalidInput("provenance JSON is malformed")
        }
        guard let root = object as? [String: Any],
              Set(root.keys) == ["schemaVersion", "brand", "reviewDate", "artifacts"],
              let artifacts = root["artifacts"] as? [[String: Any]] else {
            throw IdentityExporterError.invalidInput("provenance contains unknown or missing keys")
        }
        let artifactKeys: Set<String> = [
            "id", "sha256", "path", "purpose", "creator", "copyrightOwner", "rightsScope",
            "publicationAuthority", "license", "trademarkTreatment", "reviewer", "publicDistribution",
        ]
        guard artifacts.allSatisfy({ Set($0.keys) == artifactKeys }) else {
            throw IdentityExporterError.invalidInput("provenance artifact contains unknown or missing keys")
        }
    }

    private static func rejectMissingOrProvisionalFields(_ artifact: ProvenanceArtifact) throws {
        let values = [
            artifact.id, artifact.sha256, artifact.path, artifact.purpose, artifact.creator,
            artifact.copyrightOwner, artifact.rightsScope, artifact.publicationAuthority,
            artifact.license, artifact.trademarkTreatment, artifact.reviewer,
        ]
        let forbidden = Set(["", "tbd", "unknown", "provisional", "pending"])
        guard values.allSatisfy({ !forbidden.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }) else {
            throw IdentityExporterError.invalidInput("provenance contains an empty or provisional field")
        }
    }

    private static func isSafeRepositoryPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(".") else {
            return false
        }
        return true
    }

}

private struct ProvenanceDocument: Decodable {
    let schemaVersion: Int
    let brand: String
    let reviewDate: String
    let artifacts: [ProvenanceArtifact]
}

private struct ProvenanceArtifact: Decodable {
    let id: String
    let sha256: String
    let path: String
    let purpose: String
    let creator: String
    let copyrightOwner: String
    let rightsScope: String
    let publicationAuthority: String
    let license: String
    let trademarkTreatment: String
    let reviewer: String
    let publicDistribution: Bool

    func matches(_ contract: ArtifactContract) -> Bool {
        id == contract.id
            && sha256 == contract.sha256
            && path == contract.path
            && purpose == contract.purpose
            && creator == contract.creator
            && copyrightOwner == contract.copyrightOwner
            && rightsScope == contract.rightsScope
            && publicationAuthority == contract.publicationAuthority
            && license == contract.license
            && trademarkTreatment == contract.trademarkTreatment
            && reviewer == contract.reviewer
            && publicDistribution == contract.publicDistribution
    }
}

private struct ArtifactContract {
    let id: String
    let sha256: String
    let path: String
    let purpose: String
    let creator: String
    let copyrightOwner: String
    let rightsScope: String
    let publicationAuthority: String
    let license: String
    let trademarkTreatment: String
    let reviewer: String
    let publicDistribution: Bool

    static let apacheAuthority = "Original creator and sole copyright holder; authorized for Apache-2.0 publication"
    static let apacheTrademark = "Apache-2.0 grants no trademark rights; UtterInk name and final production marks remain subject to separate trademark policy and final review"

    static let all: [ArtifactContract] = [
        .init(
            id: "selected-logo-route",
            sha256: IdentityArtifactLock.selectedRouteSHA256,
            path: "Brand/Source/selected-logo-route.json",
            purpose: "identity-direction-record",
            creator: "kthree0213",
            copyrightOwner: "kthree0213",
            rightsScope: "Entire artifact",
            publicationAuthority: apacheAuthority,
            license: "Apache-2.0",
            trademarkTreatment: apacheTrademark,
            reviewer: "kthree0213",
            publicDistribution: true
        ),
        .init(
            id: "identity-handoff",
            sha256: IdentityArtifactLock.handoffSHA256,
            path: "Brand/Source/identity-handoff.md",
            purpose: "identity-production-handoff",
            creator: "kthree0213",
            copyrightOwner: "kthree0213",
            rightsScope: "Entire artifact",
            publicationAuthority: apacheAuthority,
            license: "Apache-2.0",
            trademarkTreatment: apacheTrademark,
            reviewer: "kthree0213",
            publicDistribution: true
        ),
        .init(
            id: "right-cursor-vector",
            sha256: IdentityArtifactLock.rightCursorSHA256,
            path: "Brand/Source/B-right-cursor.svg",
            purpose: "production-identity-vector-draft",
            creator: "kthree0213",
            copyrightOwner: "kthree0213",
            rightsScope: "Entire artifact",
            publicationAuthority: apacheAuthority,
            license: "Apache-2.0",
            trademarkTreatment: apacheTrademark,
            reviewer: "kthree0213",
            publicDistribution: true
        ),
        .init(
            id: "menu-bar-comparison",
            sha256: IdentityArtifactLock.comparisonSHA256,
            path: "dist/identity-input-review/menu-bar-comparison.png",
            purpose: "local-review-montage",
            creator: "kthree0213",
            copyrightOwner: "kthree0213",
            rightsScope: "Original montage selection and arrangement and original UtterInk candidate marks only; embedded third-party reference imagery and marks are excluded",
            publicationAuthority: "Original review montage authorized for local review only and excluded from public distribution",
            license: "Local review only; not distributed",
            trademarkTreatment: "Embedded third-party marks are reference-only; no ownership or trademark rights are asserted; the file is excluded from public distribution",
            reviewer: "kthree0213",
            publicDistribution: false
        ),
    ]
}
