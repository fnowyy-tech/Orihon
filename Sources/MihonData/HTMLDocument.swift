import Foundation

// MARK: - HTML parsing for source scrapers
//
// Keiyoushi's HTML extensions read pages with jsoup: parse, `select(css)`, `text()`, `ownText()`, `attr("abs:…")`.
// This is that subset — a forgiving tree builder (unclosed and stray tags, optional end tags, raw-text elements,
// entities) and a CSS selector engine — so HTML sources port 1:1 without a third-party dependency.
//
// Nodes live in one array owned by the document; an `HTMLElement` is a (document, index) handle, so elements keep
// their document alive and parent links never form reference cycles.

public final class HTMLDocument {
    struct Node {
        enum Content {
            case element(Int)
            case text(String)
        }

        var tag: String
        var attributes: [String: String]
        var classes: Set<String>
        var parent: Int
        var children: [Int] = []
        var content: [Content] = []
        /// Position among the parent's element children.
        var siblingIndex = 0
        /// The raw content of a `<script>` or `<style>`, which is not text (jsoup `DataNode`).
        var data = ""
    }

    private(set) var nodes: [Node]
    public let baseURL: URL?

    public init(html: String, baseURL: URL? = nil) {
        self.baseURL = baseURL
        var builder = HTMLTreeBuilder()
        builder.parse(Array(html.utf8))
        nodes = builder.nodes
    }

    /// The document itself (no tag); `select` on it searches every element.
    public var root: HTMLElement { HTMLElement(document: self, index: 0) }

    public func select(_ query: String) -> [HTMLElement] { root.select(query) }
    public func selectFirst(_ query: String) -> HTMLElement? { root.selectFirst(query) }
}

public struct HTMLElement {
    let document: HTMLDocument
    let index: Int

    public var tag: String { document.nodes[index].tag }
    public var children: [HTMLElement] { document.nodes[index].children.map { HTMLElement(document: document, index: $0) } }
    public var parent: HTMLElement? {
        let parent = document.nodes[index].parent
        return parent > 0 ? HTMLElement(document: document, index: parent) : nil
    }

    /// The attribute's value, or "" (jsoup `attr`). `abs:name` resolves it against the document URL.
    public func attr(_ name: String) -> String {
        let key = name.lowercased()
        if key.hasPrefix("abs:") { return absUrl(String(key.dropFirst(4))) }
        return document.nodes[index].attributes[key] ?? ""
    }

    public func hasAttr(_ name: String) -> Bool { document.nodes[index].attributes[name.lowercased()] != nil }

