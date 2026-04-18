import Foundation

enum PrivacyPreferences {
    private static let uploadsKey = "memx.privacy.allowAnthropicUploads"

    static var allowAnthropicUploads: Bool {
        get { UserDefaults.standard.bool(forKey: uploadsKey) }
        set { UserDefaults.standard.set(newValue, forKey: uploadsKey) }
    }
}
