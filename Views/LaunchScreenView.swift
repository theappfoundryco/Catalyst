import SwiftUI
/// The initial splash screen displayed during app launch, showing an animated ignition sequence.
///
/// ```swift
/// LaunchScreenView()
/// ```
struct LaunchScreenView: View {
    @EnvironmentObject var appVM: AppViewModel
    
    @State private var isIgnited = false
    @State private var liftOff = false
    @State private var isRotating = false
    
    var body: some View {
        ZStack {
            /// Background — fills the content region only (below the native titlebar), so the
            /// window's real traffic lights stay visible. No .ignoresSafeArea() on top.
            ///
            /// **Rationale:** Prevents drawing over the macOS window controls while maintaining a custom immersive gradient background.
            Color(NSColor.windowBackgroundColor)
            
            /// Centerpiece Rocket + Text
            ///
            /// **Rationale:** Groups the hero graphic and branding text into a single cohesive layout block.
            VStack(spacing: 30) {
                /// Rocket
                ///
                /// **Rationale:** Establishes the visual identity of Catalyst during the critical loading phase.
                ZStack {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(Color.gray.opacity(0.9))
                        .rotationEffect(.degrees(isRotating ? 360 : 0))
                        .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: isRotating)
                        /// Very subtle hover
                        ///
                        /// **Rationale:** Micro-animations during launch prevent the UI from feeling frozen while the daemon connects in the background.
                        .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: isIgnited)
                }
                
                /// Typography
                ///
                /// **Rationale:** Separates the logotype styling from the primary graphic to maintain crisp rendering at all scales.
                VStack(spacing: 8) {
                    Text("Catalyst")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary.opacity(0.9))
                        .tracking(2)
                    
                    Text("System Ignition Sequence...")
                        .font(.subheadline.monospaced())
                        .foregroundColor(.secondary)
                        .opacity(isIgnited ? 0.8 : 0.3)
                        .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: isIgnited)
                }
            }
        }
        .opacity(liftOff ? 0 : 1)
        .onAppear {
            isIgnited = true
            isRotating = true
        }
        /// When AppViewModel signals it's ready, trigger the calm liftoff
        ///
        /// **Gotchas:** Triggering liftoff before the AppViewModel is fully primed causes the user to land on a completely empty dashboard.
        .onChange(of: appVM.isAppReady) { ready in
            if ready {
                /// Smooth, gentle easeOut for liftoff
                ///
                /// **Rationale:** An `easeOut` curve feels organic and deliberately masks any sudden jank when the heavy dashboard view hierarchy is mounted.
                withAnimation(.easeOut(duration: 0.8)) {
                    liftOff = true
                }
            }
        }
    }
}

#Preview {
    LaunchScreenView()
        .environmentObject(AppViewModel())
        .frame(width: 800, height: 600)
}
