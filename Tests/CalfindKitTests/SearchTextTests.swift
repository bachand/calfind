import Testing
@testable import CalfindKit

struct SearchTextTests {

  @Test
  func `matches case-insensitively across fields`() {
    #expect(containsQuery("alice chen", in: ["Planning", nil, "Meet ALICE CHEN at noon"]))
  }

  @Test
  func `matches case-sensitively when requested`() {
    let options = SearchOptions(caseSensitive: true)

    #expect(containsQuery("ALICE CHEN", in: ["Meet ALICE CHEN at noon"], options: options))
    #expect(!containsQuery("alice chen", in: ["Meet ALICE CHEN at noon"], options: options))
  }

  @Test
  func `matches diacritics-insensitively`() {
    #expect(containsQuery("Jose", in: ["Coffee with José"]))
  }

  @Test
  func `does not match missing query`() {
    #expect(!containsQuery("Alice", in: ["Bob", nil, "Carol"]))
  }
}
