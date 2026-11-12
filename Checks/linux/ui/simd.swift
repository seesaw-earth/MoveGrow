// MoveGrow — Copyright (C) 2026 Ziqing Shi
// SPDX-License-Identifier: AGPL-3.0-only
// Stand-in for Apple's simd module (type-checking only): the functions the baby figure uses.
public func simd_length(_ v: SIMD3<Float>) -> Float { (v * v).sum().squareRoot() }
public func simd_length(_ v: SIMD2<Float>) -> Float { (v * v).sum().squareRoot() }
public func simd_normalize(_ v: SIMD3<Float>) -> SIMD3<Float> { v / simd_length(v) }
public func simd_normalize(_ v: SIMD2<Float>) -> SIMD2<Float> { v / simd_length(v) }
public func simd_dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { (a * b).sum() }
public func simd_cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
