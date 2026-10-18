import ArgumentParser
import CalfindKit
import Foundation

// MARK: - Search

public struct Search: AsyncParsableCommand {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  public static let configuration = CommandConfiguration(
    commandName: "search",
    abstract: "Search CalDAV calendar events.",
  )

  public mutating func run() async throws {
    let searchQuery: SearchQuery
    let range: ClosedRange<Date>
    let timeZone: TimeZone
    do {
      timeZone = try resolvedTimeZone()
      let calendar = Self.calendar(timeZone: timeZone)
      searchQuery = try SearchQuery(query)
      range = try ClosedRange<Date>(localDateFrom: from, to: to, calendar: calendar)
    } catch let error as CalfindValidationError {
      throw ValidationError(error.description)
    }

    let credentials: CalDavCredentials
    do { credentials = try calDavCredentials() }
    catch let error as CredentialsError { throw ValidationError(error.description) }

    let occurrences = try await CalDavSearch().occurrences(
      credentials: credentials,
      query: searchQuery,
      range: range,
      options: SearchOptions(caseSensitive: caseSensitive),
    )
    guard !occurrences.isEmpty else {
      Output.writeLine("No matching events found.")
      return
    }
    let formatter = CalDavEventFormatter(timeZone: timeZone)
    for occurrence in occurrences {
      Output.writeLine(formatter.line(for: occurrence, showingDuration: showDuration))
      if showLocation, let locationLine = formatter.locationLine(for: occurrence, showingDuration: showDuration) {
        Output.writeLine(locationLine)
      }
    }
  }

  // MARK: Internal

  @Argument(help: ArgumentHelp(stringLiteral: "Text to search for."))
  var query: String
  @Argument(help: ArgumentHelp(stringLiteral: "Start date in YYYY-MM-DD format."))
  var from: String
  @Argument(help: ArgumentHelp(stringLiteral: "End date in YYYY-MM-DD format."))
  var to: String
  @Option(name: .long, help: ArgumentHelp(stringLiteral: "CalDAV calendar collection URL."))
  var caldavURL: String?
  @Option(name: .long, help: ArgumentHelp(stringLiteral: "CalDAV username."))
  var caldavUsername: String?
  @Option(name: .long, help: ArgumentHelp(stringLiteral: "Saved calendar name."))
  var calendar: String?
  @Flag(name: .long, help: ArgumentHelp(stringLiteral: "Read the CalDAV app-specific password from standard input."))
  var passwordStdin = false
  @Flag(name: .long, help: ArgumentHelp(stringLiteral: "Match query text case-sensitively."))
  var caseSensitive = false
  @Flag(name: .long, help: ArgumentHelp(stringLiteral: "Print each event's location below its title."))
  var showLocation = false
  @Flag(name: .long, help: ArgumentHelp(stringLiteral: "Include each event's duration before its title."))
  var showDuration = false
  @Option(
    name: .long,
    help: ArgumentHelp(
      stringLiteral: "IANA time zone used for date arguments and output, such as America/Los_Angeles. Defaults to the system time zone."
    ),
  )
  var timeZone: String?

  // MARK: Private

  private static func calendar(timeZone: TimeZone) -> Calendar {
    var calendar = Calendar.current
    calendar.timeZone = timeZone
    return calendar
  }

  private func resolvedTimeZone() throws -> TimeZone {
    guard let timeZone = timeZone?.trimmingCharacters(in: .whitespacesAndNewlines), !timeZone.isEmpty else {
      return .current
    }
    return try TimeZone(validatingIdentifier: timeZone)
  }

  private func calDavCredentials() throws -> CalDavCredentials {
    let resolver = try CredentialResolver.live(stdinPasswordReader: { try StandardInputPasswordReader.readPassword() })
    return try resolver.resolve(input: SearchCredentialInput(
      url: caldavURL,
      username: caldavUsername,
      passwordFromStdin: passwordStdin,
      calendar: calendar,
    ))
  }
}

// MARK: - CalDavEventFormatter

private struct CalDavEventFormatter {

  // MARK: Lifecycle

  init(timeZone: TimeZone) {
    timedFormatter = DateFormatter()
    timedFormatter.locale = .current
    timedFormatter.timeZone = timeZone
    timedFormatter.dateFormat = "yyyy-MM-dd HH:mm"
  }

  // MARK: Internal

  func line(for occurrence: CalDavOccurrence, showingDuration: Bool) -> String {
    let title = Output.oneLine(occurrence.title ?? "(Untitled)")
    return "\(time(for: occurrence))  \(durationText(for: occurrence, showingDuration: showingDuration))\(title)"
  }

  func locationLine(for occurrence: CalDavOccurrence, showingDuration: Bool) -> String? {
    guard let location = occurrence.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty else {
      return nil
    }
    let prefix = "\(time(for: occurrence))  \(durationText(for: occurrence, showingDuration: showingDuration))"
    return String(repeating: " ", count: prefix.count) + Output.oneLine(location)
  }

  // MARK: Private

  private let timedFormatter: DateFormatter

  private static func formatDuration(_ duration: TimeInterval) -> String? {
    guard duration.isFinite, duration >= 0, duration < Double(Int.max) else {
      return nil
    }

    var remaining = Int(duration.rounded())
    let units: [(seconds: Int, symbol: String)] = [
      (24 * 60 * 60, "d"),
      (60 * 60, "h"),
      (60, "m"),
      (1, "s"),
    ]
    var parts = [String]()
    for unit in units {
      let value = remaining / unit.seconds
      if value > 0 {
        parts.append("\(value)\(unit.symbol)")
        remaining %= unit.seconds
      }
    }
    return parts.isEmpty ? "0s" : parts.joined(separator: " ")
  }

  private func time(for occurrence: CalDavOccurrence) -> String {
    timedFormatter.string(from: occurrence.startDate)
  }

  private func durationText(for occurrence: CalDavOccurrence, showingDuration: Bool) -> String {
    guard showingDuration, let duration = occurrence.duration, let formatted = Self.formatDuration(duration) else {
      return ""
    }
    return "(\(formatted))  "
  }

}
