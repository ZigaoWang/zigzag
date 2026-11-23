import CoreLocation
import WebKit

/// Where a page's `navigator.geolocation` gets its position. WebKit on macOS has no location source of its own (only
/// iOS falls back to Core Location, in WebGeolocationManagerProxy), so without one a site you allow never gets an
/// answer, and macOS never asks you or lists Zigzag under Location Services. Zigzag gives WebKit one through its C API,
/// as Safari does, backed by Core Location. Core Location is only started once a page you allowed asks (`SitePermissions`).
@MainActor
final class PageLocation: NSObject, CLLocationManagerDelegate {
    static let shared = PageLocation()

    /// Gives this configuration's process pool the location source; once per pool, since every tab in it shares it.
    static func attach(to configuration: WKWebViewConfiguration) {
        // Read by key: the property is deprecated, though every configuration still has one pool.
        guard let pool = configuration.value(forKey: "processPool") as AnyObject? else { return }
        shared.attach(to: pool)
    }

    /// Whether this WebKit has the C API the source goes through.
    static var isAvailable: Bool { API.shared != nil }
    /// How many process pools have the source.
    static var attachedPools: Int { shared.pools.count }

    private typealias Ref = UnsafeRawPointer
    /// A WebKit geolocation manager (one per process pool), by address, so it can cross to the main actor.
    private typealias Manager = UInt
    private typealias GetManager = @convention(c) (Ref) -> Ref?
    private typealias SetProvider = @convention(c) (Ref, Ref) -> Void
    private typealias DidChange = @convention(c) (Ref, Ref) -> Void
    private typealias DidFail = @convention(c) (Ref) -> Void
    private typealias Release = @convention(c) (Ref) -> Void
    private typealias MakePosition = @convention(c) (Double, Double, Double, Double, Bool, Double, Bool, Double, Bool, Double,
                                                     Bool, Double, Bool, Double) -> Ref?

    /// WebKit's C API (WKContext.h, WKGeolocationManager.h, WKGeolocationPosition.h), exported but not in the SDK.
    private struct API {
        let getManager: GetManager, setProvider: SetProvider, didChange: DidChange, didFail: DidFail
        let release: Release, makePosition: MakePosition

