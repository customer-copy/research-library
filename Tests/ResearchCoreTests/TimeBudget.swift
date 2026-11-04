import Foundation

/// Wall-clock budget for performance assertions. Local runs keep the strict
/// budget; shared CI runners (GitHub sets CI=true) get 5x headroom so timing
/// checks still catch real stalls (network/OCR waits) without flaking.
func timeBudget(_ seconds: Double) -> Duration {
  let scale = ProcessInfo.processInfo.environment["CI"] == "true" ? 5.0 : 1.0
  return .milliseconds(Int64(seconds * scale * 1000))
}
