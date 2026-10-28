//
//  GsTokens.swift
//  GhostStream (macOS)
//
//  Шрифтовые роли и шкала отступов редизайна (apps/macos/design/mockup.html,
//  ADR 0022). Новые компоненты пользуются только ими:
//    текст        — системный SF Pro;
//    цифры        — Space Grotesk (скорость, таймер), без кириллицы;
//    адреса и IP  — JetBrains Mono.
//

import PhantomUI
import SwiftUI

enum GsType {
    /// 44 bold — заголовок состояния на главной.
    case display
    /// 28 bold — пустые состояния.
    case title
    /// 17 semibold — заголовки карточек и попапа.
    case headline
    /// 13 — основной текст, строки, кнопки.
    case body
    /// 12 — подписи и вторичный текст.
    case caption
    /// 36 Space Grotesk — крупные цифры: скорость, таймер.
    case metric
    /// 17 Space Grotesk — цифры в попапе и чипах.
    case metricSmall
    /// 12 JetBrains Mono — адреса, IP, SNI.
    case mono

    var font: Font {
        switch self {
        case .display:     return .system(size: 44, weight: .bold)
        case .title:       return .system(size: 28, weight: .bold)
        case .headline:    return .system(size: 17, weight: .semibold)
        case .body:        return .system(size: 13)
        case .caption:     return .system(size: 12)
        case .metric:      return GsFontSpec(name: GsFontName.spaceGroteskBold, size: 36).font.monospacedDigit()
        case .metricSmall: return GsFontSpec(name: GsFontName.spaceGroteskBold, size: 17).font.monospacedDigit()
        case .mono:        return .custom(GsFontName.jetBrainsMono, size: 12)
        }
    }
}

/// Шкала отступов макета.
enum GsSpace {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
}

extension View {
    func gsType(_ role: GsType) -> some View { font(role.font) }
}
