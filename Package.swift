// swift-tools-version:5.9
import PackageDescription

// Frameworks vendored from UTM.app. At build time we look in ./Vendor-Frameworks
// (a symlink to /Applications/UTM.app/Contents/Frameworks). At runtime they're
// copied into Maix.app/Contents/Frameworks and found via @rpath.
let spiceFrameworks: [String] = [
    "glib-2.0.0", "gobject-2.0.0", "gio-2.0.0", "gmodule-2.0.0", "gthread-2.0.0",
    "ffi.8", "intl.8", "iconv.2",
    "gstreamer-1.0.0", "gstallocators-1.0.0", "gstapp-1.0.0", "gstaudio-1.0.0",
    "gstbase-1.0.0", "gstpbutils-1.0.0", "gstvideo-1.0.0",
    "json-glib-1.0.0",
    "spice-client-glib-2.0.8",
    "pixman-1.0", "jpeg.62",
    // USB redirection
    "usb-1.0.0", "usbredirparser.1", "usbredirhost.1",
]

let linkedFrameworks: [LinkerSetting] = spiceFrameworks.flatMap {
    [LinkerSetting.unsafeFlags(["-framework", $0])]
}

let rpathAndSearch: [LinkerSetting] = [
    .unsafeFlags(["-F", "Vendor-Frameworks"]),
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
]

let package = Package(
    name: "MaixKiosk",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/utmapp/CocoaSpice.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "MaixStubs",
            path: "Sources/MaixStubs",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "MaixKiosk",
            dependencies: [
                .product(name: "CocoaSpice", package: "CocoaSpice"),
                "MaixStubs",
            ],
            path: "Sources/MaixKiosk",
            linkerSettings: rpathAndSearch + linkedFrameworks
        ),
        .executableTarget(
            name: "maix-qemu-launcher",
            path: "Sources/MaixLauncher",
            sources: ["Bootstrap.c", "main.c"],
            publicHeadersPath: ".",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
    ]
)
