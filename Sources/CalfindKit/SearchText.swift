import Foundation

// MARK: - SearchOptions

public struct SearchOptions: Equatable, Sendable {
  public init(caseSensitive: Bool = false) {
    self.caseSensitive = caseSensitive
  }

  public static let `default` = SearchOptions(caseSensitive: false)

  public let caseSensitive: Bool

}

// MARK: - containsQuery

public func containsQuery(
  _ query: String,
  in fields: [String?],
  options: SearchOptions = .default,
) -> Bool {
  let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmedQuery.isEmpty else {
    return false
  }

  let compareOptions: String.CompareOptions = options.caseSensitive
    ? [.diacriticInsensitive]
    : [.caseInsensitive, .diacriticInsensitive]

  return fields.contains { field in
    guard let field else {
      return false
    }
    return field.range(of: trimmedQuery, options: compareOptions) != nil
  }
}
