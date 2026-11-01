#if os(iOS)
import LocalAuthentication
import SwiftUI

/// App-wide Face ID / Touch ID gate. While locked, a cover window sits above
/// every scene, including sheets and full-screen sessions, so saved passwords
/// and remote desktops stay hidden in the app switcher.
@MainActor
@Observable
public final class AppLock {
    public private(set) var isLocked = false
    public private(set) var isAuthenticationRequired = false
    public private(set) var isAuthenticating = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private var coverWindows: [UIWindow] = []
    @ObservationIgnored private var prepared = false

    public init() {}

    public static var isAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
    }

    public static var biometryName: String {
        switch biometryType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        default: NSLocalizedString("Biometrics", comment: "Biometry fallback name")
        }
    }

    public static var unlockTitle: String {
        switch biometryType {
        case .faceID: NSLocalizedString("Unlock with Face ID", comment: "App lock button")
        case .touchID: NSLocalizedString("Unlock with Touch ID", comment: "App lock button")
        default: NSLocalizedString("Unlock", comment: "App lock button")
        }
    }

    public static var settingTitle: String {
        switch biometryType {
        case .faceID: NSLocalizedString("Require Face ID", comment: "App lock setting")
        case .touchID: NSLocalizedString("Require Touch ID", comment: "App lock setting")
        default: NSLocalizedString("Require Biometrics", comment: "App lock setting")
        }
    }

    public static var biometrySystemImage: String {
        switch biometryType {
        case .faceID: "faceid"
        case .touchID: "touchid"
        default: "lock.open"
        }
    }

    private static var biometryType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        return context.biometryType
    }

    /// Locks once per launch when the preference is on. Later windows of the
    /// same launch do not prompt again.
    public func prepareAtLaunch(enabled: Bool) {
        guard !prepared else { return }
        prepared = true
        guard enabled, lock() else { return }
        Task { await unlock() }
    }

    @discardableResult
    public func lock() -> Bool {
        guard !isLocked else {
            isAuthenticationRequired = true
            return true
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        isAuthenticationRequired = true
        coverForPrivacy()
        return true
    }

    /// Hides the app behind the lock cover without asking for authentication
    /// yet. Used when the scene merely becomes inactive (Control Center, a
    /// system alert); only a real background transition requires unlocking.
    public func coverForPrivacy() {
        guard !isLocked else { return }
        isLocked = true
        errorMessage = nil
        showCovers()
    }

    /// Marks the cover as requiring authentication; the next active transition
    /// presents Face ID / Touch ID.
    public func requireAuthentication() {
        coverForPrivacy()
        isAuthenticationRequired = true
    }

    /// Dismisses a privacy-only cover when the scene returns without having
    /// been backgrounded.
    public func dismissPrivacyCover() {
        guard isLocked, !isAuthenticationRequired else { return }
        isLocked = false
        hideCovers()
    }

    public func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = NSLocalizedString("Cancel", comment: "App lock cancel")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            errorMessage = NSLocalizedString(
                "Authentication is unavailable.",
                comment: "App lock error"
            )
            return
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: NSLocalizedString(
                    "Unlock to access your saved connections.",
                    comment: "App lock reason"
                )
            )
            if success {
                isLocked = false
                isAuthenticationRequired = false
                errorMessage = nil
                hideCovers()
            }
        } catch {
            errorMessage = NSLocalizedString(
                "Authentication failed. Try again.",
                comment: "App lock error"
            )
        }
    }

    private func showCovers() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  !coverWindows.contains(where: { $0.windowScene === windowScene })
            else { continue }
            let window = UIWindow(windowScene: windowScene)
            window.windowLevel = .alert + 1
            window.backgroundColor = .systemBackground
            window.rootViewController = UIHostingController(
                rootView: AppLockView().environment(self)
            )
            window.isHidden = false
            coverWindows.append(window)
        }
    }

    private func hideCovers() {
        for window in coverWindows {
            window.isHidden = true
            window.rootViewController = nil
        }
        coverWindows.removeAll()
    }
}

struct AppLockView: View {
    @Environment(AppLock.self) private var lock
    @State private var requestedUnlock = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("OpenScreens is Locked")
                    .font(.title2.weight(.semibold))

                Text("Unlock to access your saved connections.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if lock.isAuthenticationRequired {
                    Button {
                        Task { await lock.unlock() }
                    } label: {
                        Label(AppLock.unlockTitle, systemImage: AppLock.biometrySystemImage)
                            .frame(maxWidth: 280)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(lock.isAuthenticating)

                    if let message = lock.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .multilineTextAlignment(.center)
            .padding(32)
        }
        .task {
            guard lock.isAuthenticationRequired, !requestedUnlock else { return }
            requestedUnlock = true
            await lock.unlock()
        }
    }
}

private struct AppLockLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppLock.self) private var lock
    @Environment(SettingsStore.self) private var settings

    func body(content: Content) -> some View {
        content
            .task {
                lock.prepareAtLaunch(enabled: settings.settings.requireBiometrics)
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .inactive:
                    if settings.settings.requireBiometrics {
                        lock.coverForPrivacy()
                    }
                case .background:
                    if settings.settings.requireBiometrics {
                        lock.requireAuthentication()
                    }
                case .active:
                    if lock.isLocked {
                        if lock.isAuthenticationRequired {
                            Task { await lock.unlock() }
                        } else {
                            lock.dismissPrivacyCover()
                        }
                    }
                default:
                    break
                }
            }
    }
}

public extension View {
    /// Locks the app when the scene leaves the foreground and unlocks it when
    /// the scene returns, according to the biometric lock preference.
    func appLockLifecycle() -> some View {
        modifier(AppLockLifecycle())
    }
}
#endif
