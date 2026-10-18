import Foundation
import Security

// MARK: - AuthManager

public struct AuthManager {

  // MARK: Lifecycle

  public init(configStore: SavedCredentialsStore, passwordStore: any PasswordStore) {
    self.configStore = configStore
    self.passwordStore = passwordStore
  }

  // MARK: Public

  public let configStore: SavedCredentialsStore
  public let passwordStore: any PasswordStore

  public static func live() throws -> Self {
    Self(configStore: try SavedCredentialsStore.live(), passwordStore: KeychainPasswordStore())
  }

  public func savedCalendar(named requestedCalendar: String) throws -> SavedCalendar? {
    let config = try configStore.load()
    return config.calendars[try calendarName(from: requestedCalendar)]
  }

  public func load() throws -> SavedCalendarsConfig {
    try configStore.load()
  }

  @discardableResult
  public func save(calendar requestedCalendar: String, url: String, username: String, password: String) throws -> String {
    let calendar = try calendarName(from: requestedCalendar)
    let normalizedURL = try validatedURLString(from: url)
    let normalizedUsername = try requiredText(username, missing: .missingUsername)
    guard !password.isEmpty else {
      throw CredentialsError.missingPassword
    }

    var config = try configStore.load()
    let previousPassword = try passwordStore.password(for: calendar)
    try passwordStore.save(password: password, for: calendar)
    config.upsertCalendar(named: calendar, url: normalizedURL, username: normalizedUsername)
    do {
      try configStore.save(config)
    } catch {
      try? restorePassword(previousPassword, for: calendar)
      throw error
    }
    return calendar
  }

  public func list() throws -> [NamedSavedCalendar] {
    let config = try configStore.load()
    return config.calendars.keys.sorted().compactMap { name in
      guard let calendar = config.calendars[name] else {
        return nil
      }
      return NamedSavedCalendar(name: name, url: calendar.url, username: calendar.username)
    }
  }

  public func logout(calendar requestedCalendar: String) throws {
    let calendar = try calendarName(from: requestedCalendar)
    var config = try configStore.load()
    guard config.calendars[calendar] != nil else {
      throw CredentialsError.unknownCalendar(calendar)
    }

    let previousPassword = try passwordStore.password(for: calendar)
    try passwordStore.deletePassword(for: calendar)
    config.removeCalendar(named: calendar)
    do {
      try configStore.save(config)
    } catch {
      try? restorePassword(previousPassword, for: calendar)
      throw error
    }
  }

  public func logoutAll() throws {
    let config = try configStore.load()
    let calendars = config.calendars.keys.sorted()
    let passwords = try calendars.map { calendar in
      (calendar, try passwordStore.password(for: calendar))
    }
    var deletedCalendars = [String]()

    do {
      for calendar in calendars {
        try passwordStore.deletePassword(for: calendar)
        deletedCalendars.append(calendar)
      }
      try configStore.clear()
    } catch {
      for calendar in deletedCalendars {
        let password = passwords.first(where: { $0.0 == calendar })?.1
        try? restorePassword(password, for: calendar)
      }
      throw error
    }
  }

  // MARK: Private

  private func restorePassword(_ password: String?, for calendar: String) throws {
    if let password {
      try passwordStore.save(password: password, for: calendar)
    } else {
      try passwordStore.deletePassword(for: calendar)
    }
  }
}

// MARK: - CredentialResolver

public struct CredentialResolver {

  // MARK: Lifecycle

  init(
    configStore: SavedCredentialsStore,
    passwordStore: any PasswordStore,
    stdinPasswordReader: @escaping () throws -> String,
  ) {
    self.configStore = configStore
    self.passwordStore = passwordStore
    self.stdinPasswordReader = stdinPasswordReader
  }

  // MARK: Public

  public static func live(
    stdinPasswordReader: @escaping () throws -> String
  ) throws -> Self {
    Self(
      configStore: try SavedCredentialsStore.live(),
      passwordStore: KeychainPasswordStore(),
      stdinPasswordReader: stdinPasswordReader,
    )
  }

  public func resolve(input: SearchCredentialInput) throws -> CalDavCredentials {
    let config = try configStore.load()
    let selectedCalendar = try resolvedSavedCalendar(from: input, config: config)
    let url = try resolvedURL(from: input, savedCalendar: selectedCalendar)
    let username = try resolvedUsername(from: input, savedCalendar: selectedCalendar)
    let password = try resolvedPassword(
      from: input,
      selectedCalendarName: selectedCalendar == nil
        ? nil
        : input.calendar.flatMap { try? calendarName(from: $0) },
    )

    return CalDavCredentials(url: url, username: username, password: password)
  }

  // MARK: Internal

  let configStore: SavedCredentialsStore
  let passwordStore: any PasswordStore
  let stdinPasswordReader: () throws -> String

  // MARK: Private

