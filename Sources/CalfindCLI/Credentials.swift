import ArgumentParser
import CalfindKit
import Darwin
import Foundation

// MARK: - Auth

public struct Auth: ParsableCommand {
  public init() { }

  public static let configuration = CommandConfiguration(
    commandName: "auth",
    abstract: "Save or discover CalDAV credentials.",
    subcommands: [AuthICloud.self, AuthLogin.self, AuthList.self, AuthDiscover.self, AuthLogout.self],
  )

}

// MARK: - AuthICloud

struct AuthICloud: AsyncParsableCommand {

  // MARK: Internal

  static let configuration = CommandConfiguration(
    commandName: "icloud",
    abstract: "Discover and save an iCloud calendar in one step.",
  )

  @Option(name: .long, help: ArgumentHelp(stringLiteral: "Saved calendar name. Defaults to the discovered calendar name."))
  var calendar: String?

  @Option(name: .long, help: ArgumentHelp(stringLiteral: "Apple Account email."))
  var username: String?

  @Flag(name: .long, help: ArgumentHelp(stringLiteral: "Read the Apple Account app-specific password from standard input."))
  var passwordStdin = false

  mutating func run() async throws {
    do {
      let manager = try AuthManager.live()
      let discoveryUsername = try resolvedUsername()
      let discoveryPassword = try resolvedPassword()
      let collections = try await CalDavClient().discoverCalendarCollections(
        serverURL: Self.server,
        username: discoveryUsername,
        appSpecificPassword: discoveryPassword,
      )

      guard !collections.isEmpty else {
        throw CalDavError.discoveryFailed("No iCloud calendar collections were found.")
      }

      let collection = try selectedCollection(from: collections)
      let savedName = try resolvedCalendarName(for: collection)
      try manager.save(
        calendar: savedName,
        url: collection.url,
        username: discoveryUsername,
        password: discoveryPassword,
      )
      Output.writeLine("Saved iCloud calendar '\(Output.oneLine(savedName))'.")
    } catch let error as CalDavError {
      throw ValidationError(error.description)
    } catch let error as CredentialsError {
      throw ValidationError(error.description)
    }
  }

  // MARK: Private

  private static let server = "https://caldav.icloud.com"

  private func resolvedUsername() throws -> String {
    if let username = normalizedNonEmpty(username) {
      return username
    }
    return try Prompt.readRequiredLine(
      prompt: "Apple Account email",
      missing: .missingUsername,
    )
  }

  private func resolvedPassword() throws -> String {
    if passwordStdin {
      return try StandardInputPasswordReader.readPassword()
    }
    Output.writeLine(
      "Need an Apple Account app-specific password? Create one at https://account.apple.com/. "
        + "Select Sign-In and Security, then App-Specific Passwords."
    )
    return try Prompt.readSecureRequiredLine(
      prompt: "Apple Account app-specific password"
    )
  }

  private func selectedCollection(from collections: [CalDavCalendarCollection]) throws -> CalDavCalendarCollection {
    if
      let requestedName = normalizedNonEmpty(calendar),
      let matchingCollection = collections.first(where: { collection in
        collection.displayName?.localizedCaseInsensitiveCompare(requestedName) == .orderedSame
      })
    {
      return matchingCollection
    }

    guard collections.count > 1 else {
      return collections[0]
    }

    Output.writeLine("Discovered iCloud calendars:")
    for (index, collection) in collections.enumerated() {
      let name = collection.displayName.map(Output.oneLine) ?? collection.url
      Output.writeLine("  \(index + 1). \(name)")
    }
    let selection = try Prompt.readRequiredLine(
      prompt: "Choose a calendar (1-\(collections.count))",
      missing: .invalidCalendarName,
    )
    guard let index = Int(selection), collections.indices.contains(index - 1) else {
      throw CalDavError.discoveryFailed("Choose a calendar number from 1 to \(collections.count).")
    }
    return collections[index - 1]
  }

  private func resolvedCalendarName(for collection: CalDavCalendarCollection) throws -> String {
    if let calendar = normalizedNonEmpty(calendar) {
      return calendar
    }
    if let displayName = collection.displayName, !displayName.isEmpty {
      return displayName
    }
    return try Prompt.readRequiredLine(prompt: "Saved calendar name", missing: .invalidCalendarName)
  }

  private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

}

// MARK: - AuthDiscover

struct AuthDiscover: AsyncParsableCommand {

  // MARK: Internal

  static let configuration = CommandConfiguration(
    commandName: "discover",
    abstract: "Discover CalDAV calendar collection URLs.",
  )

  @Option(name: .long, help: ArgumentHelp(stringLiteral: "CalDAV server URL to start discovery from."))
  var server = "https://caldav.icloud.com"

  @Option(name: .long, help: ArgumentHelp(stringLiteral: "CalDAV username."))
  var username: String?

  @Flag(name: .long, help: ArgumentHelp(stringLiteral: "Read the CalDAV app-specific password from standard input."))
  var passwordStdin = false

