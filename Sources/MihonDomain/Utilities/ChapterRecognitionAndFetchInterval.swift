import Foundation

// MARK: - 1:1 Port of Mihon's `ChapterRecognition` (eu.kanade.tachiyomi.util.chapter.ChapterRecognition)

public enum ChapterRecognition {
    private static let numberPattern = #"([0-9]+)(\.[0-9]+)?(\.?[a-z]+)?"#
    private static let basicRegex = try! NSRegularExpression(
        pattern: #"(?:ch\.|chap\.|chapter|第|ep\.|episode)\s*"# + numberPattern,
        options: [.caseInsensitive]
    )
    private static let numberRegex = try! NSRegularExpression(
        pattern: numberPattern,
        options: [.caseInsensitive]
    )
    private static let volumeRegex = try! NSRegularExpression(
        pattern: #"(?:vol\.|v\.|volume|卷)\s*[0-9]+"#,
        options: [.caseInsensitive]
    )
    private static let unwantedWhiteSpaceRegex = try! NSRegularExpression(
        pattern: #"\s+"#
    )

    /// 1:1 replica of Mihon's `parseChapterNumber(mangaTitle, chapterName, chapterNumber)`
    public static func parseChapterNumber(
        mangaTitle: String,
        chapterName: String,
        chapterNumber: Double? = nil
    ) -> Double {
        if let num = chapterNumber, (num == -2.0 || num > -1.0) {
            return num
        }

        var cleanName = chapterName.lowercased()
        let cleanTitle = mangaTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty {
            cleanName = cleanName.replacingOccurrences(of: cleanTitle, with: "")
        }

        cleanName = cleanName
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "-", with: ".")

        // Strip volume prefixes so "Vol. 2 Ch. 15" doesn't parse as chapter 2
        let fullRange = NSRange(cleanName.startIndex..<cleanName.endIndex, in: cleanName)
        cleanName = volumeRegex.stringByReplacingMatches(
            in: cleanName,
            range: fullRange,
            withTemplate: ""
        )

        // 1. Try explicit chapter prefix match ("ch.12", "第24话", "chapter 10.5")
        if let match = basicRegex.firstMatch(
            in: cleanName,
            range: NSRange(cleanName.startIndex..<cleanName.endIndex, in: cleanName)
        ), let parsed = extractFloat(from: match, in: cleanName) {
            return parsed
        }

        // 2. Fallback to first standalone number in cleaned string
        if let match = numberRegex.firstMatch(
            in: cleanName,
            range: NSRange(cleanName.startIndex..<cleanName.endIndex, in: cleanName)
        ), let parsed = extractFloat(from: match, in: cleanName) {
            return parsed
        }

        return -1.0
    }

    private static func extractFloat(from match: NSTextCheckingResult, in text: String) -> Double? {
        guard match.numberOfRanges >= 2,
              let intRange = Range(match.range(at: 1), in: text),
              let major = Int(text[intRange]) else {
            return nil
        }

        var sub: Double = 0.0
        if match.numberOfRanges >= 3,
           let decRange = Range(match.range(at: 2), in: text) {
            let decStr = String(text[decRange])
            sub = Double("0" + decStr) ?? 0.0
        } else if match.numberOfRanges >= 4,
                  let alphaRange = Range(match.range(at: 3), in: text) {
            let alphaStr = String(text[alphaRange]).lowercased()
            if alphaStr.contains("extra") || alphaStr.contains("omake") || alphaStr.contains("special") {
                sub = 0.99
            } else if let firstScalar = alphaStr.replacingOccurrences(of: ".", with: "").unicodeScalars.first,
                      firstScalar.value >= 97 && firstScalar.value <= 106 {
                sub = Double(firstScalar.value - 96) / 10.0
            }
        }
        return Double(major) + sub
    }
}
