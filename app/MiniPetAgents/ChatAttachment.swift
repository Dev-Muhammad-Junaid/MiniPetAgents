import Foundation
import AppKit

struct ChatAttachment {
    enum Kind {
        case image(NSImage, Data, String)   // thumbnail, png data, media type
        case text(String)                   // plain-text file content
    }
    let filename: String
    let kind: Kind

    var isImage: Bool { if case .image = kind { return true }; return false }

    var thumbnail: NSImage? {
        switch kind {
        case .image(let img, _, _): return img
        case .text: return NSImage(systemSymbolName: "doc.text.fill", accessibilityDescription: nil)
        }
    }

    static func from(url: URL) -> ChatAttachment? {
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"]
        let ext  = url.pathExtension.lowercased()
        let name = url.lastPathComponent

        if imageExts.contains(ext) {
            guard let image = NSImage(contentsOf: url),
                  let tiff  = image.tiffRepresentation,
                  let rep   = NSBitmapImageRep(data: tiff),
                  let png   = rep.representation(using: .png, properties: [:])
            else { return nil }
            let mediaType = (ext == "png") ? "image/png" : "image/jpeg"
            return ChatAttachment(filename: name, kind: .image(image, png, mediaType))
        } else {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return ChatAttachment(filename: name, kind: .text(text))
        }
    }
}
