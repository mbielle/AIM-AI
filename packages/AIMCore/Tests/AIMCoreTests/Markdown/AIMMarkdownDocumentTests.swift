import XCTest
@testable import AIMCore

final class AIMMarkdownDocumentTests: XCTestCase {
    func testRepairsMissingGFMTableDelimiter() {
        let source = """
        | Name | State |
        | Bridge | Online |
        """
        let result = AIMMarkdownNormalizer.normalize(source)
        XCTAssertEqual(result, "| Name | State |\n| --- | --- |\n| Bridge | Online |")
    }

    func testRepairsBrokenDelimiterAndKeepsCodeUntouched() {
        let source = """
        | A | B |
        |
        | 1 | 2 |

        ```md
        | not | a |
        | table | here |
        ```
        """
        let result = AIMMarkdownNormalizer.normalize(source)
        XCTAssertTrue(result.contains("| A | B |\n| --- | --- |\n| 1 | 2 |"))
        XCTAssertTrue(result.contains("```md\n| not | a |\n| table | here |\n```"))
    }

    func testNormalizesHeadingsListsMathAndUnicode() {
        let source = """
        ##Heading
        • Élément
        4) Suite
        \\[x^2 + y^2\\]
        """
        let result = AIMMarkdownNormalizer.normalize(source)
        XCTAssertTrue(result.contains("## Heading"))
        XCTAssertTrue(result.contains("- Élément"))
        XCTAssertTrue(result.contains("1. Suite"))
        XCTAssertTrue(result.contains("$$\nx^2 + y^2\n$$"))
    }

    func testUnsafeHTMLIsRemovedAndReported() {
        let source = "Hello <script>alert('x')</script><iframe src=\"https://evil.example\"></iframe> world"
        let document = AIMMarkdownDocument(source: source)
        XCTAssertTrue(document.containsUnsafeHTML)
        XCTAssertFalse(document.normalizedSource.localizedCaseInsensitiveContains("script"))
        XCTAssertFalse(document.normalizedSource.localizedCaseInsensitiveContains("iframe"))
        XCTAssertTrue(document.nodeCount > 0)
    }

    func testUnsupportedMathRemainsDetectableForTextFallback() {
        XCTAssertFalse(AIMMathValidation.isRenderable("\\definitelyUnsupported{broken"))
        XCTAssertTrue(AIMMathValidation.isRenderable("x = \\frac{1}{2}"))
    }

    func testGFMDocumentBuildsSharedASTBlocks() {
        let source = """
        # Result

        > Verified on the computer.

        - **First**
        - ~~Second~~

        | File | State |
        | --- | --- |
        | `App.swift` | Ready |

        ```swift
        print("ready")
        ```
        """

        let blocks = AIMMarkdownDocument(source: source).blocks
        XCTAssertTrue(blocks.contains(.heading(level: 1, text: "Result")))
        XCTAssertTrue(blocks.contains { block in
            guard case let .quote(text) = block else { return false }
            return text.contains("Verified on the computer")
        })
        XCTAssertTrue(blocks.contains { block in
            guard case let .unorderedList(items) = block else { return false }
            let text = items.joined(separator: " ")
            return text.contains("First") && text.contains("Second")
        })
        XCTAssertTrue(blocks.contains(.table(headers: ["File", "State"], rows: [["`App.swift`", "Ready"]])))
        XCTAssertTrue(blocks.contains(.code(language: "swift", content: "print(\"ready\")")))
    }

    func testNestedListsPreserveTheirRecursiveStructure() {
        let blocks = AIMMarkdownDocument(source: """
        - Parent
          1. First child
          2. Second child
             - Grandchild
        - Sibling
        """).blocks

        guard case let .list(.unordered(items)) = blocks.first else {
            return XCTFail("A recursive unordered list was expected")
        }
        XCTAssertEqual(items.map(\.text), ["Parent", "Sibling"])
        guard case let .ordered(children) = items[0].children.first else {
            return XCTFail("The ordered child list must be retained")
        }
        XCTAssertEqual(children.map(\.text), ["First child", "Second child"])
        guard case let .unordered(grandchildren) = children[1].children.first else {
            return XCTFail("The grandchild list must be retained")
        }
        XCTAssertEqual(grandchildren.map(\.text), ["Grandchild"])
    }

    func testListItemsKeepSingleSpaceAfterBoldLeadIn() {
        let source = "1. **Réduire la taille** : Moins de mémoire.  \n2. **Accélérer** : Les *calculs* `int8`.  "
        guard case .orderedList(let items) = AIMMarkdownDocument(source: source).blocks.first else {
            return XCTFail("Expected an ordered list")
        }
        XCTAssertEqual(items, ["**Réduire la taille** : Moins de mémoire.", "**Accélérer** : Les *calculs* `int8`."])
    }
}
