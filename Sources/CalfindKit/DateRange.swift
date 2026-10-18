import Foundation

// MARK: - CalfindValidationError

public enum CalfindValidationError: Error, Equatable, CustomStringConvertible {
  case invalidDate(String)
  case fromAfterTo(from: String, to: String)
  case invalidTimeZone(String)
  case emptyQuery

  public var description: String {
    switch self {
    case .invalidDate(let value):
      "Invalid date '\(value)'. Use YYYY-MM-DD."
    case .fromAfterTo(let from, let to):
      "FROM date \(from) must not be after TO date \(to)."
    case .invalidTimeZone(let value):
      "Invalid time zone '\(value)'. Use an IANA identifier such as America/Los_Angeles."
    case .emptyQuery:
      "QUERY must not be empty."
    }
  }
}

// MARK: - TimeZone

extension TimeZone {

  /// Creates a time zone from an IANA identifier such as `America/Los_Angeles`.
  /// Throws `CalfindValidationError.invalidTimeZone` when the identifier is unknown.
  public init(validatingIdentifier identifier: String) throws {
    guard let timeZone = TimeZone(identifier: identifier) else {
      throw CalfindValidationError.invalidTimeZone(identifier)
    }

    self = timeZone
  }
}

// MARK: - SearchQuery

public struct SearchQuery: Equatable {

  // MARK: Lifecycle

  public init(_ value: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CalfindValidationError.emptyQuery
    }

    self.value = value
  }

  // MARK: Public

  public let value: String
}

// MARK: - ClosedRange where Bound == Date

extension ClosedRange where Bound == Date {

  // MARK: Lifecycle

  public init(localDateFrom fromText: String, to toText: String, calendar: Calendar = .current) throws {
    guard let fromComponents = Self.components(from: fromText, calendar: calendar) else {
      throw CalfindValidationError.invalidDate(fromText)
    }
    guard let toComponents = Self.components(from: toText, calendar: calendar) else {
      throw CalfindValidationError.invalidDate(toText)
    }
    guard
      let start = calendar.date(from: fromComponents),
      let toStart = calendar.date(from: toComponents),
      let nextDay = calendar.date(byAdding: .day, value: 1, to: toStart),
      let end = calendar.date(byAdding: .second, value: -1, to: nextDay)
    else {
      throw CalfindValidationError.invalidDate("\(fromText) or \(toText)")
    }
    guard start <= end else {
      throw CalfindValidationError.fromAfterTo(from: fromText, to: toText)
    }

    self = start...end
  }

  // MARK: Private

  private static func components(from value: String, calendar: Calendar) -> DateComponents? {
    let pattern = #"^\d{4}-\d{2}-\d{2}$"#
    guard value.range(of: pattern, options: .regularExpression) != nil else {
      return nil
    }

    let parts = value.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else {
      return nil
    }

    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = parts[0]
    components.month = parts[1]
    components.day = parts[2]

    guard let date = components.date else {
      return nil
    }

    let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
    guard
      roundTrip.year == components.year,
      roundTrip.month == components.month,
      roundTrip.day == components.day
    else {
      return nil
    }

    return components
  }
}
