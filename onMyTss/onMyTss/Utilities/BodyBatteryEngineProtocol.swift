//
//  BodyBatteryEngineProtocol.swift
//  onMyTss
//
//  Created by Codex.
//

import Foundation

protocol BodyBatteryEngineProtocol {
    func recomputeAll() async throws
    func incrementalUpdate() async throws
}

extension BodyBatteryEngine: BodyBatteryEngineProtocol {}
