// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MenuWidgets",
  platforms: [.macOS(.v15)],
  targets: [
    // Pure logic (time zones, astronomy, weather parsing, usage records):
    // no AppKit/SwiftUI, so it is unit-testable with `swift test`.
    .target(
      name: "WidgetsCore",
      resources: [.process("Resources")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // The menu-bar app: status items, popup panels, SwiftUI views.
    .executableTarget(
      name: "MenuWidgets",
      dependencies: ["WidgetsCore"],
      resources: [.process("Resources")],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
      name: "WidgetsCoreTests",
      dependencies: ["WidgetsCore"],
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