    /// The attribute as an absolute URL (protocol-relative and relative links resolved), or "".
    public func absUrl(_ name: String) -> String {
        let value = (document.nodes[index].attributes[name.lowercased()] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        let candidates = [value, value.addingPercentEncoding(withAllowedCharacters: Self.urlAllowed) ?? value]
        for candidate in candidates {
            if let url = URL(string: candidate, relativeTo: document.baseURL), url.scheme != nil {
                return url.absoluteString
            }
        }
        return value
    }

    private static let urlAllowed = CharacterSet.urlQueryAllowed.union(.urlPathAllowed).union(CharacterSet(charactersIn: "#%"))

    /// Text of the element and its descendants with whitespace collapsed (jsoup `text()`). Walked with an explicit
    /// stack: unclosed tags can nest pages deeper than the call stack allows.
    public var text: String {
        enum Work {
            case content(HTMLDocument.Node.Content)
            case space
        }
        var out = ""
        var stack = document.nodes[index].content.reversed().map(Work.content)
        while let work = stack.popLast() {
            switch work {
            case .space:
                out += " "
            case .content(.text(let text)):
                out += text
            case .content(.element(let child)):
                let tag = document.nodes[child].tag
                if tag == "br" || HTMLTreeBuilder.blockTags.contains(tag) {
                    out += " "
                    stack.append(.space)
                }
                stack.append(contentsOf: document.nodes[child].content.reversed().map(Work.content))
            }
        }
        return Self.normalize(out)
    }

    /// The raw content of a `<script>` or `<style>` element (jsoup `data()`); empty for other elements.
    public var data: String { document.nodes[index].data }

    /// Text of the element's own text nodes only (jsoup `ownText()`).
    public var ownText: String {
        var out = ""
        for item in document.nodes[index].content {
            switch item {
            case .text(let text): out += text
            case .element(let child) where document.nodes[child].tag == "br": out += " "
            case .element: break
            }
        }
        return Self.normalize(out)
    }

    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "\u{00A0}" }).joined(separator: " ")
    }

    // MARK: Selectors

    /// This element (as jsoup does) and its descendants matching the CSS query, in document order (jsoup
    /// `select`). A query outside the supported subset matches nothing.
    public func select(_ query: String) -> [HTMLElement] {
        guard let selectors = parse(query) else { return [] }
        var result: [HTMLElement] = []
        var stack = index > 0 ? [index] : Array(document.nodes[index].children.reversed())
        while let node = stack.popLast() {
            if selectors.contains(where: { matches(node, $0) }) {
                result.append(HTMLElement(document: document, index: node))
            }
            stack.append(contentsOf: document.nodes[node].children.reversed())
        }
        return result
    }

    public func selectFirst(_ query: String) -> HTMLElement? {
        guard let selectors = parse(query) else { return nil }
        var stack = index > 0 ? [index] : Array(document.nodes[index].children.reversed())
        while let node = stack.popLast() {
            if selectors.contains(where: { matches(node, $0) }) {
                return HTMLElement(document: document, index: node)
            }
            stack.append(contentsOf: document.nodes[node].children.reversed())
        }
        return nil
    }

    private func parse(_ query: String) -> [CSSSelector]? {
        do {
            return try CSSSelectorParser.parse(query)
        } catch {
            #if DEBUG
            print("HTMLDocument: unsupported CSS selector \(query)")
            #endif
            return nil
        }
    }

    private func matches(_ node: Int, _ selector: CSSSelector) -> Bool {
        matches(node, selector, selector.compounds.count - 1)
    }

    /// Right-to-left: the last compound must match `node`, the rest its ancestors / previous siblings.
    private func matches(_ node: Int, _ selector: CSSSelector, _ position: Int) -> Bool {
        guard matchesCompound(node, selector.compounds[position]) else { return false }
        guard position > 0 else { return true }
        let nodes = document.nodes
        switch selector.combinators[position - 1] {
        case .child:
            let parent = nodes[node].parent
            return parent > 0 && matches(parent, selector, position - 1)
        case .descendant:
            var ancestor = nodes[node].parent
            while ancestor > 0 {
                if matches(ancestor, selector, position - 1) { return true }
                ancestor = nodes[ancestor].parent
            }
            return false
        case .adjacent:
            guard let previous = previousSibling(of: node) else { return false }
            return matches(previous, selector, position - 1)
        case .sibling:
            let siblings = nodes[nodes[node].parent].children
            return siblings[..<nodes[node].siblingIndex].contains { matches($0, selector, position - 1) }
        }
    }

    private func previousSibling(of node: Int) -> Int? {
        let siblingIndex = document.nodes[node].siblingIndex
        guard siblingIndex > 0 else { return nil }
        return document.nodes[document.nodes[node].parent].children[siblingIndex - 1]
    }

    private func matchesCompound(_ node: Int, _ compound: CSSCompound) -> Bool {
        let element = document.nodes[node]
        if let tag = compound.tag, element.tag != tag { return false }
        if let id = compound.id, element.attributes["id"] != id { return false }
        // Classes are stored and queried lowercased: jsoup matches them case-insensitively.
        for name in compound.classes where !element.classes.contains(name) { return false }
        for condition in compound.attributes where !condition.matches(element.attributes[condition.name]) { return false }
        for pseudo in compound.pseudos where !matchesPseudo(node, pseudo) { return false }
        return true
    }

    private func matchesPseudo(_ node: Int, _ pseudo: CSSPseudo) -> Bool {
        let nodes = document.nodes
        let siblings = nodes[nodes[node].parent].children
        let position = nodes[node].siblingIndex
        switch pseudo {
        case .not(let selectors):
            return !selectors.contains { matches(node, $0) }
        case .has(let selectors):
            let element = HTMLElement(document: document, index: node)
            return selectors.contains { selector in
                var stack = nodes[node].children
                while let child = stack.popLast() {
                    if element.matches(child, selector) { return true }
                    stack.append(contentsOf: nodes[child].children)
                }
                return false
            }
        case .indexEquals(let n):
            return position == n
        case .indexLess(let n):
            return position < n
        case .indexGreater(let n):
            return position > n
        case .nthChild(let n):
            return position + 1 == n
        case .nthOfType(let n):
            return siblings[...position].filter { nodes[$0].tag == nodes[node].tag }.count == n
        case .firstChild:
            return position == 0
        case .lastChild:
            return position == siblings.count - 1
        case .firstOfType:
            return !siblings[..<position].contains { nodes[$0].tag == nodes[node].tag }
        case .lastOfType:
            return !siblings[(position + 1)...].contains { nodes[$0].tag == nodes[node].tag }
        case .contains(let needle):
            return HTMLElement(document: document, index: node).text.lowercased().contains(needle)
        case .containsOwn(let needle):
            return HTMLElement(document: document, index: node).ownText.lowercased().contains(needle)
        }
    }
}

