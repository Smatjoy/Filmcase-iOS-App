import Testing
@testable import FilmcaseKit

@Suite("TOFU pinning")
struct TrustEvaluatorTests {
    private let first = String(repeating: "ab", count: 32)
    private let second = String(repeating: "cd", count: 32)

    @Test("first use stores the pin and trusts it")
    func firstUse() async throws {
        let store = InMemoryPinStore()
        let evaluator = TrustEvaluator(store: store)
        let decision = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: first)
        #expect(decision == .trustOnFirstUse(fingerprint: first))
        #expect(store.fingerprint(for: "filmcase.lan") == first)
    }

    @Test("the same fingerprint afterwards is trusted")
    func sameFingerprint() async throws {
        let evaluator = TrustEvaluator(store: InMemoryPinStore())
        _ = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: first)
        let decision = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: first)
        #expect(decision == .trusted)
    }

    @Test("a different fingerprint is a mismatch and does not replace the pin")
    func mismatch() async throws {
        let store = InMemoryPinStore()
        let evaluator = TrustEvaluator(store: store)
        _ = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: first)
        let decision = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: second)
        #expect(decision == .mismatch(expected: first, presented: second))
        #expect(store.fingerprint(for: "filmcase.lan") == first)
        let again = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: first)
        #expect(again == .trusted)
    }

    @Test("pins are per host")
    func perHost() async throws {
        let evaluator = TrustEvaluator(store: InMemoryPinStore())
        _ = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: first)
        let other = try await evaluator.evaluate(host: "filmcase.tailnet.ts.net", presentedFingerprintSHA256Hex: second)
        #expect(other == .trustOnFirstUse(fingerprint: second))
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
        _ = try await evaluator.evaluate(host: "Filmcase.LAN", presentedFingerprintSHA256Hex: "AB:AB:ab ab")
        let decision = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: "abababab")
        #expect(decision == .trusted)
    }

    @Test("forgetting a host makes the next connection first-use again")
    func forget() async throws {
        let evaluator = TrustEvaluator(store: InMemoryPinStore())
        _ = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: first)
        try await evaluator.forget(host: "filmcase.lan")
        let decision = try await evaluator.evaluate(host: "filmcase.lan", presentedFingerprintSHA256Hex: second)
        #expect(decision == .trustOnFirstUse(fingerprint: second))
    }
}

@Suite("TokenStore")
struct TokenStoreTests {
    @Test("in-memory store saves and deletes")
    func roundTrip() async throws {
        let store = InMemoryTokenStore()
        #expect(try await store.token() == nil)
        try await store.save(token: "abc")
        #expect(try await store.token() == "abc")
        try await store.deleteToken()
        #expect(try await store.token() == nil)
    }
}
