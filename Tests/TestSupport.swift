import Foundation

// A minimal harness for the pure correction logic. CorrectionRules has
// no AppKit, IMKit or Bundle dependency, so it compiles and runs straight
// from the command line -- see ../run-tests.sh.

var failures = 0
var checks = 0

func expect(_ actual: String?, _ expected: String?, _ label: String) {
    checks += 1
    guard actual != expected else { return }
    failures += 1
    print("FAIL \(label): expected \(expected.map { "\"\($0)\"" } ?? "nil"), got \(actual.map { "\"\($0)\"" } ?? "nil")")
}

func expect(_ actual: Bool, _ expected: Bool, _ label: String) {
    checks += 1
    guard actual != expected else { return }
    failures += 1
    print("FAIL \(label): expected \(expected), got \(actual)")
}