// MARK: - Tree builder

struct HTMLTreeBuilder {
    static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"
    ]
    /// Elements whose content is not markup. Script and style content is dropped (jsoup keeps it out of `text()`).
    static let rawTextTags: Set<String> = ["script", "style", "textarea", "title", "xmp"]
    static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre",
        "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul"
    ]
    /// Start tags that end an open `<p>` (HTML's optional end tag).
    private static let paragraphClosers: Set<String> = [
        "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "footer", "form", "h1", "h2", "h3",
        "h4", "h5", "h6", "header", "hr", "main", "nav", "ol", "p", "pre", "section", "table", "ul"
    ]

    private(set) var nodes = [HTMLDocument.Node(tag: "", attributes: [:], classes: [], parent: -1)]
    private var stack = [0]

    mutating func parse(_ b: [UInt8]) {
        let n = b.count
        var i = 0
        var textStart = 0

        func text(_ start: Int, _ end: Int) -> String {
            String(decoding: b[start..<end], as: UTF8.self)
        }

        while i < n {
            guard b[i] == UInt8(ascii: "<"), i + 1 < n else { i += 1; continue }
            let next = b[i + 1]
            if next == UInt8(ascii: "!") || next == UInt8(ascii: "?") {
                appendText(text(textStart, i))
                if Self.hasPrefix(b, at: i, "<!--") {
                    // From `i + 2`, so the empty comments `<!-->` and `<!--->` end where they should.
                    i = (Self.find(b, "-->", from: i + 2) ?? n - 3) + 3
                } else {
                    i = (Self.find(b, ">", from: i) ?? n - 1) + 1
                }
                textStart = min(i, n)
                i = textStart
                continue
            }
            if next == UInt8(ascii: "/") {
                var j = i + 2
                while j < n, Self.isNameByte(b[j]) { j += 1 }
                guard j > i + 2 else { i += 1; continue }
                appendText(text(textStart, i))
                let name = text(i + 2, j).lowercased()
                i = (Self.find(b, ">", from: j) ?? n - 1) + 1
                textStart = min(i, n)
                i = textStart
                close(name)
                continue
            }
            guard Self.isLetter(next) else { i += 1; continue }

            appendText(text(textStart, i))
            var j = i + 1
            while j < n, Self.isNameByte(b[j]) { j += 1 }
            let name = text(i + 1, j).lowercased()
            var attributes: [String: String] = [:]
            var selfClosing = false
            attributeLoop: while j < n {
                while j < n, Self.isSpace(b[j]) { j += 1 }
                guard j < n else { break }
                switch b[j] {
                case UInt8(ascii: ">"):
                    j += 1
                    break attributeLoop
                case UInt8(ascii: "/"):
                    if j + 1 < n, b[j + 1] == UInt8(ascii: ">") {
                        selfClosing = true
                        j += 2
                        break attributeLoop
                    }
                    j += 1
                    continue
                default:
                    break
                }
                let nameStart = j
                while j < n, !Self.isSpace(b[j]), b[j] != UInt8(ascii: "="), b[j] != UInt8(ascii: ">"),
                      !(b[j] == UInt8(ascii: "/") && j + 1 < n && b[j + 1] == UInt8(ascii: ">")) {
                    j += 1
                }
                guard j > nameStart else { j += 1; continue }
                let attributeName = text(nameStart, j).lowercased()
                while j < n, Self.isSpace(b[j]) { j += 1 }
                var value = ""
                if j < n, b[j] == UInt8(ascii: "=") {
                    j += 1
                    while j < n, Self.isSpace(b[j]) { j += 1 }
                    if j < n, b[j] == UInt8(ascii: "\"") || b[j] == UInt8(ascii: "'") {
                        let quote = b[j]
                        let valueStart = j + 1
                        j = valueStart
                        while j < n, b[j] != quote { j += 1 }
                        value = text(valueStart, min(j, n))
                        j += 1
                    } else {
                        let valueStart = j
                        while j < n, !Self.isSpace(b[j]), b[j] != UInt8(ascii: ">") { j += 1 }
                        value = text(valueStart, j)
                    }
                }
                if attributes[attributeName] == nil {
                    attributes[attributeName] = HTMLEntities.decode(value)
                }
            }
            i = min(j, n)
            textStart = i

            let element = open(name, attributes: attributes, selfClosing: selfClosing)
            if let element, Self.rawTextTags.contains(name) {
                let end = Self.findEndTag(b, name, from: i) ?? n
                if name != "script" && name != "style" {
                    nodes[element].content.append(.text(HTMLEntities.decode(text(i, end))))
                } else {
                    nodes[element].data = text(i, end)
                }
                close(name)
                i = end < n ? (Self.find(b, ">", from: end) ?? n - 1) + 1 : n
                textStart = i
            }
        }
        appendText(text(min(textStart, n), n))
    }

    private mutating func appendText(_ raw: String) {
        guard !raw.isEmpty else { return }
        let decoded = HTMLEntities.decode(raw)
        let current = stack[stack.count - 1]
        if case .text(let previous)? = nodes[current].content.last {
            nodes[current].content[nodes[current].content.count - 1] = .text(previous + decoded)
        } else {
            nodes[current].content.append(.text(decoded))
        }
    }

    /// Appends the element; returns its index when it stays open (not void or self-closed).
    private mutating func open(_ tag: String, attributes: [String: String], selfClosing: Bool) -> Int? {
        switch tag {
        case "li": closeOpen(["li"], within: ["ul", "ol", "menu"])
        case "dt", "dd": closeOpen(["dt", "dd"], within: ["dl"])
        case "option": closeOpen(["option"], within: ["select", "datalist", "optgroup"])
        case "tr": closeOpen(["tr"], within: ["table", "tbody", "thead", "tfoot"])
        case "td", "th": closeOpen(["td", "th"], within: ["tr", "table"])
        default: break
        }
        if Self.paragraphClosers.contains(tag), nodes[stack[stack.count - 1]].tag == "p" {
            stack.removeLast()
        }

        let parent = stack[stack.count - 1]
        let classes = Set((attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map { $0.lowercased() })
        var node = HTMLDocument.Node(tag: tag, attributes: attributes, classes: classes, parent: parent)
        node.siblingIndex = nodes[parent].children.count
        let index = nodes.count
        nodes.append(node)
        nodes[parent].children.append(index)
        nodes[parent].content.append(.element(index))

        guard !selfClosing, !Self.voidTags.contains(tag) else { return nil }
        stack.append(index)
        return index
    }

    /// jsoup's `MaxScopeSearchDepth`: end tags look only this far up the open elements, so a page of stray end
    /// tags under thousands of unclosed ones still parses in linear time.
    private static let maxScopeSearchDepth = 100

    /// Closes the innermost open `tags` element unless one of the `within` containers is opened after it.
    private mutating func closeOpen(_ tags: Set<String>, within containers: Set<String>) {
        for position in stack.indices.reversed().prefix(Self.maxScopeSearchDepth) where position > 0 {
            let tag = nodes[stack[position]].tag
            if containers.contains(tag) { return }
            if tags.contains(tag) {
                stack.removeSubrange(position...)
                return
            }
        }
    }

    /// Closes the innermost open element with this tag (and everything opened inside it); stray end tags are ignored.
    private mutating func close(_ tag: String) {
        let lowest = max(1, stack.count - Self.maxScopeSearchDepth)
        guard let position = stack[lowest...].lastIndex(where: { nodes[$0].tag == tag }) else { return }
        stack.removeSubrange(position...)
    }

    // MARK: Byte helpers

    private static func isLetter(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func isNameByte(_ c: UInt8) -> Bool {
        isLetter(c) || (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: "-") || c == UInt8(ascii: ":") || c == UInt8(ascii: "_")
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C
    }

    private static func hasPrefix(_ b: [UInt8], at i: Int, _ prefix: String) -> Bool {
        let p = Array(prefix.utf8)
        return i + p.count <= b.count && Array(b[i..<i + p.count]) == p
    }

    private static func find(_ b: [UInt8], _ needle: String, from start: Int) -> Int? {
        let p = Array(needle.utf8)
        guard !p.isEmpty, start <= b.count - p.count else { return nil }
        var i = start
        while i <= b.count - p.count {
            if b[i] == p[0] && Array(b[i..<i + p.count]) == p { return i }
            i += 1
        }
        return nil
    }

    /// Position of the end tag `</tag` (any case, followed by `>`, `/` or whitespace) at or after `start`.
    private static func findEndTag(_ b: [UInt8], _ tag: String, from start: Int) -> Int? {
        let p = Array("</\(tag)".utf8)
        var i = start
        while i <= b.count - p.count {
            if b[i] == UInt8(ascii: "<"), b[i + 1] == UInt8(ascii: "/") {
                var same = true
                for k in 2..<p.count where (b[i + k] | 0x20) != p[k] { same = false; break }
                let end = i + p.count
                if same, end == b.count || b[end] == UInt8(ascii: ">") || b[end] == UInt8(ascii: "/") || isSpace(b[end]) {
                    return i
                }
            }
            i += 1
        }
        return nil
    }
}

// MARK: - Entities

enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "hellip": "…",
        "mdash": "—", "ndash": "–", "middot": "·", "copy": "©", "reg": "®", "trade": "™", "times": "×",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»", "bull": "•",
        "deg": "°", "yen": "¥", "emsp": "\u{2003}", "ensp": "\u{2002}", "thinsp": "\u{2009}"
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let afterAmp = rest.index(after: amp)
            if let semicolon = rest[afterAmp...].prefix(10).firstIndex(of: ";"),
               let decoded = entity(rest[afterAmp..<semicolon]) {
                out += decoded
                rest = rest[rest.index(after: semicolon)...]
            } else {
                out += "&"
                rest = rest[afterAmp...]
            }
        }
        out += rest
        return out
    }

    private static func entity(_ name: Substring) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[String(name)]
    }
}

