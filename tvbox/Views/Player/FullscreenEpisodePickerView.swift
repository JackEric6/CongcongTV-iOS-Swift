import SwiftUI

/// 全屏状态下的轻量选集浮层。
/// 使用独立呈现，不触发播放器的退出全屏逻辑。
struct FullscreenEpisodePickerView: View {
    let episodes: [VodInfo.Episode]
    let selectedIndex: Int
    let onDismiss: () -> Void
    let onSelect: (Int) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                HStack {
                    Text("选集")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.75))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                ScrollView {
                    EpisodeListView(
                        episodes: episodes,
                        selectedIndex: selectedIndex,
                        onSelect: onSelect
                    )
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: 380, maxHeight: 430)
            .background(Color.black.opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            .padding(.horizontal, 20)
        }
    }
}
