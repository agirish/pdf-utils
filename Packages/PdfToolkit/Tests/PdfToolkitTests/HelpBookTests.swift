import Testing
@testable import PdfToolkit

/// Pins the shape of the Help book: unique ids, resolvable cross-links, no empty copy, and one topic
/// per tool wired to the tool's own `helpContent`. The book is hand-maintained data, so these guard
/// the invariants the renderer and `HelpPresenter` rely on.
@Suite struct HelpBookTests {

    @Test func everyTopicIDIsUnique() {
        let ids = HelpBook.allTopics.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyRelatedIDResolvesToARealTopic() {
        for topic in HelpBook.allTopics {
            for relatedID in topic.article.related {
                #expect(HelpBook.topic(id: relatedID) != nil,
                        "Topic \"\(topic.id)\" links to unknown related id \"\(relatedID)\"")
            }
        }
    }

    @Test func noArticleHasEmptyCopy() {
        for topic in HelpBook.allTopics {
            #expect(!topic.title.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!topic.article.intro.trimmingCharacters(in: .whitespaces).isEmpty)
            for block in topic.article.blocks {
                #expect(!block.searchableText.trimmingCharacters(in: .whitespaces).isEmpty,
                        "Empty block in topic \"\(topic.id)\"")
            }
        }
    }

    @Test func everyTopicBelongsToASection() {
        for topic in HelpBook.allTopics {
            #expect(HelpBook.sectionTitle(forTopicID: topic.id) != nil)
        }
    }

    @Test func everyToolHasATopicMatchingItsTitle() {
        for tool in Tool.allCases {
            let topic = HelpBook.topic(id: HelpBook.topicID(for: tool))
            #expect(topic != nil, "No Help topic for tool \(tool.rawValue)")
            #expect(topic?.title == tool.title)
            // The tool article is derived from the tool's own overview.
            #expect(topic?.article.intro == tool.helpContent.overview)
        }
    }

    @Test func emptyQueryReturnsEverySection() {
        #expect(HelpBook.filteredSections(matching: "   ").count == HelpBook.sections.count)
    }

    @Test func searchNarrowsToMatchingTopics() {
        // "password" appears in the Protect tool's copy and nowhere unrelated.
        let hits = HelpBook.filteredSections(matching: "password").flatMap(\.topics)
        #expect(hits.contains { $0.id == HelpBook.topicID(for: .protect) })
        #expect(hits.allSatisfy { $0.matches("password") })
    }

    @Test func searchWithNoMatchReturnsNothing() {
        #expect(HelpBook.filteredSections(matching: "zzzznotatopiczzzz").isEmpty)
    }
}
