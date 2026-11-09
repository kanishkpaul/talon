// How late does a 1 Hz timer fire? Stands in for talond's sampler while a scan runs.
// Usage: jitter <seconds>   → prints ticks, mean and max lateness in ms.
import Foundation

let seconds = Int(CommandLine.arguments.dropFirst().first ?? "10") ?? 10
var late: [Double] = []
var next = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
for _ in 0..<seconds {
    let now = DispatchTime.now().uptimeNanoseconds
    if next > now { usleep(UInt32((next - now) / 1000)) }
    late.append(Double(DispatchTime.now().uptimeNanoseconds - next) / 1e6)
    next += 1_000_000_000
}
let mean = late.reduce(0, +) / Double(late.count)
print(String(format: "ticks %d · mean late %.2f ms · max late %.2f ms", late.count, mean, late.max() ?? 0))
