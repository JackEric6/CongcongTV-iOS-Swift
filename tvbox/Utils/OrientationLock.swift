import Foundation
#if os(iOS)
import UIKit

/// iOS 屏幕方向辅助：配合 `UIWindowScene.requestGeometryUpdate` 在播放器全屏时
/// 强制进入横屏，退出全屏后恢复竖屏。项目已声明支持水平/垂直全部方向。
enum OrientationLock {
    private static let stateLock = NSLock()
    private static var requestGeneration: UInt = 0
    private static var currentOrientation: UIInterfaceOrientationMask = .portrait

    /// AppDelegate 会在 UIKit 回调中读取这个值，因此读写必须保持线程安全。
    static var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentOrientation
    }

    /// 进入播放器全屏时旋转为横屏（Home 右侧）。
    static func landscape() {
        setOrientation(.landscapeRight)
    }

    /// 退出播放器全屏时恢复竖屏。
    static func portrait() {
        setOrientation(.portrait)
    }

    private static func setOrientation(_ orientation: UIInterfaceOrientationMask) {
        let generation: UInt
        stateLock.lock()
        requestGeneration &+= 1
        generation = requestGeneration
        currentOrientation = orientation
        stateLock.unlock()

        // UIKit 的方向 API 必须在主线程调用。把请求串行化到主线程，并让每个
        // 异步回调携带自己的代次，避免旧请求在新请求之后重新触发旋转。
        DispatchQueue.main.async {
            guard isCurrentRequest(generation) else { return }
            applyOrientation(orientation, generation: generation)
        }
    }

    private static func isCurrentRequest(_ generation: UInt) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requestGeneration == generation
    }

    private static func applyOrientation(
        _ orientation: UIInterfaceOrientationMask,
        generation: UInt
    ) {

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            return
        }

        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientation)
        scene.requestGeometryUpdate(preferences) { _ in
            // 用户开启系统方向锁时，Geometry API 可能拒绝请求。用设备方向
            // 作为兼容回退，随后让 UIKit 重新询问当前控制器的方向掩码。
            DispatchQueue.main.async {
                guard isCurrentRequest(generation) else { return }
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
            guard isCurrentRequest(generation) else { return }
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }
}
#endif
