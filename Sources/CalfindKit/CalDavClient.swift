import Foundation
import RRuleKit

// MARK: - CalDavOccurrence

public struct CalDavOccurrence: Equatable, Sendable {
  public init(startDate: Date, title: String?, location: String?, notes: String?, duration: TimeInterval? = nil) {
    self.startDate = startDate
    self.title = title
    self.location = location
    self.notes = notes
    self.duration = duration
  }

  public let startDate: Date
  public let title: String?
  public let location: String?
  public let notes: String?
  public let duration: TimeInterval?

}

// MARK: - CalDavCalendarCollection

public struct CalDavCalendarCollection: Equatable, Sendable {
  public init(url: String, displayName: String?) {
    self.url = url
    self.displayName = displayName
  }

  public let url: String
  public let displayName: String?
}

// MARK: - CalDavClient

public final class CalDavClient {

  // MARK: Lifecycle

  public init() {
    let redirectDelegate = CalDavRedirectDelegate()
    session = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)
    self.redirectDelegate = redirectDelegate
  }

  public init(session: URLSession) {
    self.session = session
    redirectDelegate = nil
  }

  // MARK: Public

  public func occurrences(
    url: String,
    username: String,
    appSpecificPassword: String,
    startDate: Date,
    endDate: Date,
  ) async throws -> [CalDavOccurrence] {
    guard startDate <= endDate else {
      throw CalDavError.invalidDateRange
    }
    guard let requestURL = Self.secureURL(from: url) else {
      throw CalDavError.invalidURL(url)
    }

    let responseBody = try await calendarReport(
      url: requestURL,
      username: username,
      appSpecificPassword: appSpecificPassword,
      startDate: startDate,
      endDate: endDate,
    )

    let calendars = try Self.calendarDataPayloads(from: responseBody)
    return try Self.occurrences(
      from: calendars,
      startDate: startDate,
      endDate: endDate,
    )
  }

  public func discoverCalendarCollections(
    serverURL: String,
    username: String?,
    appSpecificPassword: String?,
  ) async throws -> [CalDavCalendarCollection] {
    guard let rootURL = Self.secureURL(from: serverURL) else {
      throw CalDavError.invalidURL(serverURL)
    }

    let credentials = try discoveryCredentials(username: username, password: appSpecificPassword)
    var lastError: Error?
    for bootstrapURL in bootstrapURLs(for: rootURL) {
      do {
        return try await discoverCalendarCollections(
          bootstrapURL: bootstrapURL,
          rootURL: rootURL,
          credentials: credentials,
        )
      } catch {
        lastError = error
      }
    }

    if let lastError {
      throw lastError
    }
    return []
  }

  // MARK: Fileprivate

  fileprivate static var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utcTimeZone
    return calendar
  }

  fileprivate static func hasSameOrigin(_ url: URL, as rootURL: URL) -> Bool {
    url.scheme?.lowercased() == rootURL.scheme?.lowercased()
      && url.host?.lowercased() == rootURL.host?.lowercased()
      && effectivePort(for: url) == effectivePort(for: rootURL)
  }

  // MARK: Private

  private static let utcTimeZone = TimeZone(secondsFromGMT: 0)!
  private static let maximumResponseBytes = 10 * 1024 * 1024

  private static var reportDateFormatter: DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = utcCalendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = utcTimeZone
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter
  }

  private let session: URLSession
  private let redirectDelegate: CalDavRedirectDelegate?

  private static func basicAuth(username: String, password: String) -> String {
    Data("\(username):\(password)".utf8).base64EncodedString()
  }

  private static func secureURL(from value: String) -> URL? {
    guard
      let components = URLComponents(string: value),
      components.scheme?.lowercased() == "https",
      components.host != nil,
      components.user == nil,
      components.password == nil,
      let url = components.url
    else {
      return nil
    }
    return url
  }

  private static func displayName(from prop: XMLNode) -> String? {
    prop.firstNode(named: "displayname")?.stringValue?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func hrefs(named name: String, in xml: String, responseURL: URL) throws -> [URL] {
    let document = try xmlDocument(from: xml)
    let nodes = try document.nodes(forXPath: "//*[local-name()='\(name)']/*[local-name()='href']")
    return nodes.compactMap { node in
      guard let value = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
      }
      return URL(string: value, relativeTo: responseURL)?.absoluteURL
    }
  }

  private static func effectivePort(for url: URL) -> Int? {
    if let port = url.port {
      return port
    }
    switch url.scheme?.lowercased() {
    case "https":
      return 443
    case "http":
      return 80
    default:
      return nil
    }
  }

  /// iCloud returns the principal's calendar home on a regional host such as
  /// p114-caldav.icloud.com, even when discovery starts at caldav.icloud.com.
  /// Keep the normal same-origin restriction for every other provider, while
  /// allowing only Apple's dedicated CalDAV shard hosts here.
  private static func isAllowedDiscoveryURL(_ url: URL, relativeTo rootURL: URL) -> Bool {
    if hasSameOrigin(url, as: rootURL) {
      return true
    }
    guard
      rootURL.host?.lowercased() == "caldav.icloud.com",
      let host = url.host?.lowercased(),
      host.wholeMatch(of: /p[0-9]+-caldav\.icloud\.com/) != nil,
      url.scheme?.lowercased() == "https",
      effectivePort(for: url) == effectivePort(for: rootURL)
    else {
      return false
    }
    return true
  }

  private static func calendarCollections(
    from xml: String,
    responseURL: URL,
    rootURL: URL,
  ) throws -> [CalDavCalendarCollection] {
    let document = try xmlDocument(from: xml)
    let responses = try document.nodes(forXPath: "//*[local-name()='response']")
    return responses.compactMap { response in
      guard
        let href = response.firstNode(named: "href")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
        !href.isEmpty,
        response.containsNode(named: "calendar"),
        let url = URL(string: href, relativeTo: responseURL)?.absoluteURL,
        isAllowedDiscoveryURL(url, relativeTo: rootURL)
      else {
        return nil
      }

      return CalDavCalendarCollection(
        url: url.absoluteString,
        displayName: response.firstNode(named: "prop").flatMap(displayName(from:)),
      )
    }
    .sorted { lhs, rhs in
      (lhs.displayName ?? lhs.url).localizedCaseInsensitiveCompare(rhs.displayName ?? rhs.url) == .orderedAscending
    }
  }

  private static func reportBody(startDate: Date, endDate: Date) -> Data {
    let formatter = reportDateFormatter
    let exclusiveEndDate = endDate.addingTimeInterval(1)
    // CalDAV calendar-query REPORT asks the server for raw VCALENDAR payloads
    // in the requested range. We intentionally request `<c:calendar-data />`
    // without server-side recurrence expansion so RRuleKit can expand RRULEs
    // locally with the event's time-zone-aware calendar.
    let body = """
      <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
              <c:calendar-data />
          </d:prop>
          <c:filter>
              <c:comp-filter name="VCALENDAR">
                  <c:comp-filter name="VEVENT">
                      <c:time-range start="\(formatter.string(from: startDate))" end="\(formatter.string(from: exclusiveEndDate))"/>
                  </c:comp-filter>
              </c:comp-filter>
          </c:filter>
      </c:calendar-query>
      """
    return Data(body.utf8)
  }

  private static func calendarDataPayloads(from xml: String) throws -> [String] {
    let document = try xmlDocument(from: xml)

    // CalDAV payloads may namespace-qualify `calendar-data`, so match by local
    // name and let FoundationXML decode either CDATA or escaped text content.
    let nodes = try document.nodes(forXPath: "//*[local-name()='calendar-data']")
    return nodes.compactMap(\ .stringValue)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  private static func xmlDocument(from xml: String) throws -> XMLDocument {
    guard let data = xml.data(using: .utf8) else {
      throw CalDavError.invalidXMLResponse
    }
    do {
      return try XMLDocument(data: data)
    } catch {
      throw CalDavError.invalidXMLResponse
    }
  }

  private static func occurrences(
    from calendars: [String],
    startDate: Date,
    endDate: Date,
  ) throws -> [CalDavOccurrence] {
    let components = calendars.flatMap { eventComponents(from: $0) }
    let events = components.map(EventComponent.init(rawValue:))
    let groupedByUID = Dictionary(grouping: events, by: \.uid)
    var occurrences = [CalDavOccurrence]()

    for group in groupedByUID.values {
      let masters = group.filter { $0.recurrenceID == nil }
      let overrides = group.filter { $0.recurrenceID != nil }
      let overriddenOriginalDates = Set(overrides.compactMap(\.recurrenceID))

      for master in masters where !master.isCancelled {
        guard let dtstart = master.dtstart else {
          continue
        }

        var recurrenceDates = [Date]()
        if let rrule = master.rrule {
          let recurrenceCalendar = Self.calendar(timeZone: master.recurrenceTimeZone)
          let parser = RecurrenceRuleRFC5545FormatStyle(calendar: recurrenceCalendar)
          do {
            var recurrenceRule = try parser.parse(rrule)
            recurrenceRule.calendar = recurrenceCalendar

            for date in recurrenceRule.recurrences(of: dtstart) {
              guard date <= endDate else {
                break
              }
              recurrenceDates.append(date)
            }
          } catch {
            // A malformed recurrence rule in one remote event must not make
            // every other event in the calendar unsearchable.
          }
        } else {
          recurrenceDates.append(dtstart)
        }

        recurrenceDates.append(contentsOf: master.rdates)
        var emittedDates = Set<Date>()
        for date in recurrenceDates {
          guard
            date >= startDate,
            date <= endDate,
            !master.exdates.contains(date),
            !overriddenOriginalDates.contains(date),
            emittedDates.insert(date).inserted
          else {
            continue
          }
          occurrences.append(master.occurrence(at: date))
        }
      }

      for override in overrides where !override.isCancelled {
        guard let dtstart = override.dtstart, dtstart >= startDate, dtstart <= endDate else {
          continue
        }
        occurrences.append(override.occurrence(at: dtstart, fallbackDuration: masters.first?.duration))
      }
    }

    return occurrences.sorted { lhs, rhs in
      if lhs.startDate == rhs.startDate {
        return (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "") == .orderedAscending
      }
      return lhs.startDate < rhs.startDate
    }
  }

  private static func eventComponents(from ics: String) -> [String] {
    let unfolded = ics.unfoldedICalendarLines()
    // VEVENT blocks are the only components this CLI searches. Nested VALARM
    // components are ignored because they do not contain event occurrence dates.
    return unfolded.matches(of: #/(?is)BEGIN:VEVENT\s*(.*?)\s*END:VEVENT/#)
      .map { match in String(match.1) }
  }

  private static func calendar(timeZone: TimeZone) -> Calendar {
    var calendar = utcCalendar
    calendar.timeZone = timeZone
    return calendar
  }

  private static func errorBody(from data: Data) -> String {
    String(data: data.prefix(4096), encoding: .utf8) ?? "<invalid UTF-8 response>"
  }

  private static func httpResponse(_ response: URLResponse, for requestURL: URL) throws -> HTTPURLResponse {
    guard let httpResponse = response as? HTTPURLResponse else {
      throw CalDavError.invalidResponse
    }
    guard let responseURL = httpResponse.url, hasSameOrigin(responseURL, as: requestURL) else {
      throw CalDavError.redirectedToDifferentOrigin
    }
    return httpResponse
  }

  private func calendarReport(
    url: URL,
    username: String,
    appSpecificPassword: String,
    startDate: Date,
    endDate: Date,
  ) async throws -> String {
    var request = URLRequest(url: url)
    request.httpMethod = "REPORT"
    request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.setValue("1", forHTTPHeaderField: "Depth")
    request.setValue(
      "Basic \(Self.basicAuth(username: username, password: appSpecificPassword))",
      forHTTPHeaderField: "Authorization",
    )
    request.httpBody = Self.reportBody(startDate: startDate, endDate: endDate)

    let (data, response) = try await boundedData(for: request)
    let httpResponse = try Self.httpResponse(response, for: url)
    guard (200..<300).contains(httpResponse.statusCode) else {
      let body = Self.errorBody(from: data)
      throw CalDavError.httpStatus(httpResponse.statusCode, body)
    }
    guard let body = String(data: data, encoding: .utf8) else {
      throw CalDavError.invalidUTF8Response
    }
    return body
  }

  private func bootstrapURLs(for rootURL: URL) -> [URL] {
    var candidates = [URL]()
    if var components = URLComponents(url: rootURL, resolvingAgainstBaseURL: false) {
      components.path = "/.well-known/caldav"
      components.query = nil
      components.fragment = nil
      if let wellKnownURL = components.url {
        candidates.append(wellKnownURL)
      }
    }
    candidates.append(rootURL)

    var seen = Set<String>()
    return candidates.filter { candidate in
      guard !seen.contains(candidate.absoluteString) else {
        return false
      }
      seen.insert(candidate.absoluteString)
      return true
    }
  }

  private func discoverCalendarCollections(
    bootstrapURL: URL,
    rootURL: URL,
    credentials: DiscoveryCredentials?,
  ) async throws -> [CalDavCalendarCollection] {
    let principalResponse = try await propfind(
      url: bootstrapURL,
      depth: "0",
      credentials: credentials,
      body: """
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:current-user-principal />
          </d:prop>
        </d:propfind>
        """,
    )

    guard
      let principalURL = try Self.hrefs(
        named: "current-user-principal",
        in: principalResponse.body,
        responseURL: principalResponse.url,
      ).first, Self.isAllowedDiscoveryURL(principalURL, relativeTo: rootURL)
    else {
      throw CalDavError.discoveryFailed("CalDAV server did not return a current user principal.")
    }

    let homeSetResponse = try await propfind(
      url: principalURL,
      depth: "0",
      credentials: credentials,
      body: """
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:prop>
            <c:calendar-home-set />
          </d:prop>
        </d:propfind>
        """,
    )

    let homeURLs = try Self.hrefs(
      named: "calendar-home-set",
      in: homeSetResponse.body,
      responseURL: homeSetResponse.url,
    ).filter { Self.isAllowedDiscoveryURL($0, relativeTo: rootURL) }
    guard !homeURLs.isEmpty else {
      throw CalDavError.discoveryFailed("CalDAV server did not return any calendar homes.")
    }

    var collections = [CalDavCalendarCollection]()
    for homeURL in homeURLs {
      let collectionsResponse = try await propfind(
        url: homeURL,
        depth: "1",
        credentials: credentials,
        body: """
          <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
            <d:prop>
              <d:displayname />
              <d:resourcetype />
            </d:prop>
          </d:propfind>
          """,
      )
      collections.append(contentsOf: try Self.calendarCollections(
        from: collectionsResponse.body,
        responseURL: collectionsResponse.url,
        rootURL: rootURL,
      ))
    }

    return collections
  }

  private func discoveryCredentials(username: String?, password: String?) throws -> DiscoveryCredentials? {
    switch (normalizedText(username), nonEmptySecret(password)) {
    case (let username?, let password?):
      return DiscoveryCredentials(username: username, password: password)
    case (nil, nil):
      return nil
    default:
      throw CalDavError.discoveryFailed("Pass both username and password, or neither for a no-auth discovery attempt.")
    }
  }

  private func propfind(
    url: URL,
    depth: String,
    credentials: DiscoveryCredentials?,
    body: String,
  ) async throws -> (url: URL, body: String) {
    var request = URLRequest(url: url)
    request.httpMethod = "PROPFIND"
    request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
    request.setValue(depth, forHTTPHeaderField: "Depth")
    if let credentials {
      request.setValue(
        "Basic \(Self.basicAuth(username: credentials.username, password: credentials.password))",
        forHTTPHeaderField: "Authorization",
      )
    }
    request.httpBody = Data(body.utf8)

    let (data, response) = try await boundedData(for: request)
    let httpResponse = try Self.httpResponse(response, for: url)
    guard (200..<300).contains(httpResponse.statusCode) else {
      let body = Self.errorBody(from: data)
      throw CalDavError.httpStatus(httpResponse.statusCode, body)
    }
    guard let body = String(data: data, encoding: .utf8) else {
      throw CalDavError.invalidUTF8Response
    }
    return (httpResponse.url ?? url, body)
  }

  private func boundedData(for request: URLRequest) async throws -> (Data, URLResponse) {
    let (bytes, response) = try await session.bytes(for: request)
    if response.expectedContentLength > Int64(Self.maximumResponseBytes) {
      throw CalDavError.responseTooLarge
    }
    var data = Data()
    for try await byte in bytes {
      guard data.count < Self.maximumResponseBytes else {
        throw CalDavError.responseTooLarge
      }
      data.append(byte)
    }
    return (data, response)
  }

}

// MARK: - CalDavRedirectDelegate

private final class CalDavRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
  ) {
    guard
      challenge.previousFailureCount == 0,
      challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
      let authorization = task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
      let encodedCredentials = authorization.split(separator: " ", maxSplits: 1).last,
      let data = Data(base64Encoded: String(encodedCredentials)),
      let credentials = String(data: data, encoding: .utf8),
      let separator = credentials.firstIndex(of: ":")
    else {
      completionHandler(.performDefaultHandling, nil)
      return
    }

    let username = String(credentials[..<separator])
    let password = String(credentials[credentials.index(after: separator)...])
    completionHandler(.useCredential, URLCredential(user: username, password: password, persistence: .none))
  }

  func urlSession(
    _: URLSession,
    task _: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
  ) async -> URLRequest? {
    guard
      let responseURL = response.url,
      let requestURL = request.url,
      CalDavClient.hasSameOrigin(requestURL, as: responseURL)
    else {
      return nil
    }
    return request
  }
}

