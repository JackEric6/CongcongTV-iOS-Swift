import AVKit
import AVFoundation
import SwiftUI

#if os(iOS)
import UIKit

/// SwiftUI bridge for AVPlayerViewController.
/// The AVPlayer is owned by the playback session and is never moved between views.
struct AVKitPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var sessionController: SystemPlayerSessionController? = nil
    var showsPlaybackControls: Bool = true
    var allowsPictureInPicturePlayback: Bool = false
    var onWillBeginFullScreen: (() -> Void)? = nil
    var onDidEndFullScreen: (() -> Void)? = nil
    var onRestoreUserInterfaceForFullScreenExit: ((@escaping () -> Void) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        context.coordinator.sessionController = sessionController
        configure(controller, coordinator: context.coordinator)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sessionController = sessionController
        configure(controller, coordinator: context.coordinator)
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.delegate = nil
        controller.player = nil
    }

    private func configure(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player = player
        // 使用 AVKit 自带控制条。它拥有系统维护的全屏按钮和退出手势，
        // 避免 SwiftUI 自定义按钮与播放器全屏转场互相竞争。
        controller.showsPlaybackControls = showsPlaybackControls
        controller.allowsPictureInPicturePlayback = allowsPictureInPicturePlayback
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.updatesNowPlayingInfoCenter = false
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.delegate = coordinator
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var parent: AVKitPlayerView
        weak var sessionController: SystemPlayerSessionController?

        init(_ parent: AVKitPlayerView) {
            self.parent = parent
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            let sessionController = sessionController
            Task { @MainActor in
                sessionController?.setFullScreenState(true)
            }
            parent.onWillBeginFullScreen?()
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            let sessionController = sessionController
            Task { @MainActor in
                sessionController?.setFullScreenState(false)
            }
            parent.onDidEndFullScreen?()
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForFullScreenExitWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            if let restore = parent.onRestoreUserInterfaceForFullScreenExit {
                restore { completionHandler(true) }
            } else {
                // 没有第二套 SwiftUI 全屏容器需要恢复，AVKit 自己即可完成退出。
                completionHandler(true)
            }
        }
    }
}
#endif
