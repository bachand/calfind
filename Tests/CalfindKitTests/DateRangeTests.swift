import Foundation
import Testing
@testable import CalfindKit

struct DateRangeTests {

  @Test
  func `parses start and end of local days`() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

    let range = try ClosedRange<Date>(localDateFrom: "2026-01-01", to: "2026-01-03", calendar: calendar)

    let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: range.lowerBound)
    #expect(startComponents.year == 2026)
    #expect(startComponents.month == 1)
    #expect(startComponents.day == 1)
    #expect(startComponents.hour == 0)
    #expect(startComponents.minute == 0)
    #expect(startComponents.second == 0)

    let endComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: range.upperBound)
    #expect(endComponents.year == 2026)
    #expect(endComponents.month == 1)
    #expect(endComponents.day == 3)
    #expect(endComponents.hour == 23)
    #expect(endComponents.minute == 59)
    #expect(endComponents.second == 59)
  }

  @Test
  func `parses start and end of days in a named time zone`() throws {
    let timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone

    let range = try ClosedRange<Date>(localDateFrom: "2026-01-01", to: "2026-01-03", calendar: calendar)

    let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: range.lowerBound)
    #expect(startComponents.year == 2026)
    #expect(startComponents.month == 1)
    #expect(startComponents.day == 1)
    #expect(startComponents.hour == 0)

    let endComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: range.upperBound)
    #expect(endComponents.day == 3)
    #expect(endComponents.hour == 23)
    #expect(endComponents.minute == 59)
  }

  @Test
  func `validates known time zone identifier`() throws {
    let timeZone = try TimeZone(validatingIdentifier: "America/Los_Angeles")
    #expect(timeZone.identifier == "America/Los_Angeles")
  }

  @Test
  func `rejects unknown time zone identifier`() {
    #expect(throws: CalfindValidationError.invalidTimeZone("Not/AZone")) {
      try TimeZone(validatingIdentifier: "Not/AZone")
    }
  }

  @Test
  func `rejects invalid date format`() {
    #expect(throws: CalfindValidationError.invalidDate("2026/01/01")) {
      try ClosedRange<Date>(localDateFrom: "2026/01/01", to: "2026-01-03")
    }
  }

  @Test
  func `rejects impossible date`() {
    #expect(throws: CalfindValidationError.invalidDate("2026-02-31")) {
      try ClosedRange<Date>(localDateFrom: "2026-02-31", to: "2026-03-03")
    }
  }

  @Test
  func `rejects FROM after TO`() {
    #expect(throws: CalfindValidationError.fromAfterTo(from: "2026-03-31", to: "2026-01-01")) {
      try ClosedRange<Date>(localDateFrom: "2026-03-31", to: "2026-01-01")
    }
  }

  @Test
  func `rejects empty query`() {
    #expect(throws: CalfindValidationError.emptyQuery) {
      try SearchQuery("   ")
    }
  }
}