// MARK: - DiscoveryCredentials

private struct DiscoveryCredentials {
  let username: String
  let password: String
}

// MARK: - XMLNode

extension XMLNode {
  fileprivate func containsNode(named name: String) -> Bool {
    firstNode(named: name) != nil
  }

  fileprivate func firstNode(named name: String) -> XMLNode? {
    if localName == name || self.name == name {
      return self
    }

    for child in children ?? [] {
      if let match = child.firstNode(named: name) {
        return match
      }
    }
    return nil
  }
}

// MARK: - CalDavError

public enum CalDavError: Error, CustomStringConvertible, Equatable {
  case discoveryFailed(String)
  case invalidURL(String)
  case invalidDateRange
  case invalidResponse
  case invalidUTF8Response
  case invalidXMLResponse
  case responseTooLarge
  case redirectedToDifferentOrigin
  case httpStatus(Int, String)

  // MARK: Public

  public var description: String {
    switch self {
    case .discoveryFailed(let message):
      return message
    case .invalidURL(let value):
      return "Invalid CalDAV URL '\(value)'."
    case .invalidDateRange:
      return "Start date must not be after end date."
    case .invalidResponse:
      return "CalDAV server returned an invalid response."
    case .invalidUTF8Response:
      return "CalDAV server response was not valid UTF-8."
    case .invalidXMLResponse:
      return "CalDAV server response was not valid XML."
    case .responseTooLarge:
      return "CalDAV server response was too large."
    case .redirectedToDifferentOrigin:
      return "CalDAV server redirected to a different origin."
    case .httpStatus(let status, let body):
      let sanitizedBody = Self.sanitizedBody(body)
      return sanitizedBody.isEmpty
        ? "CalDAV server returned HTTP \(status)."
        : "CalDAV server returned HTTP \(status): \(sanitizedBody)"
    }
  }

