import SwiftUI

struct LaunchScreenView: View {
    @EnvironmentObject var appVM: AppViewModel
    
    @State private var isIgnited = false
    @State private var liftOff = false
    
    var body: some View {
        ZStack {
            // Background
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()
            
            // Centerpiece Rocket + Text
            VStack(spacing: 30) {
                // Rocket
                ZStack {
                    // Soft, slow-breathing glow
                    Circle()
                        .fill(Color.orange.opacity(isIgnited ? 0.15 : 0))
                        .frame(width: 90, height: 90)
                        .blur(radius: 20)
                        .scaleEffect(isIgnited ? 1.2 : 0.8)
                    
                    Image(systemName: "flame.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.yellow.opacity(0.8), .orange.opacity(0.8), .red.opacity(0.8)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        // Very subtle hover
                        .offset(y: isIgnited ? -3 : 3)
                }
                // Shrink and vanish translation
                .scaleEffect(liftOff ? 0.01 : 1.0)
                .opacity(liftOff ? 0 : 1)
                
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
                }
                .opacity(liftOff ? 0 : 1)
            }
        }
        .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: isIgnited)
        .animation(.easeOut(duration: 0.8), value: liftOff)
        .onAppear {
            isIgnited = true
        }
        // When AppViewModel signals it's ready, trigger the calm liftoff
        .onChange(of: appVM.isAppReady) { ready in
            if ready {
                // Smooth, gentle easeOut for liftoff
                liftOff = true
            }
        }
    }
}

#Preview {
    LaunchScreenView()
        .environmentObject(AppViewModel())
        .frame(width: 800, height: 600)
}
