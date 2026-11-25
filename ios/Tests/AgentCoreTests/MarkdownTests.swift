import Foundation
import Testing

@testable import AgentCore

@Suite struct MarkdownTests {
  @Test func longFencePreservesShorterFenceInsideCode() {
    let blocks = RichText.parse("````swift\nfirst\n```\nstill code\n````")

    #expect(blocks == [.code("first\n```\nstill code", language: "swift")])
  }

  @Test func tildeFencePreservesInvalidClosersUntilStreamingFinishes() {
    let blocks = RichText.parse("~~~~text\nfirst\n~~~\n```\n~~~~ trailing text\nstill code")

    #expect(
      blocks == [.code("first\n~~~\n```\n~~~~ trailing text\nstill code", language: "text")])
  }

  @Test func escapedTablePipeStaysInItsCell() {
    let blocks = RichText.parse(
      "| A | B |\n| --- | --- |\n| left\\|right | second |\n| `left\\|right` | code |")
    var code = AttributedString("left|right")
    code.inlinePresentationIntent = .code

    #expect(
      blocks == [
        .table([
          [AttributedString("A"), AttributedString("B")],
          [AttributedString("left|right"), AttributedString("second")],
          [code, AttributedString("code")],
        ])
      ])
  }

  @Test func separatorLookingTableDataIsPreserved() {
    let blocks = RichText.parse("| A | B |\n| --- | --- |\n| - | : |")

    #expect(
      blocks == [
        .table([
          [AttributedString("A"), AttributedString("B")],
          [AttributedString("-"), AttributedString(":")],
        ])
      ])
  }

  @Test func pipeDelimitedProseNeedsTableHeaderSeparator() {
    let source = "| just prose |\n| more prose |"

    #expect(RichText.parse(source) == [.prose(AttributedString(source))])
  }

  @Test func emptyTableCellsKeepTheirColumnPositions() {
    let blocks = RichText.parse("| A | B |\n| --- | --- |\n| | second |\n| first | |")

    #expect(
      blocks == [
        .table([
          [AttributedString("A"), AttributedString("B")],
          [AttributedString(""), AttributedString("second")],
          [AttributedString("first"), AttributedString("")],
        ])
      ])
  }

  @Test func inlineStylesAndLinkDestinationsReachTheRenderer() throws {
    let blocks = RichText.parse(
      "Plain *italic* **bold** ***both*** ~~strike~~ `code` [link](https://example.invalid).")
    #expect(blocks.count == 1)
    guard case .prose(let text) = try #require(blocks.first) else {
      Issue.record("Expected inline formatting in a paragraph")
      return
    }

    #expect(String(text.characters) == "Plain italic bold both strike code link.")
    let italic = try #require(text.range(of: "italic"))
    let bold = try #require(text.range(of: "bold"))
    let both = try #require(text.range(of: "both"))
    let strike = try #require(text.range(of: "strike"))
    let code = try #require(text.range(of: "code"))
    let link = try #require(text.range(of: "link"))
    #expect(text[italic].inlinePresentationIntent == .emphasized)
    #expect(text[bold].inlinePresentationIntent == .stronglyEmphasized)
    #expect(text[both].inlinePresentationIntent == [.emphasized, .stronglyEmphasized])
    #expect(text[strike].inlinePresentationIntent == .strikethrough)
    #expect(text[code].inlinePresentationIntent == .code)
    #expect(text[link].link == URL(string: "https://example.invalid"))
    #expect(text.runs.allSatisfy { $0.presentationIntent == nil })
  }

  @Test func listMarkersAndNestingKeepTheirNativeLayoutSemantics() {
    let blocks = RichText.parse(
      "- first\n  - nested\n- last\n\n3. third\n4. fourth\n\n- [x] done\n- [ ] later")

    #expect(
      blocks == [
        .listItem(AttributedString("first"), marker: "•", depth: 0),
        .listItem(AttributedString("nested"), marker: "•", depth: 1),
        .listItem(AttributedString("last"), marker: "•", depth: 0),
        .listItem(AttributedString("third"), marker: "3.", depth: 0),
        .listItem(AttributedString("fourth"), marker: "4.", depth: 0),
        .listItem(AttributedString("[x] done"), marker: "•", depth: 0),
        .listItem(AttributedString("[ ] later"), marker: "•", depth: 0),
      ])
  }

  @Test func paragraphSoftBreaksRemainReadable() {
    let source = "First line.\nSecond line."

    #expect(RichText.parse(source) == [.prose(AttributedString(source))])
  }

  @Test func emptyCodeFenceDoesNotDisplayItsMarkdownDelimiters() {
    #expect(RichText.parse("```swift\n```").isEmpty)
  }

  @Test func listContinuationParagraphDoesNotAddAnotherBullet() {
    let blocks = RichText.parse("- first paragraph\n\n  second paragraph")

    #expect(
      blocks == [
        .listItem(AttributedString("first paragraph"), marker: "•", depth: 0),
        .listItem(AttributedString("second paragraph"), marker: "", depth: 0),
      ])
  }

  @Test func nativeBlockIntentsKeepHeadingsQuotesAndDividers() {
    let blocks = RichText.parse(
      """
      # First #

      ## Second

      ### Third

      #### Fourth

      ##### Fifth

      ###### Sixth

      Setext
      ------

      > First quoted line.
      > Second quoted line.

      * * *
      """)

    #expect(
      blocks == [
        .heading(AttributedString("First"), level: 1),
        .heading(AttributedString("Second"), level: 2),
        .heading(AttributedString("Third"), level: 3),
        .heading(AttributedString("Fourth"), level: 4),
        .heading(AttributedString("Fifth"), level: 5),
        .heading(AttributedString("Sixth"), level: 6),
        .heading(AttributedString("Setext"), level: 2),
        .quote(RichQuote([.prose(AttributedString("First quoted line.\nSecond quoted line."))])),
        .divider,
      ])
  }

  @Test func oneBlockQuoteIsOneQuoteWhateverItHolds() {
    #expect(
      RichText.parse("> Para one.\n>\n> Para two.") == [
        .quote(
          RichQuote([.prose(AttributedString("Para one.")), .prose(AttributedString("Para two."))]))
      ])
    #expect(
      RichText.parse("> First.\n\n> Second.") == [
        .quote(RichQuote([.prose(AttributedString("First."))])),
        .quote(RichQuote([.prose(AttributedString("Second."))])),
      ])
    #expect(
      RichText.parse("> Please bring:\n>\n> - the rope\n> - the tape\n>\n> Thanks.") == [
        .quote(
          RichQuote([
            .prose(AttributedString("Please bring:")),
            .listItem(AttributedString("the rope"), marker: "•", depth: 0),
            .listItem(AttributedString("the tape"), marker: "•", depth: 0),
            .prose(AttributedString("Thanks.")),
          ]))
      ])
    #expect(
      RichText.parse("> Outer level.\n>\n> > Inner nested level.\n>\n> Outer again.") == [
        .quote(
          RichQuote([
            .prose(AttributedString("Outer level.")),
            .quote(RichQuote([.prose(AttributedString("Inner nested level."))])),
            .prose(AttributedString("Outer again.")),
          ]))
      ])
    #expect(
      RichText.parse("> Run this:\n>\n> ```sh\n> echo inside\n> ```\n>\n> Then stop.") == [
        .quote(
          RichQuote([
            .prose(AttributedString("Run this:")),
            .code("echo inside", language: "sh"),
            .prose(AttributedString("Then stop.")),
          ]))
      ])
    #expect(
      RichText.parse("> | a | b |\n> |---|---|\n> | 1 | 2 |") == [
        .quote(
          RichQuote([
            .table([
              [AttributedString("a"), AttributedString("b")],
              [AttributedString("1"), AttributedString("2")],
            ])
          ]))
      ])
  }

  @Test func aQuoteInAListItemIsOneQuoteAtThatItemsDepth() {
    #expect(
      RichText.parse(
        """
        1. Name One

           > Draft for one.

        2. Name Two

           > Draft for two.
           >
           > Second paragraph.
        """) == [
          .listItem(AttributedString("Name One"), marker: "1.", depth: 0),
          .quote(RichQuote([.prose(AttributedString("Draft for one."))]), listItemDepth: 0),
          .listItem(AttributedString("Name Two"), marker: "2.", depth: 0),
          .quote(
            RichQuote([
              .prose(AttributedString("Draft for two.")),
              .prose(AttributedString("Second paragraph.")),
            ]), listItemDepth: 0),
        ])
    #expect(
      RichText.parse("- Outer\n    - Inner\n\n      > Draft for the inner item.") == [
        .listItem(AttributedString("Outer"), marker: "•", depth: 0),
        .listItem(AttributedString("Inner"), marker: "•", depth: 1),
        .quote(
          RichQuote([.prose(AttributedString("Draft for the inner item."))]), listItemDepth: 1),
      ])
    #expect(
      RichText.parse("1. > Draft that opens its item.") == [
        .listItem(AttributedString(), marker: "1.", depth: 0),
        .quote(
          RichQuote([.prose(AttributedString("Draft that opens its item."))]), listItemDepth: 0),
      ])
  }

  @Test func aListInAQuoteHoldsAQuoteAndTheTextAfterItInOneItem() {
    #expect(
      RichText.parse("> 1. Name\n>\n>    > Draft.\n>\n>    After.\n> 2. Two") == [
        .quote(
          RichQuote([
            .listItem(AttributedString("Name"), marker: "1.", depth: 0),
            .quote(RichQuote([.prose(AttributedString("Draft."))]), listItemDepth: 0),
            .listItem(AttributedString("After."), marker: "", depth: 0),
            .listItem(AttributedString("Two"), marker: "2.", depth: 0),
          ]))
      ])
  }

  @Test func textAfterAQuoteThatOpensItsListItemStaysInThatItem() {
    #expect(
      RichText.parse("1. > Opens.\n\n   After.") == [
        .listItem(AttributedString(), marker: "1.", depth: 0),
        .quote(RichQuote([.prose(AttributedString("Opens."))]), listItemDepth: 0),
        .listItem(AttributedString("After."), marker: "", depth: 0),
      ])
  }

  @Test(arguments: [
    ("> Lunch at noon works.", ["Lunch at noon works."]),
    ("> Para one.\n>\n> Para two.", ["Para one.\n\nPara two."]),
    (
      "> Please bring:\n>\n> - the rope\n> - the tape\n>\n> Thanks.",
      ["Please bring:\n\n• the rope\n• the tape\n\nThanks."]
    ),
    (
      "> Steps:\n>\n> 1. first\n>    - inner\n> 2. second",
      ["Steps:\n\n1. first\n    • inner\n2. second"]
    ),
    (
      "> Run this:\n>\n> ```sh\n> echo inside\n> ```\n>\n> Then stop.",
      ["Run this:\n\necho inside\n\nThen stop."]
    ),
    ("> ## Title\n>\n> Body.", ["Title\n\nBody."]),
    (
      "> Outer level.\n>\n> > Inner nested level.\n>\n> Outer again.",
      ["Outer level.\n\n> Inner nested level.\n\nOuter again."]
    ),
    (
      "1. **Name One**\n\n   > Draft for one.\n\n2. **Name Two**\n\n   > Draft for two.\n   >\n   > Second paragraph.",
      ["Draft for one.", "Draft for two.\n\nSecond paragraph."]
    ),
    ("> | a | b |\n> |---|---|\n> | 1 | 2 |", ["a\tb\n1\t2"]),
    (
      "> 1. Name\n>\n>    > Draft.\n>\n>    After.\n> 2. Two",
      ["1. Name\n\n    > Draft.\n\nAfter.\n2. Two"]
    ),
    ("> First.\n\n> Second.", ["First.", "Second."]),
    ("> See [route map](https://example.com/routes/7) now.", ["See route map now."]),
  ])
  func eachQuoteCopiesThePlainTextOfEverythingItHolds(markdown: String, copied: [String]) {
    let quotes = RichText.parse(markdown).compactMap { block -> String? in
      if case .quote(let quote, _) = block { quote.plainText } else { nil }
    }
    #expect(quotes == copied)
  }

  @Test func aQuoteCopiesDividersNestedBlankLinesAndListIndents() {
    let draft = RichQuote([
      .prose(AttributedString("Draft.")), .prose(AttributedString("More.")),
    ])
    #expect(
      RichQuote([.prose(AttributedString("Top.")), .divider, .quote(draft)]).plainText
        == "Top.\n\n---\n\n> Draft.\n>\n> More.")
    #expect(
      RichQuote([
        .listItem(AttributedString("Name"), marker: "1.", depth: 0),
        .quote(draft, listItemDepth: 0),
      ]).plainText == "1. Name\n\n    > Draft.\n    >\n    > More.")
    #expect(
      RichQuote([
        .listItem(AttributedString(), marker: "2.", depth: 1),
        .listItem(AttributedString("continued"), marker: "", depth: 1),
      ]).plainText == "    2.\n    continued")
  }

  @Test func consecutiveBoldReasoningSummariesSeparateCleanlyWithoutDroppingInlineBold() {
    let separated = RichText.separateReasoningSummaries(
      "**Inspecting report status****Reviewing message text**")
    #expect(separated == "**Inspecting report status**\n\n**Reviewing message text**")
    let blocks = RichText.parse(separated)
    #expect(blocks.count == 2)
    if case .prose(let first) = blocks.first, case .prose(let second) = blocks.last {
      #expect(String(first.characters) == "Inspecting report status")
      #expect(String(second.characters) == "Reviewing message text")
      #expect(!String(first.characters).contains("*"))
      #expect(!String(second.characters).contains("*"))
    } else {
      Issue.record("Expected two separate prose blocks: \(blocks)")
    }

    let inline = RichText.separateReasoningSummaries("**Inspecting** the **report** carefully")
    #expect(inline == "**Inspecting** the **report** carefully")

    let fenced = RichText.separateReasoningSummaries(
      "`keep****inline`\n\n```text\nkeep****fenced\n```\n\n****")
    #expect(fenced == "`keep****inline`\n\n```text\nkeep****fenced\n```\n\n****")
  }
}
