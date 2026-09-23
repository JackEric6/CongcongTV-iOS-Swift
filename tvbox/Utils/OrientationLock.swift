import Foundation
#if os(iOS)
import UIKit

/// iOS 屏幕方向辅助：配合 `UIWindowScene.requestGeometryUpdate` 在播放器全屏时
/// 强制进入横屏，退出全屏后恢复竖屏。项目已声明支持水平/垂直全部方向。
enum OrientationLock {
    /// 进入播放器全屏时旋转为横屏（Home 右侧）。
    static func landscape() {
        setOrientation(.landscapeRight)
    }

    /// 退出播放器全屏时恢复竖屏。
    static func portrait() {
        setOrientation(.portrait)
    }

    private static func setOrientation(_ orientation: UIInterfaceOrientationMask) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first else { return }

        let preferences = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: orientation
        )
        scene.requestGeometryUpdate(preferences) { _ in
            // 旋转被用户锁定或系统拒绝时忽略，保持当前方向即可。
        }
    }
}
#endif
