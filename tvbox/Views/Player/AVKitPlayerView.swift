import AVKit
import AVFoundation
import SwiftUI

#if os(iOS)
/// SwiftUI bridge for AVPlayerViewController.
/// The AVPlayer is owned by the playback session and is never moved between views.
struct AVKitPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var showsPlaybackControls: Bool = false
    var allowsPictureInPicturePlayback: Bool = false
    var onWillBeginFullScreen: (() -> Void)? = nil
    var onDidEndFullScreen: (() -> Void)? = nil
    var onRestoreUserInterfaceForFullScreenExit: ((@escaping () -> Void) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        configure(controller, coordinator: context.coordinator)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.parent = self
        configure(controller, coordinator: context.coordinator)
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.delegate = nil
        controller.player = nil
    }

    private func configure(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player = player
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

        init(_ parent: AVKitPlayerView) {
            self.parent = parent
        }

        func playerViewControllerWillBeginFullScreenPresentation(_ playerViewController: AVPlayerViewController) {
            parent.onWillBeginFullScreen?()
        }

        func playerViewControllerDidEndFullScreenPresentation(_ playerViewController: AVPlayerViewController) {
            parent.onDidEndFullScreen?()
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForFullScreenExitWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            guard let restore = parent.onRestoreUserInterfaceForFullScreenExit else {
                completionHandler(true)
                return
            }
            restore { completionHandler(true) }
        }
    }
}
#endif
