import Foundation

/// ชุดเทสต์ขนาดจิ๋ว — พอสำหรับตรรกะล้วนๆ และรันได้ทุกเครื่องโดยไม่ต้องมี Xcode
enum Harness {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var current = ""

    static func suite(_ name: String, _ body: () throws -> Void) {
        current = name
        do {
            try body()
        } catch {
            failures.append("\(name): threw \(error)")
        }
    }

    static func expect(
        _ ok: Bool, _ what: String, file: String = #fileID, line: Int = #line
    ) {
        checks += 1
        guard !ok else { return }
        failures.append("\(current) / \(what)  (\(file):\(line))")
    }

    static func equal<T: Equatable>(
        _ a: T, _ b: T, _ what: String, file: String = #fileID, line: Int = #line
    ) {
        checks += 1
        guard a != b else { return }
        failures.append("\(current) / \(what)\n    got:      \(a)\n    expected: \(b)  (\(file):\(line))")
    }

    static func report() -> Int32 {
        if failures.isEmpty {
            print("ok — \(checks) checks passed")
            return 0
        }
        for f in failures { print("FAIL  \(f)") }
        print("\(failures.count) of \(checks) checks failed")
        return 1
    }
}

func suite(_ name: String, _ body: () throws -> Void) { Harness.suite(name, body) }
func expect(_ ok: Bool, _ what: String, file: String = #fileID, line: Int = #line) {
    Harness.expect(ok, what, file: file, line: line)
}
func equal<T: Equatable>(
    _ a: T, _ b: T, _ what: String, file: String = #fileID, line: Int = #line
) {
    Harness.equal(a, b, what, file: file, line: line)
}