// MARK: - CSS selectors

struct CSSSelector {
    var compounds: [CSSCompound]
    /// `combinators[i]` joins `compounds[i]` and `compounds[i + 1]`.
    var combinators: [CSSCombinator]
}

enum CSSCombinator {
    case descendant, child, adjacent, sibling
}

struct CSSCompound {
    var tag: String?
    var id: String?
    var classes: [String] = []
    var attributes: [CSSAttributeCondition] = []
    var pseudos: [CSSPseudo] = []
}

struct CSSAttributeCondition {
    /// jsoup's operators: `~=` is a regular expression there, not CSS's whitespace-separated word.
    enum Operator: String {
        case equals = "=", notEquals = "!=", prefix = "^=", suffix = "$=", contains = "*=", regex = "~=", language = "|="
    }

    let name: String
    let op: Operator?
    /// Lowercased: jsoup compares attribute values case-insensitively (after trimming).
    let value: String
    /// For `~=`, matched against the attribute as written.
    let regex: NSRegularExpression?

    func matches(_ attribute: String?) -> Bool {
        // jsoup reads a missing attribute as "", which differs from any non-empty value.
        if op == .notEquals {
            return (attribute ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != value
        }
        guard let attribute else { return false }
        guard let op else { return true }
        let actual = attribute.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch op {
        case .equals: return actual == value
        case .notEquals: return actual != value
        case .prefix: return !value.isEmpty && actual.hasPrefix(value)
        case .suffix: return !value.isEmpty && actual.hasSuffix(value)
        case .contains: return !value.isEmpty && actual.contains(value)
        case .regex: return regex?.firstMatch(in: attribute, range: NSRange(attribute.startIndex..., in: attribute)) != nil
        case .language: return actual == value || actual.hasPrefix(value + "-")
        }
    }
}

enum CSSPseudo {
    case not([CSSSelector])
    case has([CSSSelector])
    /// jsoup `:eq(n)` / `:lt(n)` / `:gt(n)`: the 0-based position among element siblings.
    case indexEquals(Int), indexLess(Int), indexGreater(Int)
    case nthChild(Int)
    case nthOfType(Int)
    case firstChild, lastChild, firstOfType, lastOfType
    /// Case-insensitive text match (jsoup `:contains` / `:containsOwn`); the needle is lowercased.
    case contains(String)
    case containsOwn(String)
}

enum CSSSelectorParser {
    struct SyntaxError: Error {}

