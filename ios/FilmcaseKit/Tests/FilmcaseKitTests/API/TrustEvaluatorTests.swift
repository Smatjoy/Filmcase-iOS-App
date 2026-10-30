import Testing
@testable import FilmcaseKit

@Suite("TOFU pinning")
struct TrustEvaluatorTests {
    private let first = String(repeating: "ab", count: 32)
    private let second = String(repeating: "cd", count: 32)

    @Test("an unknown host is rejected and nothing is stored")
    func unpinned() async throws {
        let store = InMemoryPinStore()
        let evaluator = TrustEvaluator(store: store)
        let decision = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: first)
        #expect(decision == .unpinned(fingerprint: first))
        #expect(store.fingerprint(for: "filmcase.lan") == nil)
        let again = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: first)
        #expect(again == .unpinned(fingerprint: first))
    }

    @Test("an approved fingerprint is trusted afterwards")
    func approved() async throws {
        let store = InMemoryPinStore()
        let evaluator = TrustEvaluator(store: store)
        try await evaluator.approve(host: "filmcase.lan", fingerprint: first)
        #expect(store.fingerprint(for: "filmcase.lan") == first)
        let decision = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: first)
        #expect(decision == .trusted)
    }

    @Test("a different fingerprint is a mismatch and does not replace the pin")
    func mismatch() async throws {
        let store = InMemoryPinStore()
        let evaluator = TrustEvaluator(store: store)
        try await evaluator.approve(host: "filmcase.lan", fingerprint: first)
        let decision = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: second)
        #expect(decision == .mismatch(expected: first, presented: second))
        #expect(store.fingerprint(for: "filmcase.lan") == first)
        let again = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: first)
        #expect(again == .trusted)
    }

    @Test("pins are per host")
    func perHost() async throws {
        let evaluator = TrustEvaluator(store: InMemoryPinStore())
        try await evaluator.approve(host: "filmcase.lan", fingerprint: first)
        let other = try await evaluator.evaluate(host: "filmcase.tailnet.ts.net", presentedFingerprintSHA256Hex: second)
        #expect(other == .unpinned(fingerprint: second))
        try await evaluator.approve(host: "filmcase.tailnet.ts.net", fingerprint: second)
        let lan = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: first)
        let tailnet = try await evaluator.evaluate(host: "filmcase.tailnet.ts.net", presentedFingerprintSHA256Hex: second)
        #expect(lan == .trusted)
        #expect(tailnet == .trusted)
        let crossed = try await evaluator.evaluate(host: "filmcase.tailnet.ts.net", presentedFingerprintSHA256Hex: first)
        #expect(crossed == .mismatch(expected: second, presented: first))
    }

    @Test("case and separators in the fingerprint and host do not matter")
    func normalization() async throws {
        let evaluator = TrustEvaluator(store: InMemoryPinStore())
        try await evaluator.approve(host: "Filmcase.LAN", fingerprint: "AB:AB:ab ab")
        let decision = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: "abababab")
        #expect(decision == .trusted)
    }

    @Test("forgetting a host makes it unpinned again")
    func forget() async throws {
        let evaluator = TrustEvaluator(store: InMemoryPinStore())
        try await evaluator.approve(host: "filmcase.lan", fingerprint: first)
        try await evaluator.forget(host: "filmcase.lan")
        let decision = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: second)
        #expect(decision == .unpinned(fingerprint: second))
    }
}

@Suite("TokenStore")
struct TokenStoreTests {
    @Test("in-memory store saves and deletes")
    func roundTrip() async throws {
        let store: any TokenStore = InMemoryTokenStore()
        #expect(try await store.token() == nil)
        try await store.save(token: "abc")
        #expect(try await store.token() == "abc")
        try await store.deleteToken()
        #expect(try await store.token() == nil)
    }
}
