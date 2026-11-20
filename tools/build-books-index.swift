// Writes content/books/books.json, the index Pocket Mirror's Books page reads, and books-text.json
// (the text of every page, for searching inside the books): each folder becomes
// a collection, each PDF an entry with its page count and a readable title (chapter titles are
// read from the first page of each chapter file). macOS only (PDFKit). Run by tools/fetch-books.sh.
// Usage: swift tools/build-books-index.swift content/books
import Foundation
import PDFKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "content/books")
let fm = FileManager.default

// folder -> (title, about, chapters: one book split into files rather than separate books)
let known: [String: (String, String, Bool)] = [
  "army": ("US Army field manuals", "Survival, first aid, land navigation, cold weather and field hygiene. Public domain.", false),
  "fema": ("FEMA", "Are You Ready? The government's guide to disaster preparedness. Public domain.", false),
  "epa": ("EPA", "How to make water safe to drink in an emergency. Public domain.", false),
  "usda-home-canning": ("USDA Complete Guide to Home Canning", "Tested methods for canning fruit, vegetables, meat, pickles and jams (2015). Public domain.", true),
  "Where There Is No Doctor (Hesperian 2025)": ("Where There Is No Doctor", "Hesperian's village health care handbook, 2025 edition. Free for personal use.", true),
  "Where Women Have No Doctor (Hesperian 2024)": ("Where Women Have No Doctor", "Hesperian's health guide for women, 2024 edition. Free for personal use.", true),
]

func lines(_ s: String) -> [String] {
  s.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty && $0 != "\u{FFFC}" }
}

func chapterTitle(_ file: String, _ firstPage: String, book: String) -> String {
  let stem = (file as NSString).deletingPathExtension
  let ls = lines(firstPage)
  if stem.hasPrefix("00 ") { return "Front matter" }
  if stem.hasPrefix("99 ") { return "Back matter" }
  // Hesperian: the title is the first few short lines, around the running head (book name, page
  // number) and the "CHAPTER n" mark; body text or a section heading in capitals ends it.
  if book.hasPrefix("Where") {
    var title: [String] = []
    for l in ls.prefix(12) {
      if !title.isEmpty && l.range(of: #"^\d*CHAPTER"#, options: .regularExpression) != nil { break }
      if l.hasPrefix(book) || l.range(of: #"^\d+$|^\d*CHAPTER\s*\d*$|^Chapter \d+$"#, options: .regularExpression) != nil { continue }
      if l.hasPrefix("In this chapter") || (l.count > 45 && !(title.isEmpty && l.range(of: #"^\d+ [A-Z]"#, options: .regularExpression) != nil)) || (l.count > 12 && l == l.uppercased()) { break }
      title.append(l.replacingOccurrences(of: #"^\d+ "#, with: "", options: .regularExpression))
      if title.count == 4 { break }
    }
    if !title.isEmpty {
      return (Int(stem.prefix(2)).map { "\($0). " } ?? "") + title.joined(separator: " ")
    }
  }
  // USDA canning: "Complete Guide to | Home Canning | Guide 3 | Selecting, ... | and Tomato Products"
  if let i = ls.firstIndex(where: { $0.range(of: #"^Guide \d$"#, options: .regularExpression) != nil }) {
    let rest = ls[(i + 1)...].prefix(4).prefix { $0.count < 60 }
    return ls[i] + ": " + rest.joined(separator: " ")
  }
  if stem.hasPrefix("0 ") { return "Introduction" }
  return stem
}

var collections: [[String: Any]] = []
var pageText: [[Any]] = []   // [file id, page number (1-based), text]
var fileId = 0
let folders = try fm.contentsOfDirectory(atPath: root.path).filter {
  var d: ObjCBool = false
  return fm.fileExists(atPath: root.appendingPathComponent($0).path, isDirectory: &d) && d.boolValue && !$0.hasPrefix(".")
}.sorted()
for folder in folders {
  let dir = root.appendingPathComponent(folder)
  let pdfs = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.lowercased().hasSuffix(".pdf") }
    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  if pdfs.isEmpty { continue }
  let meta = known[folder] ?? (folder, "", false)
  var items: [[String: Any]] = []
  for f in pdfs {
    let url = dir.appendingPathComponent(f)
    let bytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    let doc = PDFDocument(url: url)
    let title = meta.2 ? chapterTitle(f, doc?.page(at: 0)?.string ?? "", book: meta.0) : (f as NSString).deletingPathExtension
    items.append(["id": fileId, "title": title, "file": folder + "/" + f, "pages": doc?.pageCount ?? 0, "bytes": bytes])
    if let doc {
      for i in 0..<doc.pageCount {
        let text = (doc.page(at: i)?.string ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if text.count >= 20 { pageText.append([fileId, i + 1, text]) }
      }
    }
    fileId += 1
  }
  collections.append(["title": meta.0, "about": meta.1, "chapters": meta.2, "items": items])
}
let out = root.appendingPathComponent("books.json")
let data = try JSONSerialization.data(withJSONObject: ["collections": collections], options: [.prettyPrinted, .sortedKeys])
try data.write(to: out)
let textData = try JSONSerialization.data(withJSONObject: ["pages": pageText])
try textData.write(to: root.appendingPathComponent("books-text.json"))
print("\(pageText.count) pages of text -> books-text.json (\(textData.count / 1_000_000) MB)")
print("\(collections.count) collections, \(collections.reduce(0) { $0 + (($1["items"] as? [Any])?.count ?? 0) }) files -> \(out.path)")
