import SwiftUI

/// LiveChar look: cyan = your camera, pink = the character, gold = time/balance.
enum Theme {
    static let ink = Color(red: 0.055, green: 0.063, blue: 0.125)      // #0e1020
    static let stage = Color(red: 0.090, green: 0.102, blue: 0.200)    // #171a33
    static let raise = Color(red: 0.122, green: 0.137, blue: 0.267)    // #1f2344
    static let well = Color(red: 0.063, green: 0.075, blue: 0.157)     // #101328
    static let line = Color(red: 0.173, green: 0.192, blue: 0.376)     // #2c3160
    static let text = Color(red: 0.933, green: 0.941, blue: 1.0)       // #eef0ff
    static let dim = Color(red: 0.604, green: 0.627, blue: 0.780)      // #9aa0c7
    static let you = Color(red: 0.310, green: 0.847, blue: 0.922)      // #4fd8eb
    static let char = Color(red: 1.0, green: 0.361, blue: 0.541)       // #ff5c8a
    static let gold = Color(red: 1.0, green: 0.784, blue: 0.341)       // #ffc857
    static let ok = Color(red: 0.357, green: 0.890, blue: 0.631)       // #5be3a1
    static let bad = Color(red: 1.0, green: 0.420, blue: 0.420)        // #ff6b6b
    static let go = LinearGradient(colors: [you, char], startPoint: .leading, endPoint: .trailing)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.stage, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.line, lineWidth: 1))
    }
}

struct GoButtonStyle: ButtonStyle {
    var danger = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .foregroundStyle(danger ? Theme.text : Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                if danger { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raise) }
                else { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.go) }
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(danger ? Theme.char.opacity(0.6) : .clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    var tint: Color = Theme.text
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background(Theme.raise, in: Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct Field: View {
    let label: String
    @Binding var text: String
    var secure = false
    var keyboard: UIKeyboardType = .default
    var content: UITextContentType? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(Theme.dim)
            Group {
                if secure { SecureField("", text: $text) } else { TextField("", text: $text) }
            }
            .textContentType(content)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 14).frame(minHeight: 48)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
            .foregroundStyle(Theme.text)
        }
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.dim
    var pulsing = false
    @State private var on = false
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
                .opacity(pulsing ? (on ? 1 : 0.35) : 1)
                .animation(pulsing ? .easeInOut(duration: 0.8).repeatForever() : .default, value: on)
            Text(text).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .onAppear { on = true }
    }
}

extension View {
    func screenBackground() -> some View {
        self.background(Theme.ink.ignoresSafeArea())
    }
}
