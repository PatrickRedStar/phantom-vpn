import XCTest

/// Инвариант против рецидива «зацикленной шторки» menubar-попапа.
///
/// История: `.repeatForever`-анимации, запущенные через `withAnimation { … }`,
/// внутри `MenuBarExtra(.window)` дестабилизируют фрейм попапа — окно
/// бесконечно проигрывает анимацию открытия/закрытия (Wave 5 «phantom
/// popover», 763edb68; рецидив в PulseDot — июль 2026). `withAnimation`
/// создаёт транзакцию, которая накрывает раскладку окна при первом рендере,
/// и repeatForever наследуется анимацией самого попапа.
///
/// Правило: repeatForever допустим ТОЛЬКО как scoped-анимация
/// (`.animation(_, value:)` на конкретном view) — никогда внутри
/// `withAnimation`. Тест сканирует исходники всех view, которые рендерятся
/// в попапе (PhantomUI components + apps/macos UI), и падает при нарушении.
final class MenuBarAnimationInvariantTests: XCTestCase {

    func testNoRepeatForeverInsideWithAnimation() throws {
        let root = repoRoot()
        let scanRoots = [
            root.appendingPathComponent("apps/ios/Packages/PhantomKit/Sources/PhantomUI"),
            root.appendingPathComponent("apps/macos/GhostStream"),
        ]

        var violations: [String] = []
        for scanRoot in scanRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: scanRoot,
                includingPropertiesForKeys: nil
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension == "swift" {
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                guard source.contains("repeatForever") else { continue }

                // Комментарии не считаются: доки/постмортемы имеют право
                // упоминать запрещённый паттерн текстом.
                let lines = source.components(separatedBy: .newlines)
                func isComment(_ line: String) -> Bool {
                    line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                }
                for (index, line) in lines.enumerated()
                where line.contains("repeatForever") && !isComment(line) {
                    // Ищем withAnimation в пределах 5 строк кода выше —
                    // типичный паттерн `withAnimation(.x.repeatForever…) { … }`,
                    // разбитый переносами.
                    let windowStart = max(0, index - 5)
                    let context = lines[windowStart...index]
                        .filter { !isComment($0) }
                        .joined(separator: "\n")
                    if context.contains("withAnimation") {
                        violations.append("\(url.path):\(index + 1)")
                    }
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            withAnimation + repeatForever найдены — это ломает анимацию \
            открытия menubar-попапа (бесконечный выезд/заезд «шторки»). \
            Используйте scoped `.animation(_, value:)` на конкретном view. \
            Нарушения:\n\(violations.joined(separator: "\n"))
            """
        )
    }

    /// PhantomKitTests/<file> → …/apps/ios/Packages/PhantomKit/Tests/PhantomKitTests
    /// → 6 уровней вверх до корня репозитория.
    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
        }
        return url
    }
}
