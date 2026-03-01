import SwiftUI

// A SwiftUI PIN input that renders 8 boxes like the web client.
// It captures input via a hidden SecureField/TextField and mirrors progress in boxes.
// The binding `text` is trimmed to at most `length` characters.
struct PinBoxesView: View {
    @Binding var text: String
    var length: Int = 8
    var asciiOnly: Bool = true
    var isEnabled: Bool = true
    var accessibilityLabel: String = "PIN"
    var onCommit: (() -> Void)? = nil

    @FocusState private var focused: Bool

    private func sanitized(_ s: String) -> String {
        var t = s
        if asciiOnly {
            t = String(t.unicodeScalars.filter { $0.isASCII })
        }
        if t.count > length {
            t = String(t.prefix(length))
        }
        return t
    }

    private var progressAnnounce: String {
        "\(text.count) of \(length) entered"
    }

    var body: some View {
        ZStack {
            // Hidden input that actually captures keyboard events
            // Use TextField to allow ASCII keyboard and paste; mask visually via opacity
            TextField("", text: Binding<String>(
                get: { text },
                set: { newVal in
                    let v = sanitized(newVal)
                    if v != text { text = v }
                }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(asciiOnly ? .asciiCapable : .default)
            .focused($focused)
            .opacity(0.01)
            .disabled(!isEnabled)
            .onSubmit { if text.count == length { onCommit?() } }
            .onChange(of: text) { newVal in
                if newVal.count == length { onCommit?() }
            }
            .accessibilityHidden(true)

            // Visual boxes
            HStack(spacing: 8) {
                ForEach(0..<length, id: \.self) { idx in
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(idx < text.count ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.3), lineWidth: 1)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(idx < text.count ? Color.accentColor.opacity(0.08) : Color(.secondarySystemBackground))
                            )
                        if idx < text.count {
                            Circle()
                                .fill(Color.primary)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .frame(width: 40, height: 52)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if isEnabled { focused = true } }
            .accessibilityElement()
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityValue(Text(progressAnnounce))
            .accessibilityAddTraits(.isKeyboardKey)
        }
    }
}

struct PinBoxesView_Previews: PreviewProvider {
    struct Demo: View {
        @State var v: String = ""
        var body: some View {
            VStack(spacing: 16) {
                PinBoxesView(text: $v)
                Text("Value: \(v)")
            }
            .padding()
        }
    }
    static var previews: some View { Demo() }
}