  private func resolvedSavedCalendar(
    from input: SearchCredentialInput,
    config: SavedCalendarsConfig,
  ) throws -> SavedCalendar? {
    guard normalizedText(input.url) == nil else {
      return nil
    }

    if
      normalizedText(input.username) == nil,
      input.calendar == nil,
      input.passwordFromStdin == false
    {
      if !config.calendars.isEmpty {
        throw CredentialsError.missingCalendar
      }
      return nil
    }

    guard let requestedCalendar = try input.calendar.flatMap({ try calendarName(from: $0) }) else {
      return nil
    }
    return config.calendars[requestedCalendar]
  }

  private func resolvedURL(
    from input: SearchCredentialInput,
    savedCalendar: SavedCalendar?,
  ) throws -> String {
    if let explicitURL = normalizedText(input.url) {
      return try validatedURLString(from: explicitURL)
    }
    guard let savedCalendar else {
      throw CredentialsError.missingURL
    }
    return try validatedURLString(from: savedCalendar.url)
  }

  private func resolvedUsername(
    from input: SearchCredentialInput,
    savedCalendar: SavedCalendar?,
  ) throws -> String {
    if let explicitUsername = normalizedText(input.username) {
      return explicitUsername
    }
    guard let savedCalendar else {
      throw CredentialsError.missingUsername
    }
    return savedCalendar.username
  }

  private func resolvedPassword(
    from input: SearchCredentialInput,
    selectedCalendarName: String?,
  ) throws -> String {
    if input.passwordFromStdin {
      let password = try stdinPasswordReader()
      return try requiredText(password, missing: .missingPasswordFromStdin)
    }

    guard let selectedCalendarName else {
      throw CredentialsError.missingPassword
    }

    guard let savedPassword = try passwordStore.password(for: selectedCalendarName) else {
      throw CredentialsError.missingPassword
    }
    return savedPassword
  }
}

// MARK: - SearchCredentialInput

public struct SearchCredentialInput: Equatable {

  // MARK: Lifecycle

  public init(
    url: String? = nil,
    username: String? = nil,
    passwordFromStdin: Bool = false,
    calendar: String? = nil,
  ) {
    self.url = url
    self.username = username
    self.passwordFromStdin = passwordFromStdin
    self.calendar = calendar
  }

  // MARK: Public

  public let url: String?
  public let username: String?
  public let passwordFromStdin: Bool
  public let calendar: String?
}

// MARK: - CalDavCredentials

public struct CalDavCredentials: Equatable {
  public let url: String
  public let username: String
  public let password: String
}

// MARK: - SavedCalendar

public struct SavedCalendar: Codable, Equatable {
  public let url: String
  public let username: String
}

// MARK: - SavedCalendarsConfig

public struct SavedCalendarsConfig: Codable, Equatable {

  // MARK: Lifecycle

  public init(calendars: [String: SavedCalendar] = [:]) {
    self.calendars = calendars
  }

  // MARK: Public

  public private(set) var calendars: [String: SavedCalendar]

  public mutating func upsertCalendar(named name: String, url: String, username: String) {
    calendars[name] = SavedCalendar(url: url, username: username)
  }

  public mutating func removeCalendar(named name: String) {
    calendars.removeValue(forKey: name)
  }
}

// MARK: - NamedSavedCalendar

public struct NamedSavedCalendar: Equatable {
  public let name: String
  public let url: String
  public let username: String
}

// MARK: - SavedCredentialsStore

public struct SavedCredentialsStore {

  // MARK: Lifecycle

  public init(configURL: URL, fileManager: FileManager = .default) {
    self.configURL = configURL
    self.fileManager = fileManager
  }

  // MARK: Public

  public let configURL: URL
  public let fileManager: FileManager

  public static func live(fileManager: FileManager = .default) throws -> Self {
    let applicationSupportURL = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true,
    )

    return Self(
      configURL: applicationSupportURL
        .appendingPathComponent("calfind", isDirectory: true)
        .appendingPathComponent("config.json"),
      fileManager: fileManager,
    )
  }

  public func load() throws -> SavedCalendarsConfig {
    guard fileManager.fileExists(atPath: configURL.path) else {
      return SavedCalendarsConfig()
    }

    do {
      let data = try Data(contentsOf: configURL)
      if let config = try? JSONDecoder().decode(SavedCalendarsConfig.self, from: data) {
        return config
      }
      throw CredentialsError.configDecodeFailed(configURL)
    } catch {
      throw error as? CredentialsError ?? CredentialsError.configDecodeFailed(configURL)
    }
  }

  public func save(_ config: SavedCalendarsConfig) throws {
    guard !config.calendars.isEmpty else {
      try clear()
      return
    }

    let directoryURL = configURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700],
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(config)
    try data.write(to: configURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
  }

  public func clear() throws {
    guard fileManager.fileExists(atPath: configURL.path) else {
      return
    }
    try fileManager.removeItem(at: configURL)
  }
}