  @Flag(name: .long, help: ArgumentHelp(stringLiteral: "Try discovery without credentials."))
  var noAuth = false

  mutating func run() async throws {
    do {
      let discoveryUsername = try resolvedUsername()
      let discoveryPassword = try resolvedPassword()
      let collections = try await CalDavClient().discoverCalendarCollections(
        serverURL: server,
        username: discoveryUsername,
        appSpecificPassword: discoveryPassword,
      )

      guard !collections.isEmpty else {
        Output.writeLine("No CalDAV calendar collections were found.")
        return
      }

      for collection in collections {
        if let displayName = collection.displayName, !displayName.isEmpty {
          Output.writeLine("\(Output.oneLine(displayName))\n  \(Output.oneLine(collection.url))")
        } else {
          Output.writeLine(Output.oneLine(collection.url))
        }
      }
    } catch let error as CalDavError {
      throw ValidationError(error.description)
    } catch let error as CredentialsError {
      throw ValidationError(error.description)
    }
  }

  // MARK: Private

  private var usernamePrompt: String {
    isICloudServer ? "CalDAV username (Apple Account email)" : "CalDAV username"
  }

  private var passwordPrompt: String {
    isICloudServer
      ? "CalDAV app-specific password (not your normal password)"
      : "CalDAV app-specific password"
  }

  private var isICloudServer: Bool {
    URL(string: server)?.host?.lowercased() == "caldav.icloud.com"
  }

  private func resolvedUsername() throws -> String? {
    if noAuth {
      return nil
    }
    if let username = normalizedNonEmpty(username) {
      return username
    }
    return try Prompt.readRequiredLine(prompt: usernamePrompt, missing: .missingUsername)
  }

  private func resolvedPassword() throws -> String? {
    if noAuth {
      return nil
    }
    if passwordStdin {
      return try StandardInputPasswordReader.readPassword()
    }
    if isICloudServer {
      Output.writeLine(
        "Need an Apple Account app-specific password? Create one at https://account.apple.com/. "
          + "Select Sign-In and Security, then App-Specific Passwords."
      )
    }
    return try Prompt.readSecureRequiredLine(prompt: passwordPrompt)
  }

  private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

}

// MARK: - AuthLogin

struct AuthLogin: ParsableCommand {

  // MARK: Internal

  static let configuration = CommandConfiguration(
    commandName: "login",
    abstract: "Save a named CalDAV calendar.",
  )

  @Option(name: .long, help: ArgumentHelp(stringLiteral: "Short saved calendar name, such as personal or work."))
  var calendar: String?

  @Option(name: .long, help: ArgumentHelp(stringLiteral: "CalDAV calendar collection URL."))
  var caldavURL: String?

  @Option(name: .long, help: ArgumentHelp(stringLiteral: "CalDAV username."))
  var username: String?

  @Flag(name: .long, help: ArgumentHelp(stringLiteral: "Read the CalDAV app-specific password from standard input."))
  var passwordStdin = false

  mutating func run() throws {
    let manager = try AuthManager.live()
    let savedCalendar = try savedCalendarIfPresent(manager: manager)

    do {
      let savedCalendarName = try requiredCalendarName()
      let savedName = try manager.save(
        calendar: savedCalendarName,
        url: try resolvedURL(existingCalendar: savedCalendar),
        username: try resolvedUsername(existingCalendar: savedCalendar),
        password: try resolvedPassword(),
      )

      Output.writeLine("Saved calendar '\(Output.oneLine(savedName))'.")
    } catch let error as CredentialsError {
      throw ValidationError(error.description)
    }
  }

  // MARK: Private

  private func savedCalendarIfPresent(manager: AuthManager) throws -> SavedCalendar? {
    guard let calendar else {
      return nil
    }
    return try manager.savedCalendar(named: calendarName(from: calendar))
  }

  private func requiredCalendarName() throws -> String {
    if let calendar = normalizedNonEmpty(calendar) {
      return calendar
    }
    return try Prompt.readRequiredLine(prompt: "Calendar name", missing: .invalidCalendarName)
  }

  private func resolvedURL(existingCalendar: SavedCalendar?) throws -> String {
    if let caldavURL = normalizedNonEmpty(caldavURL) {
      return caldavURL
    }
    return try Prompt.readRequiredLine(
      prompt: "CalDAV URL",
      defaultValue: existingCalendar?.url,
      missing: .missingURL,
    )
  }

  private func resolvedUsername(existingCalendar: SavedCalendar?) throws -> String {
    if let username = normalizedNonEmpty(username) {
      return username
    }
    return try Prompt.readRequiredLine(
      prompt: "CalDAV username (Apple Account email for iCloud)",
      defaultValue: existingCalendar?.username,
      missing: .missingUsername,
    )
  }

  private func resolvedPassword() throws -> String {
    if passwordStdin {
      return try StandardInputPasswordReader.readPassword()
    }
    return try Prompt
      .readSecureRequiredLine(prompt: "CalDAV app-specific password (Apple Account app-specific password for iCloud)")
  }

