import Foundation
import Testing
@testable import CalfindKit

// MARK: - CredentialResolverTests

struct CredentialResolverTests {

  // MARK: Internal

  @Test
  func `resolves URL and username from config and password from Keychain`() throws {
    let (configStore, directoryURL) = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    let passwordStore = FakePasswordStore()
    let manager = AuthManager(configStore: configStore, passwordStore: passwordStore)

    let savedCalendar = try manager.save(
      calendar: "personal",
      url: "https://caldav.example.test/home/",
      username: "user@example.com",
      password: "secret",
    )

    #expect(savedCalendar == "personal")

    let resolver = CredentialResolver(
      configStore: configStore,
      passwordStore: passwordStore,
      stdinPasswordReader: { throw TestError.unexpectedPasswordRead },
    )

    let credentials = try resolver.resolve(
      input: SearchCredentialInput(
        url: nil,
        username: nil,
        passwordFromStdin: false,
        calendar: "personal",
      )
    )

    #expect(credentials == CalDavCredentials(
      url: "https://caldav.example.test/home/",
      username: "user@example.com",
      password: "secret",
    ))
  }

  @Test
  func `uses explicit URL and username with password from standard input`() throws {
    let (configStore, directoryURL) = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    let passwordStore = FakePasswordStore(passwords: ["personal": "keychain-secret"])
    try configStore.save(SavedCalendarsConfig(calendars: [
      "personal": SavedCalendar(url: "https://stored.example.test/calendar/", username: "stored-user")
    ]))

    var stdinReadCount = 0
    let resolver = CredentialResolver(
      configStore: configStore,
      passwordStore: passwordStore,
      stdinPasswordReader: {
        stdinReadCount += 1
        return "stdin-secret"
      },
    )

    let credentials = try resolver.resolve(
      input: SearchCredentialInput(
        url: "https://flag.example.test/calendar/",
        username: "flag-user",
        passwordFromStdin: true,
        calendar: nil,
      )
    )

    #expect(credentials == CalDavCredentials(
      url: "https://flag.example.test/calendar/",
      username: "flag-user",
      password: "stdin-secret",
    ))
    #expect(stdinReadCount == 1)
  }

  @Test
  func `reads password from standard input before Keychain`() throws {
    let (configStore, directoryURL) = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    let passwordStore = FakePasswordStore(passwords: ["personal": "keychain-secret"])
    try configStore.save(SavedCalendarsConfig(calendars: [
      "personal": SavedCalendar(url: "https://stored.example.test/calendar/", username: "stored-user")
    ]))

    let resolver = CredentialResolver(
      configStore: configStore,
      passwordStore: passwordStore,
      stdinPasswordReader: { "stdin-secret" },
    )

    let credentials = try resolver.resolve(
      input: SearchCredentialInput(
        url: nil,
        username: nil,
        passwordFromStdin: true,
        calendar: "personal",
      )
    )

    #expect(credentials.password == "stdin-secret")
  }

  @Test
  func `requires calendar name when using saved calendars`() throws {
    let (configStore, directoryURL) = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    try configStore.save(SavedCalendarsConfig(calendars: [
      "personal": SavedCalendar(url: "https://home.example.test/calendar/", username: "home-user")
    ]))

    let resolver = CredentialResolver(
      configStore: configStore,
      passwordStore: FakePasswordStore(passwords: ["personal": "secret"]),
      stdinPasswordReader: { throw TestError.unexpectedPasswordRead },
    )

    #expect(throws: CredentialsError.missingCalendar) {
      try resolver.resolve(
        input: SearchCredentialInput(
          url: nil,
          username: nil,
          passwordFromStdin: false,
          calendar: nil,
        )
      )
    }
  }

  @Test
  func `logs out only the selected saved calendar`() throws {
    let (configStore, directoryURL) = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    let passwordStore = FakePasswordStore(passwords: [
      "personal": "personal-secret",
      "work": "work-secret",
    ])
    let manager = AuthManager(configStore: configStore, passwordStore: passwordStore)

    try configStore.save(SavedCalendarsConfig(calendars: [
      "personal": SavedCalendar(url: "https://home.example.test/calendar/", username: "home-user"),
      "work": SavedCalendar(url: "https://work.example.test/calendar/", username: "work-user"),
    ]))

    try manager.logout(calendar: "personal")

    let updated = try configStore.load()
    #expect(updated.calendars["personal"] == nil)
    #expect(updated.calendars["work"] == SavedCalendar(url: "https://work.example.test/calendar/", username: "work-user"))
    #expect(try passwordStore.password(for: "personal") == nil)
    #expect(try passwordStore.password(for: "work") == "work-secret")
  }

  @Test
  func `logs out all saved calendars and credentials`() throws {
    let (configStore, directoryURL) = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    let passwordStore = FakePasswordStore(passwords: [
      "personal": "personal-secret",
      "work": "work-secret",
    ])
    let manager = AuthManager(configStore: configStore, passwordStore: passwordStore)

    try configStore.save(SavedCalendarsConfig(calendars: [
      "personal": SavedCalendar(url: "https://home.example.test/calendar/", username: "home-user"),
      "work": SavedCalendar(url: "https://work.example.test/calendar/", username: "work-user"),
    ]))

    try manager.logoutAll()

    #expect(try configStore.load().calendars.isEmpty)
    #expect(try passwordStore.password(for: "personal") == nil)
    #expect(try passwordStore.password(for: "work") == nil)
  }

  @Test
  func `rolls back a password when the config cannot be saved`() throws {
    let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let blockedURL = directoryURL.appendingPathComponent("blocked")
    #expect(FileManager.default.createFile(atPath: blockedURL.path, contents: Data()))

    let configStore = SavedCredentialsStore(configURL: blockedURL.appendingPathComponent("config.json"))
    let passwordStore = FakePasswordStore()
    let manager = AuthManager(configStore: configStore, passwordStore: passwordStore)

    do {
      _ = try manager.save(
        calendar: "personal",
        url: "https://caldav.example.test/home/",
        username: "user@example.com",
        password: "secret",
      )
      Issue.record("Expected saving the blocked config to fail.")
    } catch {
      #expect(try passwordStore.password(for: "personal") == nil)
    }
  }

  @Test
  func `rejects legacy single-calendar configs`() throws {
    let (configStore, directoryURL) = Self.makeStore()
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let legacyConfig = "{\"url\":\"https://caldav.example.test/home/\",\"username\":\"user@example.com\"}"
    try Data(legacyConfig.utf8).write(to: configStore.configURL)

    #expect(throws: CredentialsError.configDecodeFailed(configStore.configURL)) {
      try configStore.load()
    }
  }

  // MARK: Private

  private static func makeStore() -> (SavedCredentialsStore, URL) {
    let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let configStore = SavedCredentialsStore(configURL: directoryURL.appendingPathComponent("config.json"))
    return (configStore, directoryURL)
  }
}

// MARK: - TestError

private enum TestError: Error {
  case unexpectedPasswordRead
}

// MARK: - FakePasswordStore

private final class FakePasswordStore: PasswordStore {

  // MARK: Lifecycle

  init(passwords: [String: String] = [:]) {
    self.passwords = passwords
  }

  // MARK: Internal

  var passwords: [String: String]

  func password(for calendar: String) throws -> String? {
    passwords[calendar]
  }

  func save(password: String, for calendar: String) throws {
    passwords[calendar] = password
  }

  func deletePassword(for calendar: String) throws {
    passwords.removeValue(forKey: calendar)
  }
}
