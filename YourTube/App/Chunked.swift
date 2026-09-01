import Foundation

extension Collection {
    /// Splits into fixed-size batches, used to bound how many channel fetches
    /// are in flight at once during a feed refresh.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [Array(self)] }
        var result: [[Element]] = []
        var batch: [Element] = []
        batch.reserveCapacity(size)
        for element in self {
            batch.append(element)
            if batch.count == size {
                result.append(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { result.append(batch) }
        return result
    }
}
