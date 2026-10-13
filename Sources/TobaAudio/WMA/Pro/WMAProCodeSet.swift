internal import Foundation

/// Every code table a WMA Pro stream reads, built once for the process.
struct WMAProCodeSet: Sendable {
    /// The scale factor differences, which FFmpeg reads eight bits per level.
    let scale: WMACodeTable
    let scaleRunLevel: WMACodeTable

    /// The two coefficient run level tables, which a bit per channel picks between.
    let coefficients: [WMACodeTable]

    let vector4: WMACodeTable
    let vector2: WMACodeTable
    let vector1: WMACodeTable

    static let shared = WMAProCodeSet()

    private init?() {
        typealias T = WMAProTables
        guard let scale = WMACodeTable(
            lengths: T.scaleLengths, symbols: T.scaleSymbols, offset: -60, rootBits: 8),
              let scaleRunLevel = WMACodeTable(
                  lengths: T.scaleRunLevelLengths, symbols: T.scaleRunLevelSymbols),
              let coefficient0 = WMACodeTable(
                  lengths: T.coefficient0Lengths, symbols: T.coefficient0Symbols),
              let coefficient1 = WMACodeTable(
                  lengths: T.coefficient1Lengths, symbols: T.coefficient1Symbols),
              let vector4 = WMACodeTable(
                  lengths: T.vector4Lengths, symbols: T.vector4Symbols, offset: -1),
              let vector2 = WMACodeTable(
                  lengths: T.vector2Lengths, symbols: T.vector2Symbols, offset: -1),
              let vector1 = WMACodeTable(lengths: T.vector1Lengths, symbols: T.vector1Symbols)
        else { return nil }

        self.scale = scale
        self.scaleRunLevel = scaleRunLevel
        coefficients = [coefficient0, coefficient1]
        self.vector4 = vector4
        self.vector2 = vector2
        self.vector1 = vector1
    }
}
