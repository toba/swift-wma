extension Array {
    /// Runs `body` over the array as one exclusive access.
    ///
    /// On a class property this pays one dynamic exclusivity check for the whole loop inside
    /// `body`, rather than one per element it writes.
    @inline(always)
    mutating func withExclusiveAccess<Result, Failure: Error>(
        _ body: (inout Self) throws(Failure) -> Result
    ) throws(Failure) -> Result { try body(&self) }
}
