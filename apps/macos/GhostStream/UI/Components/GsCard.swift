//
//  GsCard.swift
//  GhostStream (macOS)
//
//  Поверхности редизайна (mockup.html): непрозрачная карточка контента
//  (`.card`) и баннер обновления (`.upd`). Стекла здесь нет — оно только
//  на контролах.
//

import PhantomUI
import SwiftUI

/// Карточка контента: bgElev, волосяная рамка, радиус 26, необязательный
/// заголовок вида «Скорость» / «Подключение».
struct GsCard<Content: View>: View {
    private let title: String?
    private let content: Content

    @Environment(\.gsColors) private var C

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GsRadius.panel, style: .continuous)
        VStack(alignment: .leading, spacing: GsSpace.m) {
            if let title {
                Text(title)
                    .gsType(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(C.textDim)
            }
            content
        }
        .padding(GsSpace.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(C.bgElev, in: shape)
        .overlay(shape.stroke(C.hair, lineWidth: 1))
    }
}

/// «Доступна версия X — Скачать». Скачать открывает страницу релиза.
struct UpdateBanner: View {
    let release: UpdateChecker.Release
    let onDismiss: () -> Void

    @Environment(\.gsColors) private var C
    @Environment(\.openURL) private var openURL

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous)
        HStack(spacing: GsSpace.m) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 20))
                .foregroundStyle(C.signal)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: L("update.available"), release.version))
                    .gsType(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(C.bone)
                Text(String(format: L("update.current"), UpdateChecker.currentVersion))
                    .gsType(.caption)
                    .foregroundStyle(C.textDim)
            }
            Spacer(minLength: GsSpace.m)
            Button(L("update.download")) { openURL(release.url) }
                .gsType(.body)
                .fontWeight(.semibold)
                .foregroundStyle(C.bg)
                .gsProminentButton(tint: C.signal)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(C.textDim)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("update.hide"))
        }
        .padding(.leading, 14)
        .padding([.vertical, .trailing], 9)
        .background {
            shape.fill(C.bgElev).overlay(shape.fill(C.signal.opacity(0.09)))
        }
        .overlay(shape.stroke(C.signal.opacity(0.3), lineWidth: 1))
    }
}
