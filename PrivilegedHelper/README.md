# Catalyst Privileged Helper — Setup

This scaffolds an **SMAppService** privileged helper so root actions need approval
**once, ever** (no password prompt, even across launches). Until you finish these
steps, the app keeps using the per-launch password cache in `PrivilegesService`.

The Swift/plist files here are NOT yet part of the Xcode project (a new build
target can't be added safely by editing `project.pbxproj` by hand). The two
*app-side* files — `Services/CatalystHelperProtocol.swift` and
`Services/PrivilegedHelperManager.swift` — are already in the app target.

Deployment target is macOS 15.7 and Team ID `6957JGQD3R`, so all APIs below are available.

---

## 1. Add the helper target

1. **File ▸ New ▸ Target… ▸ Command Line Tool** (macOS). Name it **`CatalystHelper`**.
2. Set its **Bundle Identifier** to `com.shivanggulati.catalyst.helper`.
3. Delete the auto-generated `main.swift` in the new target's folder.
4. Add these existing files to the **CatalystHelper** target (File Inspector ▸ Target Membership):
   - `PrivilegedHelper/main.swift`
   - `PrivilegedHelper/CatalystHelperTool.swift`
   - `Services/CatalystHelperProtocol.swift`  ← shared; check **both** app and helper.
5. Set the target's **Info.plist** to `PrivilegedHelper/CatalystHelper-Info.plist`
   (Build Settings ▸ *Info.plist File*), or copy its keys into the generated one.
   It already contains `SMAuthorizedClients` pinned to `com.shivanggulati.catalyst` + your Team ID.

## 2. Embed the launchd plist in the app

1. The daemon plist is `PrivilegedHelper/com.shivanggulati.catalyst.helper.plist`.
2. On the **Catalyst app** target add a **Copy Files** build phase:
   - **Destination:** *Wrapper*, **Subpath:** `Contents/Library/LaunchDaemons`
   - Add `com.shivanggulati.catalyst.helper.plist`.
3. Add another **Copy Files** phase on the app target to embed the helper binary:
   - **Destination:** *Executables* (this lands in `Contents/MacOS/`)
   - Add the **CatalystHelper** product. The plist's `BundleProgram` already points
     at `Contents/MacOS/CatalystHelper`.

## 3. Signing

- Both targets must be **signed by the same Team** (`6957JGQD3R`) with a real
  **Developer ID / Apple Development** identity — ad-hoc signing won't authorize XPC.
- App ▸ Signing & Capabilities: add **App Sandbox = off** is already the case;
  hardened runtime is fine.
- The helper inherits the team automatically once it's in the project.

## 4. Register on launch and turn it on

In `AppViewModel.init()` (or behind a Settings toggle), install the helper and
flip the preference:

```swift
try? PrivilegedHelperManager.shared.install()   // one-time user approval
privileges.preferPrivilegedHelper = true         // route root actions via XPC
```

The first `install()` sends the user to **System Settings ▸ General ▸ Login Items
& Extensions** to approve the background item once. After that,
`runWithPrivileges(...)` runs through the helper with no prompt. If the helper is
ever missing, `PrivilegesService` automatically falls back to the password flow.

To remove it: `try PrivilegedHelperManager.shared.uninstall()`.

---

## Hardening (recommended before shipping)

`SMAuthorizedClients` restricts *who can connect*, but for defense-in-depth also
validate the caller's audit token in `HelperListenerDelegate.listener(_:shouldAcceptNewConnection:)`
before returning `true`:

- Read `newConnection.auditToken`, resolve the peer `SecCode`, and check it against
  a `SecRequirement` of `identifier "com.shivanggulati.catalyst" and anchor apple generic and
  certificate leaf[subject.OU] = "6957JGQD3R"`.
- Reject (return `false`) on any mismatch.

Also keep the helper's command surface narrow — ideally replace the generic
`runShell(_:)` with specific, validated operations (e.g. `removeItems(at:)`,
`chmod(path:mode:)`) so a compromised app can't run arbitrary root commands.

## Bump procedure

When you change the helper, increment `CatalystHelperConstants.helperVersion`
(in `CatalystHelperProtocol.swift`) **and** `CFBundleVersion` in the helper
Info.plist, then compare `installedVersion()` against the bundled value on launch
and re-`install()` when they differ.
