// swift-tools-version:5.3
import PackageDescription

// Reduced SDK binding for the packet-tunnel target. The main app continues to
// use URnetworkSdk so its view-controller API remains available.
let package = Package(
	name: "URnetworkExtensionSdk",
	products: [
		.library(
			name: "URnetworkExtensionSdk",
			targets: ["URnetworkExtensionSdkBinary"]
		),
	],
	targets: [
		.binaryTarget(
			name: "URnetworkExtensionSdkBinary",
			path: "../../../sdk/build/apple/URnetworkExtensionSdk.xcframework"
		),
	]
)
