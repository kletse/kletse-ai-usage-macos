import AppKit

func fetchSnapshot(for account: AccountConfig) async throws -> UsageSnapshot {
    switch account.provider {
    case .claude: try await ClaudeProvider(account: account).fetch()
    case .codex: try await CodexProvider(account: account).fetch()
    }
}

// Diagnostic commands must never load account configuration or fetch live data.
// Reject invalid arguments before launching the app, which does access real accounts.
let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty {
    let flags = arguments.filter { $0 != "--sample" && $0 != "--dark" }
    if flags == ["--dump"] {
        DebugRender.dump()
    } else if flags.count == 2,
              ["--render-panel", "--render-menubar"].contains(flags[0]),
              !flags[1].hasPrefix("--") {
        do {
            if flags[0] == "--render-panel" {
                _ = NSApplication.shared
                try DebugRender.panel(to: flags[1], dark: arguments.contains("--dark"))
            } else {
                try DebugRender.menuBar(to: flags[1], dark: arguments.contains("--dark"))
            }
        } catch {
            // Error descriptions can contain private filesystem paths.
            print("Could not write sample image.")
            exit(1)
        }
    } else {
        print("Usage: AIUsage [--dump | --render-panel FILE | --render-menubar FILE] [--dark] [--sample]")
        print("Diagnostic commands always use sample data.")
        exit(2)
    }
    exit(0)
}

AIUsageApp.main()