    static func parse(_ query: String) throws -> [CSSSelector] {
        var scanner = Scanner(Array(query.unicodeScalars))
        let selectors = try scanner.selectorList(until: nil)
        guard scanner.atEnd else { throw SyntaxError() }
        return selectors
    }

    private struct Scanner {
        let s: [Unicode.Scalar]
        var i = 0

        init(_ s: [Unicode.Scalar]) { self.s = s }

        var atEnd: Bool { i >= s.count }
        var peek: Unicode.Scalar? { i < s.count ? s[i] : nil }

        mutating func skipSpaces() -> Bool {
            let start = i
            while let c = peek, c.properties.isWhitespace { i += 1 }
            return i > start
        }

        /// Comma-separated selectors, up to `terminator` (")" inside `:not(…)`) or the end.
        mutating func selectorList(until terminator: Unicode.Scalar?) throws -> [CSSSelector] {
            var selectors: [CSSSelector] = []
            while true {
                _ = skipSpaces()
                selectors.append(try selector(until: terminator))
                _ = skipSpaces()
                if peek == "," { i += 1; continue }
                return selectors
            }
        }

        mutating func selector(until terminator: Unicode.Scalar?) throws -> CSSSelector {
            var compounds = [try compound()]
            var combinators: [CSSCombinator] = []
            while true {
                let hadSpace = skipSpaces()
                guard let c = peek, c != ",", c != terminator else { break }
                switch c {
                case ">": combinators.append(.child); i += 1; _ = skipSpaces()
                case "+": combinators.append(.adjacent); i += 1; _ = skipSpaces()
                case "~": combinators.append(.sibling); i += 1; _ = skipSpaces()
                default:
                    guard hadSpace else { throw SyntaxError() }
                    combinators.append(.descendant)
                }
                compounds.append(try compound())
            }
            return CSSSelector(compounds: compounds, combinators: combinators)
        }

