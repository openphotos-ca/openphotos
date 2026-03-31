import Foundation
import Network
import UIKit

final class LocalNetworkPermissionRequester: NSObject, NetServiceDelegate {
    static let shared = LocalNetworkPermissionRequester()

    private let requestDefaultsKey = "app.localNetworkPermissionRequested"
    private let bonjourType = "_openphotos._tcp"

    private var browser: NWBrowser?
    private var netService: NetService?
    private var timeoutWorkItem: DispatchWorkItem?
    private var requestInFlight = false

    private override init() {
        super.init()
    }

    func requestOnFirstLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: requestDefaultsKey) == nil else { return }
        defaults.set(true, forKey: requestDefaultsKey)
        requestNow()
    }

    func requestNow() {
        guard !requestInFlight else { return }
        requestInFlight = true

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: bonjourType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.finishRequest()
                }
            case .failed(_), .waiting(_):
                DispatchQueue.main.async {
                    self.finishRequest()
                }
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.finishRequest()
            }
        }
        self.browser = browser

        let service = NetService(
            domain: "local.",
            type: bonjourType + ".",
            name: UIDevice.current.name,
            port: 9
        )
        service.delegate = self
        self.netService = service

        let timeout = DispatchWorkItem { [weak self] in
            self?.finishRequest()
        }
        timeoutWorkItem = timeout

        browser.start(queue: .main)
        service.publish()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    func netServiceDidPublish(_ sender: NetService) {
        DispatchQueue.main.async {
            self.finishRequest()
        }
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        DispatchQueue.main.async {
            self.finishRequest()
        }
    }

    private func finishRequest() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        browser?.cancel()
        browser = nil

        netService?.stop()
        netService = nil

        requestInFlight = false
    }
}
