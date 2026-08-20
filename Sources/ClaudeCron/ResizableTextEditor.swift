import AppKit
import SwiftUI

/// TextEditor with a drag handle below it; the chosen height is persisted
/// per storage key so prompt editors keep their size across jobs and launches.
struct ResizableTextEditor: View {
    @Binding var text: String
    var font: Font = .body
    let storageKey: String
    var defaultHeight: Double = 140

    @State private var height: Double
    @State private var dragBase: Double?
    @State private var handleHovered = false

    private static let minHeight = 80.0
    private static let maxHeight = 800.0

    init(text: Binding<String>, font: Font = .body,
         storageKey: String, defaultHeight: Double = 140) {
        _text = text
        self.font = font
        self.storageKey = storageKey
        self.defaultHeight = defaultHeight
        let saved = UserDefaults.standard.double(forKey: storageKey)
        _height = State(initialValue: saved > 0 ? saved : defaultHeight)
    }

    var body: some View {
        VStack(spacing: 3) {
            TextEditor(text: $text)
                .font(font)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.3)))
                .frame(height: height)

            Capsule()
                .fill(Color.secondary.opacity(handleHovered ? 0.8 : 0.4))
                .frame(width: 48, height: 5)
                .frame(maxWidth: .infinity)
                .frame(height: 14)
                .contentShape(Rectangle())
                .onHover { inside in
                    handleHovered = inside
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            let base = dragBase ?? height
                            dragBase = base
                            height = min(Self.maxHeight,
                                         max(Self.minHeight, base + value.translation.height))
                        }
                        .onEnded { _ in
                            dragBase = nil
                            UserDefaults.standard.set(height, forKey: storageKey)
                        }
                )
                .help("Drag to resize")
        }
    }
}