        mutating func compound() throws -> CSSCompound {
            var compound = CSSCompound()
            var consumed = false
            if peek == "*" {
                i += 1
                consumed = true
            } else if let c = peek, isIdentifierStart(c) {
                compound.tag = identifier().lowercased()
                consumed = true
            }
            loop: while let c = peek {
                switch c {
                case "#":
                    i += 1
                    compound.id = identifier()
                case ".":
                    i += 1
                    compound.classes.append(identifier().lowercased())
                case "[":
                    i += 1
                    compound.attributes.append(try attributeCondition())
                case ":":
                    i += 1
                    compound.pseudos.append(try pseudo())
                default:
                    break loop
                }
                consumed = true
            }
            guard consumed else { throw SyntaxError() }
            return compound
        }

        mutating func attributeCondition() throws -> CSSAttributeCondition {
            _ = skipSpaces()
            let name = identifier().lowercased()
            guard !name.isEmpty else { throw SyntaxError() }
            _ = skipSpaces()
            var op: CSSAttributeCondition.Operator?
            if peek == "]" {
                i += 1
                return CSSAttributeCondition(name: name, op: nil, value: "", regex: nil)
            }
            if peek == "=" {
                op = .equals
                i += 1
            } else if let c = peek, i + 1 < s.count, s[i + 1] == "=",
                      let found = CSSAttributeCondition.Operator(rawValue: String(c) + "=") {
                op = found
                i += 2
            } else {
                throw SyntaxError()
            }
            _ = skipSpaces()
            var value: String
            if peek == "\"" || peek == "'" {
                value = try quoted()
            } else {
                // Like jsoup, an unquoted value runs to the `]` (`a[href^=//cdn]`).
                value = ""
                while let c = peek, c != "]" { value.unicodeScalars.append(c); i += 1 }
                value = value.trimmingCharacters(in: .whitespaces)
            }
            _ = skipSpaces()
            guard peek == "]" else { throw SyntaxError() }
            i += 1
            var regex: NSRegularExpression?
            if op == .regex {
                guard let compiled = try? NSRegularExpression(pattern: value) else { throw SyntaxError() }
                regex = compiled
            }
            return CSSAttributeCondition(name: name, op: op, value: value.lowercased(), regex: regex)
        }