  // MARK: Private

  private static func sanitizedBody(_ body: String) -> String {
    let visibleScalars = body.unicodeScalars.filter { scalar in
      scalar.value >= 0x20
        && scalar.value != 0x7F
        && (scalar.value < 0x80 || scalar.value > 0x9F)
    }
    let sanitized = String(String.UnicodeScalarView(visibleScalars))
    let prefix = String(sanitized.prefix(4096))
    return sanitized.count > 4096 ? "\(prefix)..." : prefix
  }
}

// MARK: - EventComponent

private struct EventComponent {

  // MARK: Lifecycle

  init(rawValue: String) {
    uid = Self.property("UID", in: rawValue)?.value ?? UUID().uuidString
    dtstart = Self.dateProperty("DTSTART", in: rawValue)
    rrule = Self.property("RRULE", in: rawValue)?.value
    recurrenceID = Self.dateProperty("RECURRENCE-ID", in: rawValue)
    exdates = Set(Self.dateProperties("EXDATE", in: rawValue))
    rdates = Self.dateProperties("RDATE", in: rawValue)
    recurrenceTimeZone = Self.property("DTSTART", in: rawValue)
      .flatMap(ICalendarDateParser.timeZone(from:)) ?? CalDavClient.utcCalendar.timeZone
    isCancelled = Self.property("STATUS", in: rawValue)?.value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .caseInsensitiveCompare("CANCELLED") == .orderedSame
    summary = Self.property("SUMMARY", in: rawValue)?.value.icsUnescaped()
    location = Self.property("LOCATION", in: rawValue)?.value.icsUnescaped()
    description = Self.property("DESCRIPTION", in: rawValue)?.value.icsUnescaped()
    duration = Self.eventDuration(in: rawValue)
  }

