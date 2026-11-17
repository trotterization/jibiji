import SwiftUI

/// The notebook's cover. The supplied artwork is kept intact on its black backdrop.
struct NotebookCoverView: View {
    let openNotebook: () -> Void

    private let paper = Color(red: 0.93, green: 0.88, blue: 0.79)
    private let dots = [
        Color(red: 0.79, green: 0.60, blue: 0.27),
        Color(red: 0.69, green: 0.42, blue: 0.38),
        Color(red: 0.36, green: 0.52, blue: 0.49),
    ]
    @State private var appeared = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        ForEach(Array(dots.enumerated()), id: \.offset) { index, color in
                            Circle().fill(color)
                                .scaleEffect(appeared ? 1 : 0)
                                .animation(.spring(duration: 0.5, bounce: 0.45).delay(0.1 + Double(index) * 0.09), value: appeared)
                        }
                    }
                    .frame(width: 42, height: 6)
                    .padding(.bottom, 18)
                    Text("A LITTLE SPACE TO LEARN")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(2.5)
                        .foregroundStyle(paper.opacity(0.55))
                        .rises(after: 0.1, distance: 6)

                    Image("JibijiCover")
                        .resizable()
                        .scaledToFit()
                        .frame(width: min(geometry.size.width - 64, geometry.size.height * 0.42, 370))
                        .accessibilityLabel("Jibiji logo: a paper J with gold, rose, and teal dots")
                        .padding(.top, 22)
                        .scaleEffect(appeared ? 1 : 0.94)
                        .opacity(appeared ? 1 : 0)
                        .animation(.smooth(duration: 0.8), value: appeared)

                    Text("jibiji")
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .tracking(-2)
                        .foregroundStyle(paper)
                        .padding(.top, 14)
                        .rises(after: 0.22)
                    Text("笔记")
                        .font(.system(size: 18, weight: .regular, design: .serif))
                        .tracking(8)
                        .foregroundStyle(paper.opacity(0.65))
                        .padding(.top, 3)
                        .rises(after: 0.3)
                    Text("Write naturally. Study what you wrote.")
                        .font(.system(size: 16))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(paper.opacity(0.68))
                        .padding(.top, 24)
                        .padding(.horizontal, 24)
                        .rises(after: 0.38)

                    Button(action: openNotebook) {
                        HStack(spacing: 26) {
                            Text("Open notebook")
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 18)
                        .background(paper, in: Capsule())
                    }
                    .buttonStyle(PressScaleButtonStyle())
                    .accessibilityIdentifier("openNotebook")
                    .padding(.top, 32)
                    .rises(after: 0.46)

                    Text("JIBIJI  /  HANGZHOU, CHINA")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(paper.opacity(0.38))
                        .padding(.top, 42)
                        .rises(after: 0.56, distance: 0)
                }
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { appeared = true }
    }
}
