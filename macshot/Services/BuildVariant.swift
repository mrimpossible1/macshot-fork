enum BuildVariant {
    #if OFFLINE
    static let isOffline = true
    static let displayName = "MacShotty Offline"
    #else
    static let isOffline = false
    static let displayName = "MacShotty"
    #endif
}