  // MARK: Internal

  let uid: String
  let dtstart: Date?
  let rrule: String?
  let recurrenceID: Date?
  let exdates: Set<Date>
  let rdates: [Date]
  let recurrenceTimeZone: TimeZone
  let isCancelled: Bool
  let summary: String?
  let location: String?
  let description: String?
  let duration: TimeInterval?

  func occurrence(at startDate: Date, fallbackDuration: TimeInterval? = nil) -> CalDavOccurrence {
    CalDavOccurrence(
      startDate: startDate,
      title: summary,
      location: location,
      notes: description,
      duration: duration ?? fallbackDuration,
    )
  }

  // MARK: Private

  private static func dateProperty(_ name: String, in text: String) -> Date? {
    guard let property = property(name, in: text) else {
      return nil
    }
    return ICalendarDateParser.date(from: property)
  }

  private static func dateProperties(_ name: String, in text: String) -> [Date] {
    properties(name, in: text).flatMap(ICalendarDateParser.dates(from:))
  }

  private static func eventDuration(in text: String) -> TimeInterval? {
    let startProperty = property("DTSTART", in: text)
    let startDate = startProperty.flatMap(ICalendarDateParser.date(from:))
    if
      let endDate = property("DTEND", in: text).flatMap(ICalendarDateParser.date(from:)),
      let startDate
    {
      let duration = endDate.timeIntervalSince(startDate)
      return duration >= 0 ? duration : nil
    }
    if
      let durationProperty = property("DURATION", in: text),
      let duration = ICalendarDurationParser.timeInterval(from: durationProperty.value)
    {
      return duration
    }
    if let startProperty, startDate != nil, !startProperty.value.contains("T") {
      return 24 * 60 * 60
    }
    return nil
  }

