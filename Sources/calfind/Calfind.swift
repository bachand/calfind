import ArgumentParser
import CalfindCLI

// MARK: - Calfind

@main
struct Calfind: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "calfind",
    abstract: "Search CalDAV calendar events.",
    subcommands: [Search.self, Auth.self],
    defaultSubcommand: Search.self,
  )
}