  private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

}

// MARK: - AuthList

struct AuthList: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List saved calendars.",
  )

  mutating func run() throws {
    let manager = try AuthManager.live()

    do {
      let calendars = try manager.list()
      guard !calendars.isEmpty else {
        Output.writeLine("No saved calendars.")
        return
      }

      for calendar in calendars {
        Output.writeLine("\(Output.oneLine(calendar.name))\n  \(Output.oneLine(calendar.url))")
      }
    } catch let error as CredentialsError {
      throw ValidationError(error.description)
    }
  }
}

// MARK: - AuthLogout

struct AuthLogout: ParsableCommand {

  // MARK: Internal

  static let configuration = CommandConfiguration(
    commandName: "logout",
    abstract: "Remove a saved calendar.",
  )

  @Option(name: .long, help: ArgumentHelp(stringLiteral: "Saved calendar name to remove."))
  var calendar: String?

  @Flag(name: .long, help: ArgumentHelp(stringLiteral: "Remove all saved calendars and their credentials."))
  var all = false

  mutating func run() throws {
    let manager = try AuthManager.live()

    do {
      if all {
        guard calendar == nil else {
          throw ValidationError("Use either --calendar or --all, not both.")
        }
        try manager.logoutAll()
        Output.writeLine("Removed all saved calendars and credentials.")
        return
      }
      let calendar = try requiredCalendarName()
      try manager.logout(calendar: calendar)
      Output.writeLine("Removed saved calendar '\(Output.oneLine(calendar))'.")
    } catch let error as CredentialsError {
      throw ValidationError(error.description)
    }
  }

  // MARK: Private

  private func requiredCalendarName() throws -> String {
    if let calendar = normalizedNonEmpty(calendar) {
      return calendar
    }
    return try Prompt.readRequiredLine(prompt: "Calendar name", missing: .invalidCalendarName)
  }

  private func normalizedNonEmpty(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }
}

// MARK: - Prompt

enum Prompt {
  static func readRequiredLine(prompt: String, defaultValue: String? = nil, missing: CredentialsError) throws -> String {
    guard isatty(STDIN_FILENO) == 1 else {
      throw CredentialsError.interactivePromptRequiresTerminal
    }

    let promptSuffix = defaultValue.map { " [\($0)]" } ?? ""
    Output.write("\(prompt)\(promptSuffix): ", to: .standardError)
    guard let line = Swift.readLine(strippingNewline: true) else {
      throw CredentialsError.promptCancelled(prompt)
    }

    if line.isEmpty, let defaultValue {
      return defaultValue
    }

    let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      throw missing
    }
    return normalized
  }

  static func readSecureRequiredLine(prompt: String) throws -> String {
    guard isatty(STDIN_FILENO) == 1 else {
      throw CredentialsError.interactivePromptRequiresTerminal
    }

    Output.write("\(prompt): ", to: .standardError)

    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      throw CredentialsError.interactivePromptRequiresTerminal
    }

    var hidden = original
    hidden.c_lflag &= ~tcflag_t(ECHO)
    guard tcsetattr(STDIN_FILENO, TCSANOW, &hidden) == 0 else {
      throw CredentialsError.interactivePromptRequiresTerminal
    }

    defer {
      var restored = original
      tcsetattr(STDIN_FILENO, TCSANOW, &restored)
      Output.writeLine("", to: .standardError)
    }

    guard let line = Swift.readLine(strippingNewline: true) else {
      throw CredentialsError.promptCancelled(prompt)
    }
    guard !line.isEmpty else {
      throw CredentialsError.missingPassword
    }
    return line
  }
}

// MARK: - StandardInputPasswordReader

public enum StandardInputPasswordReader {
  public static func readPassword() throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else {
      throw CredentialsError.missingPasswordFromStdin
    }
    guard let value = String(data: data, encoding: .utf8) else {
      throw CredentialsError.stdinPasswordNotUTF8
    }

    let password = value.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
    guard !password.isEmpty else {
      throw CredentialsError.missingPasswordFromStdin
    }
    return password
  }
}

// MARK: - Output

public enum Output {
  public enum Stream {
    case standardOutput
    case standardError

    fileprivate var fileHandle: FileHandle {
      switch self {
      case .standardOutput:
        FileHandle.standardOutput
      case .standardError:
        FileHandle.standardError
      }
    }
  }

  public static func write(_ value: String, to stream: Stream = .standardOutput) {
    guard let data = value.data(using: .utf8) else {
      return
    }
    stream.fileHandle.write(data)
  }

  public static func writeLine(_ line: String, to stream: Stream = .standardOutput) {
    write("\(line)\n", to: stream)
  }

  public static func oneLine(_ value: String) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
      let isControlCharacter = scalar.value < 0x20
        || scalar.value == 0x7F
        || (0x80...0x9F).contains(scalar.value)
      return isControlCharacter ? UnicodeScalar(0x20)! : scalar
    }))
  }
}