  private static func property(_ name: String, in text: String) -> ICalendarProperty? {
    properties(name, in: text).first
  }

  private static func properties(_ name: String, in text: String) -> [ICalendarProperty] {
    text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
      guard line.hasPrefix(name) else {
        return nil
      }

      let rest = line.dropFirst(name.count)
      guard rest.first == ":" || rest.first == ";" else {
        return nil
      }
      guard let separatorIndex = rest.firstIndex(of: ":") else {
        return nil
      }

      return ICalendarProperty(
        parameters: String(rest[..<separatorIndex]),
        value: String(rest[rest.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines),
      )
    }
  }
}

// MARK: - ICalendarDurationParser

private enum ICalendarDurationParser {
  static func timeInterval(from value: String) -> TimeInterval? {
    guard
      let match = value.firstMatch(
        of: #/^P(?:(\d+)W|(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?)$/#
      )
    else {
      return nil
    }

    let components = [match.1, match.2, match.3, match.4, match.5]
    guard components.contains(where: { $0 != nil }) else {
      return nil
    }
    guard !value.contains("T") || components[2...].contains(where: { $0 != nil }) else {
      return nil
    }

    let multipliers: [Int64] = [7 * 24 * 60 * 60, 24 * 60 * 60, 60 * 60, 60, 1]
    var total: Int64 = 0
    for (component, multiplier) in zip(components, multipliers) {
      guard let component else {
        continue
      }
      guard let amount = Int64(component) else {
        return nil
      }
      let (seconds, multiplyOverflow) = amount.multipliedReportingOverflow(by: multiplier)
      guard !multiplyOverflow else {
        return nil
      }
      let (updatedTotal, additionOverflow) = total.addingReportingOverflow(seconds)
      guard !additionOverflow else {
        return nil
      }
      total = updatedTotal
    }
    return TimeInterval(total)
  }
}

