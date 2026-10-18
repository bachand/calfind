import Foundation
import Testing
@testable import CalfindKit

// MARK: - CalDavClientTests

struct CalDavClientTests {

  // MARK: Internal

  @Test
  func `sends REPORT and expands recurring events with moved overrides`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    MockURLProtocol.registerHandler(for: url) { request in
      #expect(request.httpMethod == "REPORT")
      #expect(request.value(forHTTPHeaderField: "Content-Type") == "text/xml; charset=utf-8")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpwYXNz")

      let body = try #require(Self.requestBody(from: request).flatMap { String(data: $0, encoding: .utf8) })
      #expect(body.contains(#"<c:time-range start="20260101T000000Z" end="20260201T000000Z"/>"#))

      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 207,
        httpVersion: nil,
        headerFields: nil,
      )!
      return (response, Data(Self.recurrenceDurationMultistatus.utf8))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))

    let startDate = try #require(Self.utcDate("2026-01-01T00:00:00Z"))
    let endDate = try #require(Self.utcDate("2026-01-31T23:59:59Z"))
    let occurrences = try await client.occurrences(
      url: url.absoluteString,
      username: "user",
      appSpecificPassword: "pass",
      startDate: startDate,
      endDate: endDate,
    )

    #expect(occurrences.map(\.startDate) == [
      try #require(Self.utcDate("2026-01-05T09:00:00Z")),
      try #require(Self.utcDate("2026-01-13T11:30:00Z")),
      try #require(Self.utcDate("2026-01-20T14:00:00Z")),
      try #require(Self.utcDate("2026-01-26T09:00:00Z")),
    ])
    #expect(occurrences.map(\.title) == ["Planning", "Moved Planning", "Moved without duration", "Planning"])
    #expect(occurrences.map(\.duration) == [3600, 7200, 3600, 3600])
  }

  @Test
  func `respects recurrence exclusions and additions`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    MockURLProtocol.registerHandler(for: url) { request in
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 207,
        httpVersion: nil,
        headerFields: nil,
      )!
      return (response, Data(Self.recurrenceExceptionsMultistatus.utf8))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))
    let occurrences = try await client.occurrences(
      url: url.absoluteString,
      username: "user",
      appSpecificPassword: "pass",
      startDate: try #require(Self.utcDate("2026-01-01T00:00:00Z")),
      endDate: try #require(Self.utcDate("2026-01-31T23:59:59Z")),
    )

    #expect(occurrences.map(\.startDate) == [
      try #require(Self.utcDate("2026-01-05T09:00:00Z")),
      try #require(Self.utcDate("2026-01-19T09:00:00Z")),
      try #require(Self.utcDate("2026-01-20T09:00:00Z")),
    ])
  }

  @Test
  func `expands recurring events in their time zone`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    MockURLProtocol.registerHandler(for: url) { request in
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 207,
        httpVersion: nil,
        headerFields: nil,
      )!
      return (response, Data(Self.timeZoneRecurrenceMultistatus.utf8))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))
    let occurrences = try await client.occurrences(
      url: url.absoluteString,
      username: "user",
      appSpecificPassword: "pass",
      startDate: try #require(Self.utcDate("2026-03-07T00:00:00Z")),
      endDate: try #require(Self.utcDate("2026-03-10T00:00:00Z")),
    )

    #expect(occurrences.map(\.startDate) == [
      try #require(Self.utcDate("2026-03-07T17:00:00Z")),
      try #require(Self.utcDate("2026-03-08T16:00:00Z")),
      try #require(Self.utcDate("2026-03-09T16:00:00Z")),
    ])
  }

  @Test
  func `omits cancelled events`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    MockURLProtocol.registerHandler(for: url) { request in
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 207,
        httpVersion: nil,
        headerFields: nil,
      )!
      return (response, Data(Self.cancelledMultistatus.utf8))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))
    let occurrences = try await client.occurrences(
      url: url.absoluteString,
      username: "user",
      appSpecificPassword: "pass",
      startDate: try #require(Self.utcDate("2026-01-01T00:00:00Z")),
      endDate: try #require(Self.utcDate("2026-01-31T23:59:59Z")),
    )

    #expect(occurrences.isEmpty)
  }

  @Test
  func `parses XML-escaped calendar-data payloads`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    MockURLProtocol.registerHandler(for: url) { request in
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 207,
        httpVersion: nil,
        headerFields: nil,
      )!
      return (response, Data(Self.escapedMultistatus.utf8))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))

    let startDate = try #require(Self.utcDate("2026-01-01T00:00:00Z"))
    let endDate = try #require(Self.utcDate("2026-01-31T23:59:59Z"))
    let occurrences = try await client.occurrences(
      url: url.absoluteString,
      username: "user",
      appSpecificPassword: "pass",
      startDate: startDate,
      endDate: endDate,
    )

    #expect(occurrences.count == 1)
    #expect(occurrences.map(\.startDate) == [
      try #require(Self.utcDate("2026-01-08T15:00:00Z"))
    ])
    #expect(occurrences.map(\.title) == ["Docs & Review"])
    #expect(occurrences.map(\.notes) == ["Bring <notes> & agenda"])
    #expect(occurrences.map(\.duration) == [nil])
  }

  @Test
  func `parses event duration properties and all-day durations`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    MockURLProtocol.registerHandler(for: url) { request in
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 207,
        httpVersion: nil,
        headerFields: nil,
      )!
      return (response, Data(Self.durationsMultistatus.utf8))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))
    let occurrences = try await client.occurrences(
      url: url.absoluteString,
      username: "user",
      appSpecificPassword: "pass",
      startDate: try #require(Self.utcDate("2026-01-01T00:00:00Z")),
      endDate: try #require(Self.utcDate("2026-12-31T23:59:59Z")),
    )

    #expect(occurrences.map(\.title) == ["Duration value", "All day two", "All day default", "DST crossing"])
    #expect(occurrences.map(\.duration) == [5400, 172800, 86400, 3600])
  }

  @Test
  func `parses calendar data with literal escaped line breaks`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    MockURLProtocol.registerHandler(for: url) { request in
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 207,
        httpVersion: nil,
        headerFields: nil,
      )!
      let body = Self.multistatus.replacingOccurrences(of: "\n", with: "\\r\\n")
      return (response, Data(body.utf8))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))
    let occurrences = try await client.occurrences(
      url: url.absoluteString,
      username: "user",
      appSpecificPassword: "pass",
      startDate: try #require(Self.utcDate("2026-01-01T00:00:00Z")),
      endDate: try #require(Self.utcDate("2026-01-31T23:59:59Z")),
    )

    #expect(occurrences.map(\.startDate) == [
      try #require(Self.utcDate("2026-01-05T09:00:00Z")),
      try #require(Self.utcDate("2026-01-13T11:30:00Z")),
      try #require(Self.utcDate("2026-01-19T09:00:00Z")),
    ])
  }

  @Test
  func `parses calendar data with literal escaped LF line breaks`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    MockURLProtocol.registerHandler(for: url) { request in
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 207,
        httpVersion: nil,
        headerFields: nil,
      )!
      let body = Self.multistatus.replacingOccurrences(of: "\n", with: "\\n")
      return (response, Data(body.utf8))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))
    let occurrences = try await client.occurrences(
      url: url.absoluteString,
      username: "user",
      appSpecificPassword: "pass",
      startDate: try #require(Self.utcDate("2026-01-01T00:00:00Z")),
      endDate: try #require(Self.utcDate("2026-01-31T23:59:59Z")),
    )

    #expect(occurrences.count == 3)
  }

  @Test
  func `parses calendar data with Unicode line separators`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    MockURLProtocol.registerHandler(for: url) { request in
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 207,
        httpVersion: nil,
        headerFields: nil,
      )!
      let body = Self.multistatus.replacingOccurrences(of: "\n", with: "\u{2028}")
      return (response, Data(body.utf8))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))
    let occurrences = try await client.occurrences(
      url: url.absoluteString,
      username: "user",
      appSpecificPassword: "pass",
      startDate: try #require(Self.utcDate("2026-01-01T00:00:00Z")),
      endDate: try #require(Self.utcDate("2026-01-31T23:59:59Z")),
    )

    #expect(occurrences.count == 3)
  }

  @Test
  func `skips malformed recurrence rules while returning valid events`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    MockURLProtocol.registerHandler(for: url) { request in
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 207,
        httpVersion: nil,
        headerFields: nil,
      )!
      let body = Self.multistatus.replacingOccurrences(
        of: "END:VCALENDAR",
        with: """
          BEGIN:VEVENT
          UID:malformed-recurrence
          DTSTART:20260107T090000Z
          RRULE:FREQ=INVALID
          SUMMARY:Ignored recurrence
          END:VEVENT
          END:VCALENDAR
          """,
      )
      return (response, Data(body.utf8))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))
    let occurrences = try await client.occurrences(
      url: url.absoluteString,
      username: "user",
      appSpecificPassword: "pass",
      startDate: try #require(Self.utcDate("2026-01-01T00:00:00Z")),
      endDate: try #require(Self.utcDate("2026-01-31T23:59:59Z")),
    )

    #expect(occurrences.map(\.title) == ["Planning", "Moved Planning", "Planning"])
  }

  @Test
  func `rejects malformed XML responses`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    MockURLProtocol.registerHandler(for: url) { request in
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 207,
        httpVersion: nil,
        headerFields: nil,
      )!
      return (response, Data("<d:multistatus>".utf8))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))

    await #expect(throws: CalDavError.invalidXMLResponse) {
      try await client.occurrences(
        url: url.absoluteString,
        username: "user",
        appSpecificPassword: "pass",
        startDate: try #require(Self.utcDate("2026-01-01T00:00:00Z")),
        endDate: try #require(Self.utcDate("2026-01-31T23:59:59Z")),
      )
    }
  }

  @Test
  func `sanitizes and limits HTTP error responses`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    MockURLProtocol.registerHandler(for: url) { request in
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 500,
        httpVersion: nil,
        headerFields: nil,
      )!
      let body = "\u{001B}[31m" + String(repeating: "x", count: 5000)
      return (response, Data(body.utf8))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))

    do {
      _ = try await client.occurrences(
        url: url.absoluteString,
        username: "user",
        appSpecificPassword: "pass",
        startDate: try #require(Self.utcDate("2026-01-01T00:00:00Z")),
        endDate: try #require(Self.utcDate("2026-01-31T23:59:59Z")),
      )
      Issue.record("Expected the server error to be thrown.")
    } catch let error as CalDavError {
      #expect(!error.description.contains("\u{001B}"))
      #expect(error.description.count < 4200)
    }
  }

  @Test
  func `rejects oversized responses`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    MockURLProtocol.registerHandler(for: url) { request in
      let response = HTTPURLResponse(
        url: try #require(request.url),
        statusCode: 207,
        httpVersion: nil,
        headerFields: nil,
      )!
      return (response, Data(repeating: 0x20, count: 10 * 1024 * 1024 + 1))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))

    await #expect(throws: CalDavError.responseTooLarge) {
      try await client.occurrences(
        url: url.absoluteString,
        username: "user",
        appSpecificPassword: "pass",
        startDate: try #require(Self.utcDate("2026-01-01T00:00:00Z")),
        endDate: try #require(Self.utcDate("2026-01-31T23:59:59Z")),
      )
    }
  }

  @Test
  func `rejects responses from a different origin`() async throws {
    let url = try #require(URL(string: "https://caldav.example.test/\(UUID().uuidString)/calendar/"))
    let attackerURL = try #require(URL(string: "https://attacker.example.test/calendar/"))
    MockURLProtocol.registerHandler(for: url) { _ in
      let response = HTTPURLResponse(
        url: attackerURL,
        statusCode: 207,
        httpVersion: nil,
        headerFields: nil,
      )!
      return (response, Data(Self.multistatus.utf8))
    }
    defer { MockURLProtocol.removeHandler(for: url) }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))

    await #expect(throws: CalDavError.redirectedToDifferentOrigin) {
      try await client.occurrences(
        url: url.absoluteString,
        username: "user",
        appSpecificPassword: "pass",
        startDate: try #require(Self.utcDate("2026-01-01T00:00:00Z")),
        endDate: try #require(Self.utcDate("2026-01-31T23:59:59Z")),
      )
    }
  }

  @Test
  func `discovers calendar collection URLs`() async throws {
    let wellKnownURL = try #require(URL(string: "https://caldav.example.test/.well-known/caldav"))
    let principalURL = try #require(URL(string: "https://caldav.example.test/principals/user/"))
    let homeURL = try #require(URL(string: "https://caldav.example.test/calendars/user/"))

    MockURLProtocol.registerHandler(for: wellKnownURL) { request in
      #expect(request.httpMethod == "PROPFIND")
      #expect(request.value(forHTTPHeaderField: "Depth") == "0")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic dXNlcjpwYXNz")
      return (Self.multistatusResponse(for: request), Data(Self.currentUserPrincipalResponse.utf8))
    }
    MockURLProtocol.registerHandler(for: principalURL) { request in
      #expect(request.httpMethod == "PROPFIND")
      #expect(request.value(forHTTPHeaderField: "Depth") == "0")
      return (Self.multistatusResponse(for: request), Data(Self.calendarHomeSetResponse.utf8))
    }
    MockURLProtocol.registerHandler(for: homeURL) { request in
      #expect(request.httpMethod == "PROPFIND")
      #expect(request.value(forHTTPHeaderField: "Depth") == "1")
      return (Self.multistatusResponse(for: request), Data(Self.calendarCollectionsResponse.utf8))
    }
    defer {
      MockURLProtocol.removeHandler(for: wellKnownURL)
      MockURLProtocol.removeHandler(for: principalURL)
      MockURLProtocol.removeHandler(for: homeURL)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))

    let collections = try await client.discoverCalendarCollections(
      serverURL: "https://caldav.example.test",
      username: "user",
      appSpecificPassword: "pass",
    )

    #expect(collections == [
      CalDavCalendarCollection(url: "https://caldav.example.test/calendars/user/home/", displayName: "Home"),
      CalDavCalendarCollection(url: "https://caldav.example.test/calendars/user/work/", displayName: "Work"),
    ])
  }

  @Test
  func `supports no-auth discovery`() async throws {
    let wellKnownURL = try #require(URL(string: "https://public.example.test/.well-known/caldav"))
    let principalURL = try #require(URL(string: "https://public.example.test/principals/anonymous/"))
    let homeURL = try #require(URL(string: "https://public.example.test/calendars/public/"))

    MockURLProtocol.registerHandler(for: wellKnownURL) { request in
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      return (Self.multistatusResponse(for: request), Data(Self.anonymousPrincipalResponse.utf8))
    }
    MockURLProtocol.registerHandler(for: principalURL) { request in
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      return (Self.multistatusResponse(for: request), Data(Self.publicHomeSetResponse.utf8))
    }
    MockURLProtocol.registerHandler(for: homeURL) { request in
      #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
      return (Self.multistatusResponse(for: request), Data(Self.publicCalendarCollectionsResponse.utf8))
    }
    defer {
      MockURLProtocol.removeHandler(for: wellKnownURL)
      MockURLProtocol.removeHandler(for: principalURL)
      MockURLProtocol.removeHandler(for: homeURL)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))

    let collections = try await client.discoverCalendarCollections(
      serverURL: "https://public.example.test",
      username: nil,
      appSpecificPassword: nil,
    )

    #expect(collections == [
      CalDavCalendarCollection(url: "https://public.example.test/calendars/public/releases/", displayName: "Releases")
    ])
  }

  @Test
  func `rejects cross-origin discovery links`() async throws {
    let serverHost = "\(UUID().uuidString).example.test"
    let serverURL = try #require(URL(string: "https://\(serverHost)"))
    let wellKnownURL = try #require(URL(string: "https://\(serverHost)/.well-known/caldav"))
    let attackerURL = try #require(URL(string: "https://attacker.example.test/principals/user/"))

    MockURLProtocol.registerHandler(for: wellKnownURL) { request in
      (Self.multistatusResponse(for: request), Data(Self.crossOriginPrincipalResponse.utf8))
    }
    MockURLProtocol.registerHandler(for: serverURL) { request in
      (Self.multistatusResponse(for: request), Data(Self.crossOriginPrincipalResponse.utf8))
    }
    MockURLProtocol.registerHandler(for: attackerURL) { _ in
      Issue.record("Discovery must not request off-origin DAV links.")
      throw URLError(.badServerResponse)
    }
    defer {
      MockURLProtocol.removeHandler(for: wellKnownURL)
      MockURLProtocol.removeHandler(for: serverURL)
      MockURLProtocol.removeHandler(for: attackerURL)
    }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let client = CalDavClient(session: URLSession(configuration: configuration))

    await #expect(throws: CalDavError.self) {
      try await client.discoverCalendarCollections(
        serverURL: serverURL.absoluteString,
        username: "user",
        appSpecificPassword: "pass",
      )
    }
  }

  // MARK: Private

  private static let multistatus = #"""
  <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
    <d:response>
      <d:propstat>
        <d:prop>
          <c:calendar-data><![CDATA[
  BEGIN:VCALENDAR
  VERSION:2.0
  BEGIN:VEVENT
  UID:series-1
  DTSTART:20260105T090000Z
  RRULE:FREQ=WEEKLY;COUNT=3
  SUMMARY:Planning
  LOCATION:Room 1
  DESCRIPTION:Weekly planning
  END:VEVENT
  BEGIN:VEVENT
  UID:series-1
  RECURRENCE-ID:20260112T090000Z
  DTSTART:20260113T113000Z
  SUMMARY:Moved Planning
  LOCATION:Room 2
  DESCRIPTION:Moved instance
  END:VEVENT
  END:VCALENDAR
          ]]></c:calendar-data>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static let recurrenceDurationMultistatus = #"""
  <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
    <d:response>
      <d:propstat>
        <d:prop>
          <c:calendar-data><![CDATA[
  BEGIN:VCALENDAR
  VERSION:2.0
  BEGIN:VEVENT
  UID:series-1
  DTSTART:20260105T090000Z
  DTEND:20260105T100000Z
  RRULE:FREQ=WEEKLY;COUNT=4
  SUMMARY:Planning
  LOCATION:Room 1
  DESCRIPTION:Weekly planning
  END:VEVENT
  BEGIN:VEVENT
  UID:series-1
  RECURRENCE-ID:20260112T090000Z
  DTSTART:20260113T113000Z
  DTEND:20260113T133000Z
  SUMMARY:Moved Planning
  LOCATION:Room 2
  DESCRIPTION:Moved instance
  END:VEVENT
  BEGIN:VEVENT
  UID:series-1
  RECURRENCE-ID:20260119T090000Z
  DTSTART:20260120T140000Z
  SUMMARY:Moved without duration
  END:VEVENT
  END:VCALENDAR
          ]]></c:calendar-data>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static let durationsMultistatus = #"""
  <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
    <d:response>
      <d:propstat>
        <d:prop>
          <c:calendar-data><![CDATA[
  BEGIN:VCALENDAR
  VERSION:2.0
  BEGIN:VEVENT
  UID:duration-value
  DTSTART:20260108T090000Z
  DURATION:PT1H30M
  SUMMARY:Duration value
  END:VEVENT
  BEGIN:VEVENT
  UID:all-day-two
  DTSTART;VALUE=DATE:20260109
  DTEND;VALUE=DATE:20260111
  SUMMARY:All day two
  END:VEVENT
  BEGIN:VEVENT
  UID:all-day-default
  DTSTART;VALUE=DATE:20260112
  SUMMARY:All day default
  END:VEVENT
  BEGIN:VEVENT
  UID:dst-crossing
  DTSTART;TZID=America/Los_Angeles:20260308T013000
  DTEND;TZID=America/Los_Angeles:20260308T033000
  SUMMARY:DST crossing
  END:VEVENT
  END:VCALENDAR
          ]]></c:calendar-data>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static let escapedMultistatus = #"""
  <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
    <d:response>
      <d:propstat>
        <d:prop>
          <c:calendar-data>BEGIN:VCALENDAR
  VERSION:2.0
  BEGIN:VEVENT
  UID:escaped-1
  DTSTART:20260108T150000Z
  SUMMARY:Docs &amp; Review
  DESCRIPTION:Bring &lt;notes&gt; &amp; agenda
  END:VEVENT
  END:VCALENDAR</c:calendar-data>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static let recurrenceExceptionsMultistatus = #"""
  <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
    <d:response>
      <d:propstat>
        <d:prop>
          <c:calendar-data><![CDATA[
  BEGIN:VCALENDAR
  VERSION:2.0
  BEGIN:VEVENT
  UID:exceptions-1
  DTSTART:20260105T090000Z
  RRULE:FREQ=WEEKLY;COUNT=3
  EXDATE:20260112T090000Z
  RDATE:20260120T090000Z
  SUMMARY:Exceptions
  END:VEVENT
  END:VCALENDAR
          ]]></c:calendar-data>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static let timeZoneRecurrenceMultistatus = #"""
  <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
    <d:response>
      <d:propstat>
        <d:prop>
          <c:calendar-data><![CDATA[
  BEGIN:VCALENDAR
  VERSION:2.0
  BEGIN:VEVENT
  UID:timezone-1
  DTSTART;TZID=America/Los_Angeles:20260307T090000
  RRULE:FREQ=DAILY;COUNT=3
  SUMMARY:Time zone meeting
  END:VEVENT
  END:VCALENDAR
          ]]></c:calendar-data>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static let cancelledMultistatus = #"""
  <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
    <d:response>
      <d:propstat>
        <d:prop>
          <c:calendar-data><![CDATA[
  BEGIN:VCALENDAR
  VERSION:2.0
  BEGIN:VEVENT
  UID:cancelled-1
  DTSTART:20260105T090000Z
  STATUS:CANCELLED
  SUMMARY:Cancelled
  END:VEVENT
  END:VCALENDAR
          ]]></c:calendar-data>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static let currentUserPrincipalResponse = #"""
  <d:multistatus xmlns:d="DAV:">
    <d:response>
      <d:href>/.well-known/caldav</d:href>
      <d:propstat>
        <d:prop>
          <d:current-user-principal>
            <d:href>/principals/user/</d:href>
          </d:current-user-principal>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static let anonymousPrincipalResponse = #"""
  <d:multistatus xmlns:d="DAV:">
    <d:response>
      <d:propstat>
        <d:prop>
          <d:current-user-principal>
            <d:href>/principals/anonymous/</d:href>
          </d:current-user-principal>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static let crossOriginPrincipalResponse = #"""
  <d:multistatus xmlns:d="DAV:">
    <d:response>
      <d:propstat>
        <d:prop>
          <d:current-user-principal>
            <d:href>https://attacker.example.test/principals/user/</d:href>
          </d:current-user-principal>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static let calendarHomeSetResponse = #"""
  <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
    <d:response>
      <d:propstat>
        <d:prop>
          <c:calendar-home-set>
            <d:href>/calendars/user/</d:href>
          </c:calendar-home-set>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static let publicHomeSetResponse = #"""
  <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
    <d:response>
      <d:propstat>
        <d:prop>
          <c:calendar-home-set>
            <d:href>/calendars/public/</d:href>
          </c:calendar-home-set>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static let calendarCollectionsResponse = #"""
  <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
    <d:response>
      <d:href>/calendars/user/</d:href>
      <d:propstat>
        <d:prop>
          <d:displayname>User Calendar Home</d:displayname>
          <d:resourcetype><d:collection /></d:resourcetype>
        </d:prop>
      </d:propstat>
    </d:response>
    <d:response>
      <d:href>/calendars/user/work/</d:href>
      <d:propstat>
        <d:prop>
          <d:displayname>Work</d:displayname>
          <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
        </d:prop>
      </d:propstat>
    </d:response>
    <d:response>
      <d:href>/calendars/user/home/</d:href>
      <d:propstat>
        <d:prop>
          <d:displayname>Home</d:displayname>
          <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static let publicCalendarCollectionsResponse = #"""
  <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
    <d:response>
      <d:href>/calendars/public/releases/</d:href>
      <d:propstat>
        <d:prop>
          <d:displayname>Releases</d:displayname>
          <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
        </d:prop>
      </d:propstat>
    </d:response>
  </d:multistatus>
  """#

  private static func multistatusResponse(for request: URLRequest) -> HTTPURLResponse {
    HTTPURLResponse(
      url: request.url!,
      statusCode: 207,
      httpVersion: nil,
      headerFields: nil,
    )!
  }

  private static func utcDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  private static func requestBody(from request: URLRequest) -> Data? {
    if let httpBody = request.httpBody {
      return httpBody
    }

    guard let stream = request.httpBodyStream else {
      return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else {
        break
      }
      data.append(buffer, count: count)
    }
    return data
  }

}

// MARK: - MockURLProtocol

private final class MockURLProtocol: URLProtocol {

  // MARK: Internal

  override class func canInit(with _: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let requestHandler = Self.requestHandler(for: request) else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }

    do {
      let (response, data) = try requestHandler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() { }

  // MARK: Fileprivate

  fileprivate typealias RequestHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

  fileprivate static func registerHandler(for url: URL, handler: @escaping RequestHandler) {
    requestHandlersLock.lock()
    requestHandlers[url.absoluteString] = handler
    requestHandlersLock.unlock()
  }

  fileprivate static func removeHandler(for url: URL) {
    requestHandlersLock.lock()
    requestHandlers.removeValue(forKey: url.absoluteString)
    requestHandlersLock.unlock()
  }

  // MARK: Private

  nonisolated(unsafe) private static var requestHandlers = [String: RequestHandler]()
  private static let requestHandlersLock = NSLock()

  private static func requestHandler(for request: URLRequest) -> RequestHandler? {
    guard let url = request.url else {
      return nil
    }

    requestHandlersLock.lock()
    defer { requestHandlersLock.unlock() }
    return requestHandlers[url.absoluteString]
  }

}
