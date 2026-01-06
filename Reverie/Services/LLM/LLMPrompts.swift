import Foundation

struct LLMRequestPrompt {
    let text: String
    let cachePrefix: String?
    let cacheSuffix: String?

    init(text: String) {
        self.text = text
        self.cachePrefix = nil
        self.cacheSuffix = nil
    }

    init(cachePrefix: String, cacheSuffix: String) {
        self.cachePrefix = cachePrefix
        self.cacheSuffix = cacheSuffix
        self.text = cachePrefix + cacheSuffix
    }
}

enum PromptLibrary {

    // MARK: - Chapter Analysis

    static func analysisPrompt(
        contentWithBlocks: String,
        rollingSummary: String?,
        insightDensity: DensityLevel,
        imageDensity: DensityLevel?,
        wordCount: Int
    ) -> LLMRequestPrompt {

        let imageSection: String
        if let imageDensity {
            imageSection = """

## Images (\(imageDensity.imageGuidance))
Suggest scenes worth visualizing:
- Striking visuals: ships, architecture, creatures, landscapes, key objects
- Moments with distinctive atmosphere
- Spatial layouts that help understanding

Each needs:
- excerpt: a verbatim excerpt from the chapter, long enough to capture the scene (2-6 sentences or more if needed). Use contiguous text only. No paraphrase, no added words, no [N] labels.
- sourceBlockId: block number [N] where the excerpt starts (if it spans multiple blocks, use the first).
Skip if nothing merits visualization.
"""
        } else {
            imageSection = ""
        }

        let prompt = """
## The Chapter

Context: \(rollingSummary ?? "This is the beginning of the book.")

Text (blocks numbered for margin placement):
\(contentWithBlocks)

---

## What You're Looking For

Insights that bring knowledge from OUTSIDE the text. Be specific—names, dates, sources.

**Science/Engineering**
- Real physics, biology, chemistry, engineering that illuminates or contradicts the fiction
- Specific: "Bussard ramjets were proposed by Robert Bussard in 1960 using interstellar hydrogen..."
- Not: "The science in this chapter is interesting"

**History**
- Actual events, figures, periods that connect to the narrative
- Specific: "The political situation mirrors the Weimar Republic's final years, when..."
- Not: "This has historical parallels"

**Philosophy**
- Named thought experiments, philosophical traditions, specific thinkers
- Specific: "This is essentially Newcomb's problem, formulated by William Newcomb in 1960..."
- Not: "Raises questions about free will"

**Connections**
- Specific other works, authors, mythological traditions
- Specific: "Borges' 'The Garden of Forking Paths' (1941) explores identical territory..."
- Not: "Echoes other science fiction"

**World-Building** (fiction only)
- In-universe implications the author left unstated
- Must require inference beyond what's explicitly on the page

---

## The Quality Bar

The test: Does this require knowledge the TEXT ITSELF doesn't provide?

EXCELLENT:
{
  "type": "science",
  "title": "The orbital mechanics are backwards",
  "content": "The described trajectory would require accelerating toward Earth, not away. Hard sci-fi usually gets this right—the 'error' might be intentional, suggesting the drive works on principles we don't understand yet.",
  "sourceBlockId": 7
}

{
  "type": "connection",
  "title": "Borges wrote this exact scenario",
  "content": "The Garden of Forking Paths explores the same premise—every decision spawns a universe. But where Borges treats it as metaphysical horror, this author frames it as liberation. The inversion is probably deliberate.",
  "sourceBlockId": 23
}

GENERIC (never do this):
{
  "type": "philosophy",
  "title": "Questions of identity",
  "content": "The author explores themes of identity and what it means to be human."
}
→ Fails: vague, could apply to any book, names nothing specific

OBVIOUS (equally bad):
{
  "type": "science",
  "title": "Why FTL was necessary",
  "content": "The story shows that without faster-than-light travel, the crew couldn't reach their destination in time."
}
→ Fails: the reader understood this from the text

---

## Your Approach

Use your thinking to work through this systematically:

1. **SCAN**: Read the chapter and identify 10-15 moments where external knowledge would genuinely illuminate the text—scientific claims, historical parallels, philosophical positions, literary echoes.

2. **EVALUATE**: For each candidate, ask: "Could an attentive reader figure this out from the text alone?" If yes, discard it.

3. **RESEARCH**: For survivors, recall the specific external knowledge. Not "this relates to philosophy" but the actual names, dates, works, and facts.

4. **GENERATE**: Only output insights that bring genuinely external knowledge. Be specific. Name names. If you can't be specific, skip it.

\(insightDensity.proportionalGuidance(wordCount: wordCount))

---

## Output

For each insight:
- type: science | history | philosophy | connection | world
- title: Specific and intriguing (not generic)
- content: Real information with specifics—names, dates, works
- sourceBlockId: Block number [N] where this should appear in the margin

## Quiz

Questions testing understanding, not memory:
- Why did X happen? (causality)
- What would happen if Y? (prediction)
- How does A connect to B? (synthesis)

Bad: "What color was the ship?"
Good: "Given what we know about her past, why might she have made this choice?"

Each: question, answer, sourceBlockId.
\(imageSection)
## Summary
2-3 sentences: what happened and what matters for understanding the rest.
"""

        return LLMRequestPrompt(text: prompt)
    }

    // MARK: - Summary Only

