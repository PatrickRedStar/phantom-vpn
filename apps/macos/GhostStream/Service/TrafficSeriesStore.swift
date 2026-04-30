//
//  TrafficSeriesStore.swift
//  GhostStream (macOS)
//
//  Shared runtime traffic samples for the console STREAM chart and menu-bar
//  mini chart.
//

import Foundation
import Observation
import PhantomKit

public struct TrafficSeries {
    public let rxSamples: [Double]
    public let txSamples: [Double]
    public let sampleCapacity: Int
}

private struct TrafficSample {
    let timestamp: Date
    let rxRateBps: Double
    let txRateBps: Double
    let bytesRx: UInt64
    let bytesTx: UInt64
}

private struct TrafficByteSnapshot {
    let timestamp: Date
    let bytesRx: UInt64
    let bytesTx: UInt64
}

@MainActor
@Observable
public final class TrafficSeriesStore {

    public static let shared = TrafficSeriesStore()

    public private(set) var currentRxRateBps: Double = 0
    public private(set) var currentTxRateBps: Double = 0
    public private(set) var currentRxBytes: UInt64 = 0
    public private(set) var currentTxBytes: UInt64 = 0
    public private(set) var sampleCount: Int = 0

    private let maxSamples = 3_600
    private var samples: [TrafficSample] = []
    private var lastByteSnapshot: TrafficByteSnapshot?
    private var sampleTask: Task<Void, Never>?
    private weak var stateManager: VpnStateManager?

    private init() {}

    public func start(stateManager: VpnStateManager) {
        self.stateManager = stateManager
        guard sampleTask == nil else { return }

        sampleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let stateManager = self.stateManager {
                    self.sample(frame: stateManager.statusFrame)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    public func stop() {
        sampleTask?.cancel()
        sampleTask = nil
        lastByteSnapshot = nil
    }

    public func series(capacity rawCapacity: Int) -> TrafficSeries {
        let capacity = max(2, rawCapacity)
        let clipped = samples.suffix(capacity)
        return TrafficSeries(
            rxSamples: clipped.map(\.rxRateBps),
            txSamples: clipped.map(\.txRateBps),
            sampleCapacity: capacity
        )
    }

    private func sample(frame: StatusFrame) {
        guard shouldSample(frame.state) else {
            currentRxRateBps = 0
            currentTxRateBps = 0
            lastByteSnapshot = nil
            return
        }

        let now = Date()
        let rxRate = resolvedRate(
            reported: frame.rateRxBps,
            currentBytes: frame.bytesRx,
            previousBytes: lastByteSnapshot?.bytesRx,
            previousDate: lastByteSnapshot?.timestamp,
            now: now
        )
        let txRate = resolvedRate(
            reported: frame.rateTxBps,
            currentBytes: frame.bytesTx,
            previousBytes: lastByteSnapshot?.bytesTx,
            previousDate: lastByteSnapshot?.timestamp,
            now: now
        )

        currentRxRateBps = rxRate
        currentTxRateBps = txRate
        currentRxBytes = frame.bytesRx
        currentTxBytes = frame.bytesTx
        lastByteSnapshot = TrafficByteSnapshot(
            timestamp: now,
            bytesRx: frame.bytesRx,
            bytesTx: frame.bytesTx
        )

        samples.append(
            TrafficSample(
                timestamp: now,
                rxRateBps: rxRate,
                txRateBps: txRate,
                bytesRx: frame.bytesRx,
                bytesTx: frame.bytesTx
            )
        )
        trimSamples()
        sampleCount = samples.count
    }

    private func shouldSample(_ state: ConnState) -> Bool {
        switch state {
        case .connecting, .reconnecting, .connected:
            return true
        case .disconnected, .error:
            return false
        }
    }

    private func resolvedRate(
        reported: Double,
        currentBytes: UInt64,
        previousBytes: UInt64?,
        previousDate: Date?,
        now: Date
    ) -> Double {
        let reported = sanitizeRate(reported)
        guard reported == 0,
              let previousBytes,
              let previousDate,
              currentBytes >= previousBytes
        else {
            return reported
        }

        let elapsed = max(now.timeIntervalSince(previousDate), 0.001)
        return Double(currentBytes - previousBytes) / elapsed
    }

    private func sanitizeRate(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }

    private func trimSamples() {
        guard samples.count > maxSamples else { return }
        samples.removeFirst(samples.count - maxSamples)
    }
}