        mutating func pseudo() throws -> CSSPseudo {
            let name = identifier().lowercased()
            switch name {
            case "first-child": return .firstChild
            case "last-child": return .lastChild
            case "first-of-type": return .firstOfType
            case "last-of-type": return .lastOfType
            default: break
            }
            guard peek == "(" else { throw SyntaxError() }
            i += 1
            defer { i += 1 }
            switch name {
            case "not", "has":
                let selectors = try selectorList(until: ")")
                guard peek == ")" else { throw SyntaxError() }
                return name == "not" ? .not(selectors) : .has(selectors)
            case "nth-child", "nth-of-type", "eq", "lt", "gt":
                _ = skipSpaces()
                guard let n = Int(identifier()) else { throw SyntaxError() }
                _ = skipSpaces()
                guard peek == ")" else { throw SyntaxError() }
                switch name {
                case "nth-child": return .nthChild(n)
                case "nth-of-type": return .nthOfType(n)
                case "eq": return .indexEquals(n)
                case "lt": return .indexLess(n)
                default: return .indexGreater(n)
                }
            case "contains", "containsown":
                _ = skipSpaces()
                var text = ""
                if peek == "\"" || peek == "'" {
                    text = try quoted()
                    _ = skipSpaces()
                } else {
                    while let c = peek, c != ")" { text.unicodeScalars.append(c); i += 1 }
                }
                guard peek == ")" else { throw SyntaxError() }
                let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
                return name == "contains" ? .contains(needle) : .containsOwn(needle)
            default:
                throw SyntaxError()
            }
        }

        mutating func quoted() throws -> String {
            guard let quote = peek else { throw SyntaxError() }
            i += 1
            var value = String.UnicodeScalarView()
            while let c = peek, c != quote {
                if c == "\\", i + 1 < s.count { i += 1 }
                value.append(s[i])
                i += 1
            }
            guard peek == quote else { throw SyntaxError() }
            i += 1
            return String(value)
        }

        mutating func identifier() -> String {
            var value = String.UnicodeScalarView()
            while let c = peek, isIdentifierCharacter(c) {
                if c == "\\", i + 1 < s.count { i += 1 }
                value.append(s[i])
                i += 1
            }
            return String(value)
        }

        func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
            c.properties.isAlphabetic || c == "_" || c == "-" || c.value > 0x7F
        }

        func isIdentifierCharacter(_ c: Unicode.Scalar) -> Bool {
            c.properties.isAlphabetic || c.properties.numericType != nil || c == "_" || c == "-" || c == "\\" || c.value > 0x7F
        }
    }
}
