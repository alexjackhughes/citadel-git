import Foundation
import Darwin

// A private process group lets Cancel stop Git and its hooks/helpers together.
_ = setsid()
let arguments = ["/usr/bin/git"] + Array(CommandLine.arguments.dropFirst())
let argv = arguments.map { strdup($0) } + [nil]
_ = argv.withUnsafeBufferPointer { buffer in
    execv("/usr/bin/git", UnsafeMutablePointer(mutating: buffer.baseAddress!))
}
perror("git")
exit(127)
