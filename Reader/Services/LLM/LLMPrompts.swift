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
        imageDensity: DensityLevel?
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
You're helping a thoughtful reader get more from this chapter. Think of yourself as a well-read friend who notices things they might miss.

## The Reader
Reads: Ted Chiang, Three Body Problem, Feynman, Skunk Works, The Martian, QNTM.
Values: Technical accuracy, philosophical depth, surprising connections, the "why" behind things.
Hates: Generic observations, preachy commentary, anything that wastes their time.

## What Makes a Good Insight

GOOD insights bring something from OUTSIDE the text:
- Real science/engineering that illuminates the fiction (or reveals where it diverges)
- Historical events, figures, periods that connect to the text
- Connections to other works, authors, mythology, intellectual traditions
- The philosophical tradition or thought experiment being engaged (name it specifically)
- In-universe implications the author left unstated (fiction only)

BAD insights explain what the story already told us:
- Restating the plot's central mechanism ("The twist reveals X" - we read the twist)
- Explaining why a character did something when the text made it clear
- Noting the obvious stakes or conflict
- Any insight an attentive reader would have on their own

The test: Does this require knowledge or perspective the TEXT ITSELF doesn't provide?
- If you're explaining what happened → bad
- If you're connecting it to something external → potentially good

## Examples

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

OBVIOUS (equally bad):
{
  "type": "science",
  "title": "Why FTL was necessary",
  "content": "The story shows that without faster-than-light travel, the crew couldn't reach their destination in time. This is why the ending works."
}
This fails because the story ITSELF made this clear. The reader understood it. You're explaining the punchline.

## The Chapter

Context: \(rollingSummary ?? "This is the beginning of the book.")

Text (blocks numbered for margin placement):
\(contentWithBlocks)

## Output

Generate insights. Density: \(insightDensity.insightGuidance)

For each:
- type: science | history | philosophy | connection | world
- title: Specific and intriguing
- content: Add real information or a genuine new perspective
- sourceBlockId: Where should this appear in the margin? The insight can reference anything—other passages, external knowledge, broad themes—the block ID is just placement, indicating where the reader would benefit from seeing this note.

Quality bar: The reader should learn something they COULDN'T have gotten from the text alone.
- "I didn't know that" (external fact)
- "I didn't make that connection" (to other works/ideas)

If they could have figured it out just by reading carefully, skip it.

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
You're discussing this chapter with a reader.

Context: \(rollingSummary ?? "Beginning of book.")

Chapter:
\(contentWithBlocks)

Question:
"""
        let suffix = """
"\(message)"

Answer using the text and your knowledge. Be substantive and direct. If they ask about future events, say you can only discuss through this chapter.
"""

        return LLMRequestPrompt(cachePrefix: prefix, cacheSuffix: suffix)
    }

    // MARK: - Streaming Chat

    static func chatStreamingPrompt(
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

    // MARK: - Word/Concept Explanation

    static func explainWordPrompt(
        word: String,
        context: String,
        rollingSummary: String?
    ) -> LLMRequestPrompt {
        let prompt = """
Reader clicked "\(word)" in:

"\(context)"

Context: \(rollingSummary ?? "Beginning of book.")

Explain in 2-3 sentences. They're smart and curious. No spoilers.
"""
        return LLMRequestPrompt(text: prompt)
    }

    static func explainWordChatPrompt(word: String, context: String) -> String {
        """
Explain "\(word)" in this context. 2-3 sentences, no spoilers.

"\(context)"
"""
    }

    // MARK: - Image Prompt

    static func imagePrompt(word: String, context: String) -> LLMRequestPrompt {
        let prompt = """
Generate an image prompt for the scene around "\(word)":

"\(context)"

Single vivid prompt. Include setting, lighting, atmosphere, key elements, suggested style. Ground it in what the text describes.
"""
        return LLMRequestPrompt(text: prompt)
    }

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
Formulate the single most effective Google search query to find primary sources or deeper context for this literary insight.

Book: "\(bookTitle)" by \(author)
Insight: "\(insightTitle)"
Detail: "\(insightContent)"

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
