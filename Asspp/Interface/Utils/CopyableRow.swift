//
//  CopyableRow.swift
//  Asspp
//

import SwiftUI

struct CopyableRow: View {
    let label: LocalizedStringKey
    let value: String
    var monospaced: Bool = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                Text(label)
                    .fixedSize()
                Spacer(minLength: 0)
                valueText
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                valueText
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var valueText: some View {
        Text(value)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}