// MARK: - PasswordStore

public protocol PasswordStore {
  func password(for calendar: String) throws -> String?
  func save(password: String, for calendar: String) throws
  func deletePassword(for calendar: String) throws
}

// MARK: - KeychainPasswordStore

public struct KeychainPasswordStore: PasswordStore {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  public func password(for calendar: String) throws -> String? {
    var result: CFTypeRef?
    let query = baseQuery(for: calendar).merging([
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecReturnData as String: true,
    ]) { _, newValue in newValue }

    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
        throw CredentialsError.invalidStoredPassword
      }
      return password

    case errSecItemNotFound:
      return nil

    default:
      throw CredentialsError.keychainFailure(action: "load password", status: status)
    }
  }

  public func save(password: String, for calendar: String) throws {
    let addQuery = baseQuery(for: calendar).merging([
      kSecValueData as String: Data(password.utf8)
    ]) { _, newValue in newValue }

    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    switch addStatus {
    case errSecSuccess:
      return

    case errSecDuplicateItem:
      let attributes = [kSecValueData as String: Data(password.utf8)]
      let updateStatus = SecItemUpdate(baseQuery(for: calendar) as CFDictionary, attributes as CFDictionary)
      guard updateStatus == errSecSuccess else {
        throw CredentialsError.keychainFailure(action: "update password", status: updateStatus)
      }

    default:
      throw CredentialsError.keychainFailure(action: "save password", status: addStatus)
    }
  }

  public func deletePassword(for calendar: String) throws {
    let status = SecItemDelete(baseQuery(for: calendar) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CredentialsError.keychainFailure(action: "delete password", status: status)
    }
  }

  // MARK: Private

  private static let serviceName = "calfind"

  private func baseQuery(for calendar: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.serviceName,
      kSecAttrAccount as String: calendar,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecAttrSynchronizable as String: kCFBooleanFalse!,
    ]
  }
}

// MARK: - CredentialsError

public enum CredentialsError: Error, CustomStringConvertible, Equatable {
  case configDecodeFailed(URL)
  case interactivePromptRequiresTerminal
  case invalidCalendarName
  case invalidStoredPassword
  case invalidURL(String)
  case keychainFailure(action: String, status: OSStatus)
  case missingCalendar
  case missingPassword
  case missingPasswordFromStdin
  case missingURL
  case missingUsername
  case promptCancelled(String)
  case stdinPasswordNotUTF8
  case unknownCalendar(String)

  // MARK: Public

  public var description: String {
    switch self {
    case .configDecodeFailed(let url):
      return "Saved config at '\(url.path)' is not valid JSON."

    case .interactivePromptRequiresTerminal:
      return "Interactive login requires a terminal."

    case .invalidCalendarName:
      return "Calendar names must not be empty."

    case .invalidStoredPassword:
      return "Saved Keychain password was not valid UTF-8."

    case .invalidURL(let value):
      return "Invalid CalDAV URL '\(value)'."

    case .keychainFailure(let action, let status):
      let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
      return "Keychain failed to \(action): \(message)."

    case .missingCalendar:
      return "Missing saved calendar name. Pass --calendar."

    case .missingPassword:
      return "Missing CalDAV app-specific password. Run calfind auth login or pass --password-stdin."

    case .missingPasswordFromStdin:
      return "No password was received on standard input."

    case .missingURL:
      return "Missing CalDAV URL. Run calfind auth login or pass --caldav-url."

    case .missingUsername:
      return "Missing CalDAV username. Run calfind auth login or pass --caldav-username."

    case .promptCancelled(let prompt):
      return "Input ended while reading \(prompt)."

    case .stdinPasswordNotUTF8:
      return "Password from standard input was not valid UTF-8."

    case .unknownCalendar(let calendar):
      return "No saved calendar named '\(calendar)' was found."
    }
  }
}

public func calendarName(from value: String) throws -> String {
  let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !normalized.isEmpty else {
    throw CredentialsError.invalidCalendarName
  }
  return normalized
}

func requiredText(_ value: String, missing error: CredentialsError) throws -> String {
  let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !normalized.isEmpty else {
    throw error
  }
  return normalized
}

func normalizedText(_ value: String?) -> String? {
  guard let value else {
    return nil
  }

  let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return normalized.isEmpty ? nil : normalized
}

func nonEmptySecret(_ value: String?) -> String? {
  guard let value, !value.isEmpty else {
    return nil
  }
  return value
}

func validatedURLString(from value: String) throws -> String {
  let normalized = try requiredText(value, missing: .missingURL)
  guard
    let components = URLComponents(string: normalized),
    components.scheme?.lowercased() == "https",
    components.host != nil,
    components.user == nil,
    components.password == nil
  else {
    throw CredentialsError.invalidURL(normalized)
  }
  return normalized
}
