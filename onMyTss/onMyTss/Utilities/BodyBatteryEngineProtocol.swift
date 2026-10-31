//
//  BodyBatteryEngineProtocol.swift
//  onMyTss
//
//  Created by Codex.
//

import Foundation

@MainActor
protocol BodyBatteryEngineProtocol {
    var isProcessing: Bool { get }
    func recomputeAll() async throws
    func incrementalUpdate() async throws
}

extension BodyBatteryEngine: BodyBatteryEngineProtocol {}