        static let shared: API? = {
            guard let webKit = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW) else { return nil }
            func load<T>(_ name: String, as type: T.Type) -> T? { dlsym(webKit, name).map { unsafeBitCast($0, to: type) } }
            guard let getManager = load("WKContextGetGeolocationManager", as: GetManager.self),
                  let setProvider = load("WKGeolocationManagerSetProvider", as: SetProvider.self),
                  let didChange = load("WKGeolocationManagerProviderDidChangePosition", as: DidChange.self),
                  let didFail = load("WKGeolocationManagerProviderDidFailToDeterminePosition", as: DidFail.self),
                  let release = load("WKRelease", as: Release.self),
                  let makePosition = load("WKGeolocationPositionCreate_c", as: MakePosition.self) else { return nil }
            return API(getManager: getManager, setProvider: setProvider, didChange: didChange, didFail: didFail,
                       release: release, makePosition: makePosition)
        }()
    }

    /// WKGeolocationProviderV1: version, clientInfo, then startUpdating, stopUpdating and setEnableHighAccuracy.
    /// WebKit copies it; it's kept for the life of the app all the same.
    private static let provider: UnsafeMutableRawPointer = {
        typealias Update = @convention(c) (Ref?, Ref?) -> Void
        typealias Accuracy = @convention(c) (Ref?, Bool, Ref?) -> Void
        let start: Update = { manager, _ in
            guard let manager else { return }
            let key = Manager(bitPattern: manager)
            MainActor.assumeIsolated { PageLocation.shared.start(key) }
        }
        let stop: Update = { manager, _ in
            guard let manager else { return }
            let key = Manager(bitPattern: manager)
            MainActor.assumeIsolated { PageLocation.shared.stop(key) }
        }
        let accuracy: Accuracy = { manager, on, _ in
            guard let manager else { return }
            let key = Manager(bitPattern: manager)
            MainActor.assumeIsolated { PageLocation.shared.setHighAccuracy(on, for: key) }
        }
        let pointer = MemoryLayout<UnsafeRawPointer>.size
        let memory = UnsafeMutableRawPointer.allocate(byteCount: pointer * 5, alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: pointer * 5)
        memory.storeBytes(of: Int32(1), as: Int32.self)
        memory.storeBytes(of: unsafeBitCast(start, to: UnsafeRawPointer.self), toByteOffset: pointer * 2, as: UnsafeRawPointer.self)
        memory.storeBytes(of: unsafeBitCast(stop, to: UnsafeRawPointer.self), toByteOffset: pointer * 3, as: UnsafeRawPointer.self)
        memory.storeBytes(of: unsafeBitCast(accuracy, to: UnsafeRawPointer.self), toByteOffset: pointer * 4, as: UnsafeRawPointer.self)
        return memory
    }()

    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return manager
    }()
    /// Pools given the source, kept so their geolocation managers stay valid.
    private var pools: [ObjectIdentifier: AnyObject] = [:]
    /// WebKit's geolocation managers with a page watching, and whether each wants high accuracy.
    private var watching: [Manager: Bool] = [:]

    private func attach(to pool: AnyObject) {
        let id = ObjectIdentifier(pool)
        guard pools[id] == nil, let api = API.shared else { return }
        // A WKContextRef is the WKProcessPool itself (API::Object::wrap).
        guard let manager = api.getManager(Unmanaged.passUnretained(pool).toOpaque()) else { return }
        pools[id] = pool
        api.setProvider(manager, Self.provider)
    }

    private func start(_ manager: Manager) {
        watching[manager] = watching[manager] ?? false
        switch locationManager.authorizationStatus {
        case .notDetermined:
            // macOS asks you now; the answer comes back in locationManagerDidChangeAuthorization.
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            fail(manager)
        default:
            if let last = locationManager.location, -last.timestamp.timeIntervalSinceNow < 60 { send(last, to: [manager]) }
            updateAccuracy()
            locationManager.startUpdatingLocation()
        }
    }

    private func stop(_ manager: Manager) {
        watching[manager] = nil
        if watching.isEmpty { locationManager.stopUpdatingLocation() } else { updateAccuracy() }
    }

    private func setHighAccuracy(_ on: Bool, for manager: Manager) {
        guard watching[manager] != nil else { return }
        watching[manager] = on
        updateAccuracy()
    }

    private func updateAccuracy() {
        locationManager.desiredAccuracy = watching.values.contains(true) ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
    }

    private func send(_ location: CLLocation, to managers: [Manager]) {
        guard let api = API.shared else { return }
        let altitude = location.verticalAccuracy >= 0, heading = location.course >= 0, speed = location.speed >= 0
        let floor = location.floor.map { Double($0.level) }
        guard let position = api.makePosition(location.timestamp.timeIntervalSince1970,
                                              location.coordinate.latitude, location.coordinate.longitude, location.horizontalAccuracy,
                                              altitude, location.altitude, altitude, location.verticalAccuracy,
                                              heading, location.course, speed, location.speed,
                                              floor != nil, floor ?? 0) else { return }
        for manager in managers { if let manager = Ref(bitPattern: manager) { api.didChange(manager, position) } }
        api.release(position)
    }

    private func fail(_ manager: Manager) {
        guard let manager = Ref(bitPattern: manager) else { return }
        API.shared?.didFail(manager)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard !watching.isEmpty else { return }
            switch locationManager.authorizationStatus {
            case .notDetermined:
                break
            case .denied, .restricted:
                for page in watching.keys { fail(page) }
                locationManager.stopUpdatingLocation()
            default:
                updateAccuracy()
                locationManager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let last = locations.last, last.horizontalAccuracy >= 0 else { return }
            send(last, to: Array(watching.keys))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            // Not known yet: Core Location keeps trying.
            if (error as? CLError)?.code == .locationUnknown { return }
            for page in watching.keys { fail(page) }
        }
    }
}
