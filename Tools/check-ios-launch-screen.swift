import Foundation
import Vision

guard CommandLine.arguments.count == 2 else {
    fatalError("Pass the simulator screenshot path")
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["en-US"]
let handler = VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[1]), options: [:])
try handler.perform([request])
let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
print(lines.joined(separator: "\n"))
let text = lines.joined(separator: " ").lowercased().filter { $0.isLetter }
guard text.contains("allsports") else {
    fputs("The Sports screen was not visible after launch.\n", stderr)
    exit(1)
}
