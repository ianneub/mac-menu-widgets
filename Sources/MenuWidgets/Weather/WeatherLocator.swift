import CoreLocation
import Foundation
import MapKit
import WidgetsCore

/// The Mac's location, shared by the widgets that follow it (the weather,
/// and the time pane's local row through `time.useLocation`). One locator
/// runs while any of them wants it, and stops when none does.
@MainActor
final class SharedLocation: ObservableObject {
  static let shared = SharedLocation()

  /// The last known place; nil while nothing follows the location, macOS
  /// denies it, or no fix has come in yet.
  @Published private(set) var place: LocatedPlace?
  /// Whether macOS lets the app use the location (unknown while nothing
  /// follows it).
  @Published private(set) var access: WeatherLocator.Access = .unknown
  private var locator: WeatherLocator?
  private var followers: Set<String> = []

  /// Starts or stops following the location for `follower` ("weather",
  /// "time"). Nothing is asked of macOS until someone calls `update()`.
  func follow(_ follower: String, _ on: Bool) {
    if on { followers.insert(follower) } else { followers.remove(follower) }
    if !followers.isEmpty, locator == nil {
      let loc = WeatherLocator()
      locator = loc
      loc.onPlace = { [weak self] _ in self?.publish() }
      loc.onAccess = { [weak self] _ in self?.publish() }
      publish()
    } else if followers.isEmpty, let loc = locator {
      loc.stop()
      locator = nil
      publish()
    }
  }

  /// Asks for a fix, and the first time for permission.
  func update() { locator?.update() }

  private func publish() {
    let a = locator?.access ?? .unknown
    let p = a == .denied ? nil : locator?.place
    if access != a { access = a }
    if place != p { place = p }
  }
}

/// The Mac's location for the weather widget: one Core Location fix at a
/// time (city-level accuracy is plenty), named by reverse geocoding. A fix
/// within WeatherLocation.minimumMove of the last place is ignored. The
/// last place is kept in UserDefaults so the panel names it at launch.
@MainActor
final class WeatherLocator: NSObject, CLLocationManagerDelegate {
  enum Access { case unknown, granted, denied }

  private let manager = CLLocationManager()
  private var geocoding = false
  private(set) var access: Access = .unknown
  private(set) var place: LocatedPlace?
  /// A new place (it moved, or got its name).
  var onPlace: (LocatedPlace) -> Void = { _ in }
  /// Access was granted or taken away.
  var onAccess: (Access) -> Void = { _ in }

  private static let defaultsKey = "weather.locatedPlace"

  override init() {
    super.init()
    if let d = UserDefaults.standard.data(forKey: Self.defaultsKey),
       let p = try? JSONDecoder().decode(LocatedPlace.self, from: d) {
      place = p
    }
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyKilometer
    access = Self.access(manager.authorizationStatus)
  }

  /// Asks for a fix, asking for permission first if macOS hasn't yet.
  func update() {
    switch manager.authorizationStatus {
    case .notDetermined: manager.requestWhenInUseAuthorization()
    case .denied, .restricted: break
    default: manager.requestLocation()
    }
  }

  func stop() {
    manager.delegate = nil
    manager.stopUpdatingLocation()
  }

  private static func access(_ status: CLAuthorizationStatus) -> Access {
    switch status {
    case .notDetermined: return .unknown
    case .denied, .restricted: return .denied
    default: return .granted
    }
  }

  // MARK: CLLocationManagerDelegate

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        let a = Self.access(status)
        guard a != self.access else { return }
        self.access = a
        self.onAccess(a)
        if a == .granted { self.manager.requestLocation() }
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let loc = locations.last else { return }
    DispatchQueue.main.async { MainActor.assumeIsolated { self.received(loc) } }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Usually "location unknown" right after wake or with Wi-Fi off; the
    // next refresh asks again, and the weather keeps the last place.
    NSLog("weather: location: \(error.localizedDescription)")
  }

  private func received(_ loc: CLLocation) {
    let lat = loc.coordinate.latitude, lon = loc.coordinate.longitude
    let unnamed = place?.name.isEmpty ?? true
    guard WeatherLocation.moved(from: place, latitude: lat, longitude: lon) || unnamed, !geocoding else { return }
    geocoding = true
    Task {
      let name = await Self.name(for: loc)
      geocoding = false
      // Without a name (offline), keep the point: the config's name shows
      // until a later fix gets one.
      let p = LocatedPlace(latitude: lat, longitude: lon, name: name ?? "")
      place = p
      if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: Self.defaultsKey) }
      onPlace(p)
    }
  }

  /// "Cupertino CA" for a point, or nil when geocoding fails.
  private static func name(for loc: CLLocation) async -> String? {
    if #available(macOS 26, *) {
      guard let request = MKReverseGeocodingRequest(location: loc),
            let item = try? await request.mapItems.first,
            let city = item.addressRepresentations?.cityWithContext ?? item.addressRepresentations?.cityName
      else { return nil }
      return WeatherLocation.displayName(city)
    } else {
      guard let mark = try? await CLGeocoder().reverseGeocodeLocation(loc).first else { return nil }
      let parts = [mark.locality, mark.administrativeArea].compactMap { $0 }.filter { !$0.isEmpty }
      return parts.isEmpty ? nil : WeatherLocation.displayName(parts.joined(separator: " "))
    }
  }
}
