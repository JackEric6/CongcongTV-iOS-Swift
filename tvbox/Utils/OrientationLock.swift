import Foundation
#if os(iOS)
import UIKit

/// iOS 屏幕方向辅助：配合 `UIWindowScene.requestGeometryUpdate` 在播放器全屏时
/// 强制进入横屏，退出全屏后恢复竖屏。项目已声明支持水平/垂直全部方向。
enum OrientationLock {
    private(set) static var supportedInterfaceOrientations: UIInterfaceOrientationMask = .portrait

    /// 进入播放器全屏时旋转为横屏（Home 右侧）。
    static func landscape() {
        setOrientation(.landscapeRight)
    }

    /// 退出播放器全屏时恢复竖屏。
    static func portrait() {
        setOrientation(.portrait)
    }

    private static func setOrientation(_ orientation: UIInterfaceOrientationMask) {
        supportedInterfaceOrientations = orientation

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return
        }

        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientation)
        scene.requestGeometryUpdate(preferences) { _ in
            // 用户开启系统方向锁时，Geometry API 可能拒绝请求。用设备方向
            // 作为兼容回退，随后让 UIKit 重新询问当前控制器的方向掩码。
            DispatchQueue.main.async {
                let deviceOrientation: UIInterfaceOrientation = orientation == .portrait
                    ? .portrait
                    : .landscapeRight
                UIDevice.current.setValue(deviceOrientation.rawValue, forKey: "orientation")
                UIViewController.attemptRotationToDeviceOrientation()
            }
        }

        // 某些系统版本在请求成功时不会调用 completion，仍需主动触发一次
        // 方向重算；这不会创建第二套全屏呈现流程。
        DispatchQueue.main.async {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}
#endif
