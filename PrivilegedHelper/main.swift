import Foundation

// Entry point for the CatalystHelper privileged daemon.
//
// launchd starts this on demand (the first time the app connects to the Mach
// service). It vends the XPC listener and then parks on the run loop. The
// process runs as root, so everything it executes is privileged.
//
// NOTE: This file belongs to the *CatalystHelper* command-line target, NOT the
// main app. See PrivilegedHelper/README.md.

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: CatalystHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

// Keep the daemon alive to service XPC requests.
RunLoop.main.run()
