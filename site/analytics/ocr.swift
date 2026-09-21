// Read the text out of an image, so a check can ask what a screenshot actually says.
//
// The alternative was to trust that a capture was taken against the demo fixture. Trust is not a
// check: one frame taken from the wrong window puts a client's project name on the front page of
// the internet, and nothing in a build would notice. Vision is on every Mac this ships from, so
// the question "does this picture contain that word" has an answer.
//
//   swift site/analytics/ocr.swift <image> [<image> …]
//
// Prints one line per recognised string. Exits non-zero only if an image cannot be read at all —
// finding nothing is a legitimate answer about a picture with no text in it.

import Foundation
import Vision
import AppKit

var failed = false

for path in CommandLine.arguments.dropFirst() {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        failed = true
        continue
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    // A product name in a sidebar is small; without this, Vision discards exactly the text this
    // check exists to find.
    request.minimumTextHeight = 0.004
    request.revision = VNRecognizeTextRequestRevision3

    do {
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
    } catch {
        FileHandle.standardError.write("vision failed on \(path): \(error)\n".data(using: .utf8)!)
        failed = true
        continue
    }
    for observation in (request.results ?? []) {
        guard let best = observation.topCandidates(1).first else { continue }
        print(best.string)
    }
}

exit(failed ? 1 : 0)