// MARK: - ICalendarProperty

private struct ICalendarProperty {
  let parameters: String
  let value: String
}

// MARK: - ICalendarDateParser

/// Parses RFC 5545 iCalendar DATE and DATE-TIME property values used by fields
/// like DTSTART and RECURRENCE-ID. Examples are `20260105` for all-day dates,
/// `20260105T090000Z` for UTC date-times, and `TZID=America/Los_Angeles:
/// 20260105T090000` for date-times tied to an explicit calendar timezone.
private enum ICalendarDateParser {

  // MARK: Internal

  static func date(from property: ICalendarProperty) -> Date? {
    let timeZone = timeZone(from: property.parameters) ?? TimeZone(secondsFromGMT: 0)!
    let value = property.value

    if value.hasSuffix("Z") {
      return formatter(format: "yyyyMMdd'T'HHmmss", timeZone: TimeZone(secondsFromGMT: 0)!)
        .date(from: String(value.dropLast()))
    }

    if value.contains("T") {
      return formatter(format: "yyyyMMdd'T'HHmmss", timeZone: timeZone).date(from: value)
    }

    return formatter(format: "yyyyMMdd", timeZone: timeZone).date(from: value)
  }

  static func dates(from property: ICalendarProperty) -> [Date] {
    property.value.split(separator: ",").compactMap { value in
      date(from: ICalendarProperty(parameters: property.parameters, value: String(value)))
    }
  }

