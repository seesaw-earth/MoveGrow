// swift-tools-version:5.9
// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
//
// Builds the Foundation-only motor rule engine (MoveGrow/Motor) as a library so it can be unit
// tested with `swift test` on macOS or Linux. The iOS app compiles the same files directly.
import PackageDescription

let package = Package(
    name: "MoveGrowMotor",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "MotorKit", targets: ["MotorKit"])],
    targets: [
        .target(name: "MotorKit", path: "MoveGrow/Motor", exclude: ["Resources"]),
        .testTarget(name: "MotorKitTests", dependencies: ["MotorKit"], path: "Tests/MotorKitTests",
                    exclude: ["Fixtures"]),
    ]
)