    static func summaryPrompt(
        contentWithBlocks: String,
        rollingSummary: String?
    ) -> LLMRequestPrompt {
        let prompt = """
Summarize this chapter in 2-3 sentences: what happened and what matters for understanding the rest.

Context: \(rollingSummary ?? "This is the beginning of the book.")

Chapter:
\(contentWithBlocks)
"""
        return LLMRequestPrompt(text: prompt)
    }

    // MARK: - More Insights

    static func moreInsightsPrompt(
        contentWithBlocks: String,
        rollingSummary: String?,
        existingTitles: [String],
        insightDensity: DensityLevel
    ) -> LLMRequestPrompt {
        let existingList = existingTitles.isEmpty
            ? "None yet"
            : existingTitles.map { "- \($0)" }.joined(separator: "\n")

        let prefix = """
Generate additional insights. Already covered:
\(existingList)

Context: \(rollingSummary ?? "Beginning of book.")

Text:
"""
        let suffix = """
\(contentWithBlocks)

Find what was missed:
- Science/tech angles
- Historical parallels
- Philosophical questions
- Connections to other works
- World-building implications

Density: \(insightDensity.insightGuidance)
Each: type, title, content, sourceBlockId.

Only include insights requiring knowledge OUTSIDE the text. If a reader could figure it out by reading carefully, skip it.
"""

        return LLMRequestPrompt(cachePrefix: prefix, cacheSuffix: suffix)
    }

    // MARK: - More Questions

    static func moreQuestionsPrompt(
        contentWithBlocks: String,
        rollingSummary: String?,
        existingQuestions: [String]
    ) -> LLMRequestPrompt {
        let existingList = existingQuestions.isEmpty
            ? "None yet"
            : existingQuestions.map { "- \($0)" }.joined(separator: "\n")

        let prefix = """
Generate additional quiz questions. Already covered:
\(existingList)

Context: \(rollingSummary ?? "Beginning of book.")

Text:
"""
        let suffix = """
\(contentWithBlocks)

Good questions:
- Causality and consequences
- Prediction from evidence
- Synthesis across events
- Character motivation

NOT trivia, names, or ctrl+F-able facts.

Each: question, answer, sourceBlockId.
"""

        return LLMRequestPrompt(cachePrefix: prefix, cacheSuffix: suffix)
    }

    // MARK: - Chat

    static func chatPrompt(
        message: String,
        contentWithBlocks: String,
        rollingSummary: String?
    ) -> LLMRequestPrompt {
        let prefix = """
Discussing this chapter with a reader.

Story so far: \(rollingSummary ?? "Beginning of book.")

Chapter:
\(contentWithBlocks)

Question:
"""
        let suffix = """
"\(message)"

Be substantive:
- Science/history: give real information
- Story questions: analyze with evidence
- Confusion: clarify without condescension

No spoilers beyond this chapter.
"""

        return LLMRequestPrompt(cachePrefix: prefix, cacheSuffix: suffix)
    }

    static func explainWordChatPrompt(word: String, context: String) -> String {
        """
Explain "\(word)" in this context. 2-3 sentences, no spoilers.

"\(context)"
"""
    }

    // MARK: - Image Prompt

    static func imagePromptFromExcerpt(_ excerpt: String, rewrite: Bool) -> String {
        let header: String
        if rewrite {
            header = """
Before generating, rewrite the excerpt into a concise, vivid image prompt for yourself. Then generate the image from that rewritten prompt. Do not add elements that aren’t described or clearly implied.
"""
        } else {
            header = "Generate an image based strictly on this excerpt from a book. Do not add elements that aren’t described or clearly implied."
        }
        return """
\(header)

Excerpt:
\"\"\"
\(excerpt)
\"\"\"
"""
    }

    // MARK: - Search Query Distillation

    static func distillSearchQueryPrompt(
        insightTitle: String,
        insightContent: String,
        bookTitle: String,
        author: String
    ) -> LLMRequestPrompt {
        let prompt = """
A reader just finished reading a literary insight and clicked "search" to learn more. They might want to:
- Explore topic, connections, and philosophical implications
- Verify factual claims or get technical details
- Find discussion, analysis, or deeper context

Book: "\(bookTitle)" by \(author)
Insight: "\(insightTitle)"
Detail: "\(insightContent)"

Formulate a Google search query that serves these purposes well.

Good queries work for BOTH exploration and verification:
- "Procyon star system white dwarf energy"
- "lunar regolith oxygen silicon semiconductor fabrication"
- "Nick Bostrom simulation argument counterarguments"

Avoid:
- site: restrictions
- Overly narrow or technical jargon-only queries
- Queries that would return 0 results

The query should be discoverable enough to surface content AND specific enough to be relevant.

Output ONLY the search query text. No quotes, no preamble.
"""
        return LLMRequestPrompt(text: prompt)
    }

    // MARK: - Chapter Classification

    static func chapterClassificationPrompt(
        chapters: [(index: Int, title: String, preview: String)]
    ) -> LLMRequestPrompt {
        var chapterList = ""
        for chapter in chapters {
            let words = chapter.preview.split(separator: " ").prefix(200)
            let truncatedPreview = words.joined(separator: " ")
            chapterList += """
[\(chapter.index)] "\(chapter.title)"
\(truncatedPreview)

"""
        }

        let prompt = """
Classify each chapter as content or garbage.

Content: Actual story, substantive introductions, meaningful prologues/epilogues.
Garbage: Title pages, copyright, TOC, acknowledgements, about the author, empty chapters.

Lean toward "content" when unsure.

\(chapterList)

Return one classification per index.
"""

        return LLMRequestPrompt(text: prompt)
    }
}
