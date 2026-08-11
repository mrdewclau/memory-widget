import CoreGraphics
import Foundation
import ImageIO
import Vision

private struct VisionOutput: Codable {
    let humanSeen: Bool?
    let animalSeen: Bool?
    let animalKind: String?
    let text: String?
}

@main
enum ContextVisionHelper {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            exit(2)
        }

        let mode = arguments[1]
        let output: VisionOutput
        if mode == "screen" {
            output = inspectScreen(image)
        } else {
            output = inspectCamera(image)
        }

        guard let data = try? JSONEncoder().encode(output) else { exit(3) }
        FileHandle.standardOutput.write(data)
    }

    private static func inspectScreen(_ image: CGImage) -> VisionOutput {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.025
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let summary = lines.prefix(8).joined(separator: " · ")
        return VisionOutput(humanSeen: nil, animalSeen: nil, animalKind: nil, text: summary.isEmpty ? nil : summary)
    }

    private static func inspectCamera(_ image: CGImage) -> VisionOutput {
        let animals = VNRecognizeAnimalsRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let bodies = VNDetectHumanBodyPoseRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([animals, faces, bodies])

        let animal = animals.results?.first?.labels.first
        let humanSeen = !(faces.results ?? []).isEmpty || !(bodies.results ?? []).isEmpty
        return VisionOutput(
            humanSeen: humanSeen,
            animalSeen: animal != nil,
            animalKind: animal?.identifier.capitalized,
            text: nil
        )
    }
}
