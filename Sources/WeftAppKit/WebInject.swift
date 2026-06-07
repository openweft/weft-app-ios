import Foundation

/// The Swift side of the JS contract in weft-webui's
/// `src/lib/endpoints.ts` — identical to weft-app-core's `webinject`
/// package, so the SPA behaves the same regardless of host shell.
public enum WebInject {

    /// `window.__WEFT_ENDPOINTS__ = {...}` — install as a
    /// WKUserScript at .atDocumentStart.
    public static func initScript(_ endpoints: [Endpoint]) -> String {
        let arr = endpoints.map { ["name": $0.name, "url": $0.backend.url()] }
        let cfg: [String: Any] = ["endpoints": arr]
        let json = (try? JSONSerialization.data(withJSONObject: cfg))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.__WEFT_ENDPOINTS__ = \(json);"
    }

    /// `window.__weftFailoverNotice(from,to)` — raises the SPA banner.
    public static func failoverNotice(from: String?, to: String?) -> String {
        "window.__weftFailoverNotice && window.__weftFailoverNotice(\(quote(from)),\(quote(to)));"
    }

    private static func quote(_ s: String?) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s ?? ""])) ?? Data()
        // Encode as a 1-element array then strip the brackets to get a
        // properly-escaped JSON string literal.
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }
}
