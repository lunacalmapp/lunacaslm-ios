import UIKit
import Capacitor
import GoogleSignIn
import FirebaseCore
import FirebaseMessaging

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        // 用来把"苹果原始设备编号"翻译成 Firebase 真正认识的推送令牌（读取项目里已有的 GoogleService-Info.plist，不用额外配置）。
        FirebaseApp.configure()
        // 开启 iOS 原生回弹（Capacitor 默认可能关着）。网页界面是稍后才创建的，所以隔一会儿再设几次。
        for delay in [0.2, 0.8, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.enableNativeBounce()
            }
        }
        return true
    }

    // 打开 iOS 原生回弹：和 Safari、系统设置一样的橡皮筋拉伸 + 惯性减速
    private func enableNativeBounce() {
        guard let root = window?.rootViewController as? CAPBridgeViewController,
              let sv = root.webView?.scrollView else { return }
        sv.bounces = true
        sv.alwaysBounceVertical = true
        sv.alwaysBounceHorizontal = false
        sv.decelerationRate = .normal
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and invalidate graphics rendering callbacks. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the active state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        enableNativeBounce()   // 每次回到前台再确认一次
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    // 苹果推送注册成功/失败后，系统会调用这两个方法。
    // 上次只是把苹果给的"原始设备编号"直接转发出去——这个编号 Firebase 后台不认识，发送时会失败。
    // 这次交给 Firebase Messaging 翻译一遍，拿到真正的推送令牌（格式跟安卓那边一致）再转发给插件。
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
        Messaging.messaging().token(completion: { (token, error) in
            if let error = error {
                NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
            } else if let token = token {
                NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: token)
            }
        })
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
    }

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Called when the app was launched with a url. Feel free to add additional processing here,
        // but if you want the App API to support tracking app url opens, make sure to keep this call

        // Google 登录选完账号后，会通过这个 URL 跳回 App —— 先交给 Google Sign-In SDK 处理，
        // 它能识别的话就直接结束；识别不了（不是 Google 登录相关的链接）再交回给 Capacitor 走原来的逻辑。
        if GIDSignIn.sharedInstance.handle(url) {
            return true
        }
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        // Called when the app was launched with an activity, including Universal Links.
        // Feel free to add additional processing here, but if you want the App API to support
        // tracking app url opens, make sure to keep this call
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }

}

// ───────── 换桌面图标插件（App 里调用 Capacitor.Plugins.LunaAppIcon.setIcon({name})）─────────
// 图标图片放在 Assets.xcassets 里，名字叫 Icon-xxx；name = "luna" 表示恢复默认图标。
// iOS 每次换图标都会弹出系统自带的提示（"您已更改图标"），这个无法去掉，也不能改文字。
@objc(LunaAppIconPlugin)
public class LunaAppIconPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "LunaAppIconPlugin"
    public let jsName = "LunaAppIcon"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "setIcon", returnType: CAPPluginReturnPromise)
    ]

    @objc func setIcon(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? "luna"
        DispatchQueue.main.async {
            guard UIApplication.shared.supportsAlternateIcons else {
                call.reject("alternate icons not supported")
                return
            }
            let target: String? = (name == "luna") ? nil : "Icon-" + name
            UIApplication.shared.setAlternateIconName(target) { error in
                if let error = error {
                    call.reject(error.localizedDescription)
                } else {
                    call.resolve()
                }
            }
        }
    }
}

// 让 Capacitor 在网页加载之前就认识上面这个插件
@objc(MainViewController)
class MainViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(LunaAppIconPlugin())
    }
}
