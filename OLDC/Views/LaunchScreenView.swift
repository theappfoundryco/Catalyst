import SwiftUI

struct LaunchScreenView: View {
    @EnvironmentObject var appVM: AppViewModel
    
    @State private var isIgnited = false
    @State private var liftOff = false
    @State private var isRotating = false
    
    var body: some View {
        ZStack {
            // Background — fills the content region only (below the native titlebar), so the
            // window's real traffic lights stay visible. No .ignoresSafeArea() on top.
            Color(NSColor.windowBackgroundColor)
            
            // Centerpiece Rocket + Text
            VStack(spacing: 30) {
                // Rocket
                ZStack {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(Color.gray.opacity(0.9))
                        .rotationEffect(.degrees(isRotating ? 360 : 0))
                        .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: isRotating)
                        // Very subtle hover
                        .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: isIgnited)
                }
                
                // Typography
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
        // When AppViewModel signals it's ready, trigger the calm liftoff
        .onChange(of: appVM.isAppReady) { ready in
            if ready {
                // Smooth, gentle easeOut for liftoff
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
