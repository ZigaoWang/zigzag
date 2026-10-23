import Foundation
// Sends a debug command to a running Debug build of Zigzag.
let command = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(.init("app.zigzag.debug"), object: command, userInfo: nil, deliverImmediately: true)
