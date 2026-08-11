import Foundation
import SoundAnalysis

private struct SoundOutput: Codable {
    let label: String?
    let confidence: Double?
}

private final class SoundObserver: NSObject, SNResultsObserving {
    private let semaphore = DispatchSemaphore(value: 0)
    private(set) var bestLabel: String?
    private(set) var bestConfidence = 0.0

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classifications = result as? SNClassificationResult else { return }
        for classification in classifications.classifications.prefix(5) where classification.confidence > bestConfidence {
            bestLabel = classification.identifier
            bestConfidence = classification.confidence
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        semaphore.signal()
    }

    func requestDidComplete(_ request: SNRequest) {
        semaphore.signal()
    }

    func wait() {
        _ = semaphore.wait(timeout: .now() + 45)
    }
}

@main
enum ContextSoundHelper {
    static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        do {
            let analyzer = try SNAudioFileAnalyzer(url: url)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 600)
            request.overlapFactor = 0.25
            let observer = SoundObserver()
            try analyzer.add(request, withObserver: observer)
            analyzer.analyze()
            observer.wait()

            let output = SoundOutput(
                label: observer.bestConfidence >= 0.12 ? observer.bestLabel : "ambient",
                confidence: observer.bestConfidence
            )
            FileHandle.standardOutput.write(try JSONEncoder().encode(output))
        } catch {
            exit(3)
        }
    }
}
