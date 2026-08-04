// swift-tools-version: 6.0
import PackageDescription

// ไม่ใช้ testTarget เพราะเครื่องที่มีแค่ Command Line Tools (ไม่มี Xcode เต็มตัว)
// จะ *build* ชุดเทสต์ผ่านแต่ไม่รันมันเลยและยัง exit 0 ซึ่งอันตรายกว่าไม่มีเทสต์
// `swift run perchtest` เป็น executable ธรรมดา จึงรันได้เหมือนกันทุกเครื่อง
let package = Package(
    name: "perch",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PerchCore",
            path: "Sources/PerchCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "perch",
            dependencies: ["PerchCore"],
            path: "Sources/perch",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // ฝัง Info.plist ลงไบนารี — CLI ที่ไม่มีมันจะถูก CoreBluetooth ปฏิเสธเงียบๆ
            // (ไม่มี callback ไม่มี error ไม่มีกล่องขออนุญาต)
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/perch/Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "perchtest",
            dependencies: ["PerchCore"],
            path: "Sources/perchtest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
