import Foundation

// Local vocabulary shared by routing and retrieval. No document text leaves the Mac.

private let documents: [(pattern: Rx, terms: [String])] = [
    (Rx("\\b(?:e[ -]?)?(?:aadhaar|aadhar|adhar|adhaar|aadhhar|uidai)\\b|आधार", "i"), ["aadhaar", "aadhar", "adhar", "adhaar", "uidai", "आधार"]),
    (Rx("\\bpan\\s*(?:card|document)\\b", "i"), ["pan", "permanent account number"]),
    (Rx("\\bpassport\\b", "i"), ["passport"]),
    (Rx("\\b(?:driv(?:ing|er'?s?)\\s+licen[cs]e)\\b", "i"), ["driving licence", "driving license", "drivers license"]),
    (Rx("\\b(?:cv|resum[eé])\\b", "i"), ["resume", "résumé", "cv"]),
    (Rx("\\b(?:insurance|insurence)\\b", "i"), ["insurance", "insurence"])
]

public func documentTerms(_ text: String) -> [String] {
    documents.filter { $0.pattern.test(text) }.flatMap(\.terms).unique
}

public func hasLocalSearchIntent(_ text: String) -> Bool {
    let request = Rx("\\b(find|locate|search|look for|where(?:'s| is| are)|show|open)\\b", "i").test(text)
    return request && (!documentTerms(text).isEmpty || Rx("\\b(?:my|this)\\s+(?:pc|computer|mac|laptop|device)\\b", "i").test(text))
}

public func removeDocumentWords(_ text: String) -> String {
    var cleaned = text
    for document in documents where document.pattern.test(text) {
        cleaned = document.pattern.replaceFirst(cleaned, " ")
    }
    return cleaned
}
