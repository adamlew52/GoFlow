import SwiftUI
import WebKit

// MARK: - Palette (matching admin dashboard)

extension Color {
    static let flowSurface    = Color(red: 0.067, green: 0.071, blue: 0.039)
    static let flowAmber      = Color(red: 0.788, green: 0.490, blue: 0.047)
    static let flowAmberSoft  = Color(red: 0.941, green: 0.722, blue: 0.251)
    static let flowBorder     = Color(red: 0.788, green: 0.490, blue: 0.047).opacity(0.18)
    static let forestDeep     = Color(red: 0.067, green: 0.122, blue: 0.071)
    static let cream          = Color(red: 0.902, green: 0.929, blue: 0.847)
}

// MARK: - ContentView

struct ContentView: View {
    private let dashboardURL = URL(string: "https://www.sensaro.net/Mobile/SATYR/admin/dashboard.html")!

    @State private var isLoading      = false
    @State private var errorMessage: String? = nil
    @State private var canGoBack      = false
    @State private var canGoForward   = false
    @State private var webViewRef: WKWebView? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.flowSurface.ignoresSafeArea()

            WebView(
                url: dashboardURL,
                isLoading: $isLoading,
                errorMessage: $errorMessage,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                webViewRef: $webViewRef
            )
            .ignoresSafeArea()

            if isLoading {
                LoadingOverlay()
                    .transition(.opacity)
            }

            if let error = errorMessage {
                ErrorOverlay(message: error) {
                    errorMessage = nil
                    webViewRef?.reload()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }


        }
        .statusBar(hidden: false)
        .animation(.easeInOut(duration: 0.2), value: isLoading)
        .animation(.easeInOut(duration: 0.2), value: errorMessage)
    }
}

// MARK: - Bottom Navigation Bar

struct BottomBar: View {
    let canGoBack:    Bool
    let canGoForward: Bool
    let isLoading:    Bool
    let onBack:       () -> Void
    let onForward:    () -> Void
    let onReload:     () -> Void
    let onHome:       () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.flowAmber.opacity(0.35))
                .frame(height: 1)

            HStack(spacing: 0) {
                BarButton(icon: "chevron.backward", enabled: canGoBack,    action: onBack)
                BarButton(icon: "chevron.forward",  enabled: canGoForward, action: onForward)
                Spacer()
                BarButton(icon: "house",            enabled: true,         action: onHome)
                BarButton(
                    icon: isLoading ? "xmark" : "arrow.clockwise",
                    enabled: true,
                    action: onReload
                )
                .rotationEffect(isLoading ? .degrees(360) : .zero)
                .animation(
                    isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                    value: isLoading
                )
            }
            .padding(.horizontal, 8)
            .frame(height: 48)
            .background(Color.flowSurface.overlay(Color.flowAmber.opacity(0.04)))
            .padding(.bottom, safeAreaBottom)
            .background(Color.flowSurface)
        }
    }

    private var safeAreaBottom: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.safeAreaInsets.bottom }
            .first ?? 0
    }
}

struct BarButton: View {
    let icon:    String
    let enabled: Bool
    let action:  () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(enabled ? Color.flowAmber : Color.flowAmber.opacity(0.3))
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
    }
}

// MARK: - Loading Overlay

struct LoadingOverlay: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.flowAmber.opacity(0.15), lineWidth: 3)
                    .frame(width: 56, height: 56)
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [Color.flowAmber, Color.flowAmberSoft, Color.flowAmber.opacity(0)]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(pulse ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: pulse)
            }

            Text("Loading…")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.cream.opacity(0.5))
                .tracking(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.flowSurface.opacity(0.85))
        .onAppear { pulse = true }
    }
}

// MARK: - Error Overlay

struct ErrorOverlay: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(Color(red: 0.659, green: 0.196, blue: 0.196))

            Text("Connection Error")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color.cream)

            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Color.cream.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button(action: onRetry) {
                Text("Retry")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color.flowSurface)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(Color.flowAmber)
                    .clipShape(Capsule())
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.133, green: 0.106, blue: 0.039))
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.flowBorder, lineWidth: 1)
        )
    }
}

#Preview { ContentView() }
