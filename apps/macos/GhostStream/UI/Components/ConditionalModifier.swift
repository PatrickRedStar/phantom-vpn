//
//  ConditionalModifier.swift
//  GhostStream (macOS)
//
//  Условный модификатор — общий хелпер для случаев, когда модификатор
//  нужно НЕ применять вовсе (например, `.keyboardShortcut` нельзя снять
//  через nil-API). Изначально жил private в SidebarList (UI-R2-N15);
//  вынесен сюда, когда гейт по «палитра открыта» понадобился и другим
//  шорткатам (⌘K connect, ⌥⌘C/⇧⌘E/⇧⌘⌫/⌘F в логах — UI-AUDIT-07/2026).
//

import SwiftUI

extension View {
    /// Применяет `transform`, когда `condition == true`, иначе возвращает
    /// view без изменений. Меняет тип view (AnyView-free ветвление через
    /// @ViewBuilder), поэтому подходит для statically-known модификаторов
    /// вроде `.keyboardShortcut`.
    @ViewBuilder
    func `if`<Content: View>(
        _ condition: Bool,
        transform: (Self) -> Content
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
