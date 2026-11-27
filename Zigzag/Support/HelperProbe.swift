#if DEBUG
import Foundation

/// Tests only: started with `ZIGZAG_HELPER_PROBE` set to `picture`, `pdf` or `pdf-own`, this process is a bare client
/// of that helper instead of the app. It prints `helper <pid>` once the helper answers, then waits to be killed
/// (HelperLifetimeTests).
nonisolated enum HelperProbe {
    static func runIfAsked(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let kind = environment["ZIGZAG_HELPER_PROBE"] else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        switch kind {
        case "picture":
            nonisolated(unsafe) let connection = NSXPCConnection(serviceName: PictureService.name)
            connection.remoteObjectInterface = PictureService.interface()
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in exit(2) } as? PictureDecoding
            proxy?.decode(pixel, maxSide: 16) { _ in print("helper \(connection.processIdentifier)") }
            keep = connection
        case "pdf", "pdf-own":
            let link = XPCPDFLink(serviceName: PDFService.name, ownHelper: kind == "pdf-own")
            link.send({ $0.open(Data("%PDF-1.4 probe".utf8)) { _ in print("helper \(link.processIdentifier)") } },
                      failed: { _ in exit(2) })
            keep = link
        default:
            exit(2)
        }
        dispatchMain()
    }

    nonisolated(unsafe) private static var keep: AnyObject?

    /// A 1×1 PNG.
    private static let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!
}
#endif
