import SwiftUI

/// The notebook's cover. The supplied artwork is kept intact on its black backdrop.
struct NotebookCoverView: View {
    let openNotebook: () -> Void

    private let paper = Color(red: 0.93, green: 0.88, blue: 0.79)

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Circle().fill(Color(red: 0.79, green: 0.60, blue: 0.27))
                        Circle().fill(Color(red: 0.69, green: 0.42, blue: 0.38))
                        Circle().fill(Color(red: 0.36, green: 0.52, blue: 0.49))
                    }
                    .frame(width: 42, height: 6)
                    .padding(.bottom, 18)
                    Text("A LITTLE SPACE TO LEARN")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(2.5)
                        .foregroundStyle(paper.opacity(0.55))

                    Image("JibijiCover")
                        .resizable()
                        .scaledToFit()
                        .frame(width: min(geometry.size.width - 64, geometry.size.height * 0.42, 370))
                        .accessibilityLabel("Jibiji logo: a paper J with gold, rose, and teal dots")
                        .padding(.top, 22)

                    Text("jibiji")
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .tracking(-2)
                        .foregroundStyle(paper)
                        .padding(.top, 14)
                    Text("笔记")
                        .font(.system(size: 18, weight: .regular, design: .serif))
                        .tracking(8)
                        .foregroundStyle(paper.opacity(0.65))
                        .padding(.top, 3)
                    Text("Write naturally. Study what you wrote.")
                        .font(.system(size: 16))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(paper.opacity(0.68))
                        .padding(.top, 24)
                        .padding(.horizontal, 24)

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
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("openNotebook")
                    .padding(.top, 32)

                    Text("JIBIJI  /  HANGZHOU, CHINA")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(1.8)
                        .foregroundStyle(paper.opacity(0.38))
                        .padding(.top, 42)
                }
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
