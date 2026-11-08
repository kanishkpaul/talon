// Shared between the admin helper (talond) and its client.
import Foundation

let helperMachName = "dev.talon.helper"

@objc(TalonHelperProtocol)
protocol HelperProtocol {
    /// Who the helper runs as and how many processes it can see.
    func status(reply: @escaping (String) -> Void)
    /// Kernel-enforced (fatal) memory ceiling on an already-running process.
    func capMemory(pid: Int32, megabytes: Int32, reply: @escaping (Int32, String) -> Void)
}
