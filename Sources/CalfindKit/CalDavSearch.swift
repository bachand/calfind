import Foundation

// MARK: - CalDavSearch

public struct CalDavSearch {

  // MARK: Lifecycle

  public init(client: CalDavClient = CalDavClient()) {
    self.client = client
  }

  // MARK: Public

  public let client: CalDavClient

  public func occurrences(
    credentials: CalDavCredentials,
    query: SearchQuery,
    range: ClosedRange<Date>,
    options: SearchOptions = .default,
  ) async throws -> [CalDavOccurrence] {
    try await client.occurrences(
      url: credentials.url,
      username: credentials.username,
      appSpecificPassword: credentials.password,
      startDate: range.lowerBound,
      endDate: range.upperBound,
    )
    .filter {
      containsQuery(
        query.value,
        in: [$0.title, $0.location, $0.notes],
        options: options,
      )
    }
    .sorted { lhs, rhs in
      if lhs.startDate == rhs.startDate {
        return (lhs.title ?? "").localizedCaseInsensitiveCompare(rhs.title ?? "") == .orderedAscending
      }
      return lhs.startDate < rhs.startDate
    }
  }
}
