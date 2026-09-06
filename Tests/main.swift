import Foundation

correctionRulesTests()

print("\(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)
