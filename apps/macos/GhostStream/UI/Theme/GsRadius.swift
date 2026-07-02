//
//  GsRadius.swift
//  GhostStream (macOS)
//
//  Единая система радиусов скругления для macOS-приложения (rounded-редизайн
//  2026-07, мокап full-rounded.html). Токены применяются ВЕЗДЕ вместо голых
//  `Rectangle()`:
//
//    окно / модальный шит      → window (16)
//    карточка / контейнер      → card   (12)
//    кнопка / поле ввода       → control(9)
//    чип / бейдж / пилюля-мелочь→ chip   (7)
//
//  Только macOS: shared PhantomUI-компоненты (iOS+macOS) НЕ трогаем.
//  Используется как `RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous)`
//  или через хелперы ниже.
//

import SwiftUI

public enum GsRadius {
    /// Окна и модальные шиты.
    public static let window: CGFloat = 16
    /// Карточки, контейнеры, строки-списки, панели.
    public static let card: CGFloat = 12
    /// Кнопки и поля ввода.
    public static let control: CGFloat = 9
    /// Чипы, бейджи, мелкие пилюли.
    public static let chip: CGFloat = 7
}

public extension RoundedRectangle {
    /// `RoundedRectangle(cornerRadius: r, style: .continuous)` короче.
    static func gs(_ r: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: r, style: .continuous)
    }
}

public extension View {
    /// Обводка скруглённым прямоугольником заданного радиуса.
    func gsStroke(_ color: Color, _ radius: CGFloat, lineWidth: CGFloat = 1) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(color, lineWidth: lineWidth))
    }

    /// Заливка-подложка скруглённым прямоугольником + опциональная обводка.
    func gsCard(fill: Color, stroke: Color? = nil, radius: CGFloat = GsRadius.card, lineWidth: CGFloat = 1) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(stroke.map { RoundedRectangle(cornerRadius: radius, style: .continuous).stroke($0, lineWidth: lineWidth) })
    }

    /// Скругление через clipShape.
    func gsClip(_ radius: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