  static func timeZone(from property: ICalendarProperty) -> TimeZone? {
    timeZone(from: property.parameters)
  }

  // MARK: Private

  private static func formatter(format: String, timeZone: TimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = CalDavClient.utcCalendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter
  }

  private static func timeZone(from parameters: String) -> TimeZone? {
    guard let match = parameters.firstMatch(of: #/(?i)TZID="?([^";:]+)"?/#) else {
      return nil
    }

    return TimeZone(identifier: String(match.1))
  }
}

// MARK: - String helpers

extension String {

  // MARK: Fileprivate

  fileprivate func unfoldedICalendarLines() -> String {
    // RFC 5545 line folding continues a logical property line when the next
    // physical line begins with a single space or tab.
    let normalizedLineEndings = normalizingLiteralICalendarLineBreaks()
    return normalizedLineEndings
      .replacingOccurrences(of: "\r\n ", with: "")
      .replacingOccurrences(of: "\r\n\t", with: "")
      .replacingOccurrences(of: "\n ", with: "")
      .replacingOccurrences(of: "\n\t", with: "")
  }

  fileprivate func icsUnescaped() -> String {
    replacingOccurrences(of: "\\n", with: "\n")
      .replacingOccurrences(of: "\\N", with: "\n")
      .replacingOccurrences(of: "\\,", with: ",")
      .replacingOccurrences(of: "\\;", with: ";")
      .replacingOccurrences(of: "\\\\", with: "\\")
  }

  // MARK: Private

  private func normalizingLiteralICalendarLineBreaks() -> String {
    let normalizedCRLF = replacingOccurrences(of: "\\r\\n", with: "\n")
    let normalizedUnicodeLineBreaks = normalizedCRLF.reduce(into: "") { result, character in
      result.append(character.isNewline ? "\n" : character)
    }
    guard !normalizedUnicodeLineBreaks.contains("\n") else {
      return normalizedUnicodeLineBreaks
    }

    // Some CalDAV servers serialize VCALENDAR text with literal `\\n` line
    // separators. Convert only separators followed by an iCalendar property,
    // leaving escaped newlines inside property values untouched.
    return normalizedUnicodeLineBreaks.replacingOccurrences(
      of: #"\\n(?=[A-Za-z-]+(?:;|:))"#,
      with: "\n",
      options: .regularExpression,
    )
  }

}
