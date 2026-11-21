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
        CAPPluginMethod(name: "setIcon", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setCover", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pauseCover", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getIconInfo", returnType: CAPPluginReturnPromise)
    ]

    // ── 切到后台时遮住画面（防止多任务界面里露出 App 内容）──
    // 系统在 App 变成"非活跃"那一刻截图，所以必须在原生层、这一刻立刻盖一层。
    private var coverOn = false
    private var pausedUntil = Date(timeIntervalSince1970: 0)
    private var coverView: UIView?

    public override func load() {
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResign), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    // 诊断：读出这个包里实际登记了哪些备用图标，以及系统当前状态（换图标失败时显示给用户看）
    private func iconPlistDump() -> String {
        var out = ""
        let fm = FileManager.default
        out += "car=" + (Bundle.main.path(forResource: "Assets", ofType: "car") != nil ? "Y" : "N")
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any] {
            if let p = icons["CFBundlePrimaryIcon"] { out += " P=" + String(describing: p).replacingOccurrences(of: "\n", with: " ") }
            if let a = icons["CFBundleAlternateIcons"] as? [String: Any], let d = a["Icon-drop"] {
                out += " D=" + String(describing: d).replacingOccurrences(of: "\n", with: " ")
            } else { out += " D=missing" }
        } else { out += " CFBundleIcons=missing" }
        if let files = try? fm.contentsOfDirectory(atPath: Bundle.main.bundlePath) {
            let m = files.filter { $0.hasPrefix("Icon-") || $0.hasPrefix("AppIcon") }.sorted()
            out += " files=" + m.prefix(12).joined(separator: ",")
        }
        return out
    }

    @objc func getIconInfo(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            var alts: [String] = []
            var prim = ""
            if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any] {
                if let a = icons["CFBundleAlternateIcons"] as? [String: Any] { alts = Array(a.keys).sorted() }
                if let p = icons["CFBundlePrimaryIcon"] as? [String: Any] { prim = (p["CFBundleIconName"] as? String) ?? "" }
            }
            call.resolve([
                "supports": UIApplication.shared.supportsAlternateIcons,
                "current": UIApplication.shared.alternateIconName ?? "(default)",
                "alts": alts,
                "altCount": alts.count,
                "primary": prim,
                "ios": UIDevice.current.systemVersion,
                 "plist": self.iconPlistDump(),
                "state": UIApplication.shared.applicationState.rawValue
            ])
        }
    }

    @objc func setCover(_ call: CAPPluginCall) {
        coverOn = call.getBool("on") ?? false
        if !coverOn { removeCover() }
        call.resolve()
    }

    // 弹出 Face ID / 指纹时系统也会让 App 短暂"非活跃"，这段时间不要盖（ms=1 表示马上恢复）
    @objc func pauseCover(_ call: CAPPluginCall) {
        let ms = call.getDouble("ms") ?? 0
        pausedUntil = Date().addingTimeInterval(ms / 1000.0)
        call.resolve()
    }

    @objc private func appWillResign() {
        guard coverOn, Date() >= pausedUntil, coverView == nil else { return }
        var win: UIWindow? = (UIApplication.shared.delegate as? AppDelegate)?.window
        if win == nil { win = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) }
        guard let w = win else { return }
        let v = UIView(frame: w.bounds)
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let g = CAGradientLayer()
        g.frame = w.bounds
        g.colors = [UIColor(red: 0.992, green: 0.937, blue: 0.973, alpha: 1).cgColor,
                    UIColor(red: 0.953, green: 0.925, blue: 1.0, alpha: 1).cgColor,
                    UIColor(red: 0.914, green: 0.945, blue: 1.0, alpha: 1).cgColor]
        v.layer.addSublayer(g)
        w.addSubview(v)
        coverView = v
    }

    @objc private func appDidBecomeActive() { removeCover() }

    private func removeCover() {
        DispatchQueue.main.async {
            self.coverView?.removeFromSuperview()
            self.coverView = nil
        }
    }

    // iOS 偶尔会报 "Resource temporarily unavailable"（系统图标服务正忙）。
    // 做法：同一时间只允许一次换图标；先等点击动画/弹层收完（0.4 秒）再换；
    // App 不在前台就等；遇到这个“系统忙”错误就用更长的间隔多试几次（最多约 15 秒）。
    private var iconBusy = false

    @objc func setIcon(_ call: CAPPluginCall) {
        let name = call.getString("name") ?? "luna"
        // "luna" 代表系统主图标（AppIcon），传 nil 即可恢复；其余必须是已登记的备用图标（含 classic）
        let target: String? = (name == "luna") ? nil : "Icon-" + name
        DispatchQueue.main.async {
            guard UIApplication.shared.supportsAlternateIcons else {
                call.reject("alternate icons not supported")
                return
            }
            // 防护：只允许已登记的备用图标；传无效名字会让 iOS 26 的换图标功能卡死到重启手机
            if let t = target {
                var known: [String] = []
                if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
                   let a = icons["CFBundleAlternateIcons"] as? [String: Any] { known = Array(a.keys) }
                if !known.contains(t) {
                    call.reject("icon not registered: \(t)")
                    return
                }
            }
            if UIApplication.shared.alternateIconName == target {
                call.resolve()
                return
            }
            if self.iconBusy {
                call.reject("busy")
                return
            }
            self.iconBusy = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.trySetIcon(target, call: call, attempt: 0, waited: 0)
            }
        }
    }

    private func trySetIcon(_ target: String?, call: CAPPluginCall, attempt: Int, waited: Int) {
        let app = UIApplication.shared
        if app.alternateIconName == target {
            iconBusy = false
            call.resolve()
            return
        }
        if app.applicationState != .active && waited < 12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.trySetIcon(target, call: call, attempt: attempt, waited: waited + 1)
            }
            return
        }
        app.setAlternateIconName(target) { error in
            DispatchQueue.main.async {
                if let error = error {
                    let ns = error as NSError
                    let sysBusy = (ns.domain == NSPOSIXErrorDomain && ns.code == 35)
                        || error.localizedDescription.contains("temporarily unavailable")
                    let maxTry = sysBusy ? 3 : 2
                    if attempt < maxTry {
                        let delay = sysBusy ? (1.0 + Double(attempt) * 0.8) : 0.6
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            self.trySetIcon(target, call: call, attempt: attempt + 1, waited: waited)
                        }
                    } else {
                        self.iconBusy = false
                        call.reject("\(ns.domain) \(ns.code): \(error.localizedDescription)")
                    }
                } else {
                    self.iconBusy = false
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
