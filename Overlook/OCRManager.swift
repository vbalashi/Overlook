import Foundation
import Vision
import CoreImage
import AppKit
import Combine

@MainActor
class OCRManager: ObservableObject {
    @Published var isProcessing = false
    @Published var recognizedRegions: [TextRegion] = []

    nonisolated(unsafe) private var textRecognitionRequest: VNRecognizeTextRequest?
    nonisolated(unsafe) private var textObservationRequest: VNRecognizeTextRequest?
    nonisolated(unsafe) private var ocrQueue = DispatchQueue(label: "com.overlook.ocr", qos: .userInitiated)

    init() {
        setupOCRRequests()
    }

    private func setupOCRRequests() {
        textRecognitionRequest = VNRecognizeTextRequest()
        textRecognitionRequest?.recognitionLevel = .accurate
        textRecognitionRequest?.usesLanguageCorrection = true
        textRecognitionRequest?.recognitionLanguages = ["en-US", "en-GB"]
        textRecognitionRequest?.automaticallyDetectsLanguage = true

        textObservationRequest = VNRecognizeTextRequest()
        textObservationRequest?.recognitionLevel = .fast
        textObservationRequest?.usesLanguageCorrection = false
        textObservationRequest?.recognitionLanguages = ["en-US", "en-GB"]
        textObservationRequest?.automaticallyDetectsLanguage = true
    }

    func recognizeTextInRegion(_ region: CGRect, in pixelBuffer: CVPixelBuffer?) async throws -> String {
        guard let pixelBuffer = pixelBuffer else {
            throw OCRError.noVideoFrame
        }

        let pixelBufferBox = PixelBufferBox(pixelBuffer)
        return try await withCheckedThrowingContinuation { continuation in
            ocrQueue.async { [weak self] in
                self?.performRegionTextRecognition(region: region, in: pixelBufferBox.pixelBuffer) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    func detectTextRegions(in pixelBuffer: CVPixelBuffer?) async throws -> [TextRegion] {
        guard let pixelBuffer = pixelBuffer else {
            throw OCRError.noVideoFrame
        }

        let pixelBufferBox = PixelBufferBox(pixelBuffer)
        return try await withCheckedThrowingContinuation { continuation in
            ocrQueue.async { [weak self] in
                self?.performTextDetection(in: pixelBufferBox.pixelBuffer) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    nonisolated private func performTextDetection(in pixelBuffer: CVPixelBuffer, completion: @escaping (Result<[TextRegion], Error>) -> Void) {
        guard let request = textObservationRequest else {
            completion(.failure(OCRError.requestNotInitialized))
            return
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])

        do {
            try handler.perform([request])

            let regions = (request.results ?? []).compactMap { observation -> TextRegion? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return TextRegion(
                    text: candidate.string,
                    boundingBox: observation.boundingBox,
                    confidence: candidate.confidence
                )
            }

            Task { @MainActor in
                self.recognizedRegions = regions
            }

            completion(.success(regions))
        } catch {
            completion(.failure(error))
        }
    }

    nonisolated private func performRegionTextRecognition(region: CGRect, in pixelBuffer: CVPixelBuffer, completion: @escaping (Result<String, Error>) -> Void) {
        guard let request = textRecognitionRequest else {
            completion(.failure(OCRError.requestNotInitialized))
            return
        }

        let bufferSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let normalizedRegion = CGRect(
            x: region.origin.x * bufferSize.width,
            y: region.origin.y * bufferSize.height,
            width: region.size.width * bufferSize.width,
            height: region.size.height * bufferSize.height
        )

        let croppedBuffer = cropPixelBuffer(pixelBuffer, to: normalizedRegion)
        let handler = VNImageRequestHandler(cvPixelBuffer: croppedBuffer, options: [:])

        Task { @MainActor in
            isProcessing = true
        }

        do {
            try handler.perform([request])

            guard let observations = request.results else {
                Task { @MainActor in
                    isProcessing = false
                }
                completion(.failure(OCRError.noTextFound))
                return
            }

            let recognizedText = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }.joined(separator: " ")

            Task { @MainActor in
                isProcessing = false
            }

            if recognizedText.isEmpty {
                completion(.failure(OCRError.noTextFound))
            } else {
                completion(.success(recognizedText))
            }
        } catch {
            Task { @MainActor in
                isProcessing = false
            }
            completion(.failure(error))
        }
    }

    nonisolated private func cropPixelBuffer(_ pixelBuffer: CVPixelBuffer, to rect: CGRect) -> CVPixelBuffer {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = ciImage.extent.integral
        let requested = rect.integral
        let clipped = requested.intersection(sourceExtent)

        if clipped.isEmpty {
            return pixelBuffer
        }

        let croppedImage = ciImage
            .cropped(to: clipped)
            .transformed(by: CGAffineTransform(translationX: -clipped.origin.x, y: -clipped.origin.y))

        var croppedPixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(clipped.width),
            Int(clipped.height),
            CVPixelBufferGetPixelFormatType(pixelBuffer),
            nil,
            &croppedPixelBuffer
        )

        guard status == kCVReturnSuccess, let outputBuffer = croppedPixelBuffer else {
            return pixelBuffer
        }

        let context = CIContext()
        context.render(croppedImage, to: outputBuffer)

        return outputBuffer
    }
}

struct TextRegion: Identifiable, Codable {
    let id: UUID
    let text: String
    let boundingBox: CGRect
    let confidence: Float

    init(id: UUID = UUID(), text: String, boundingBox: CGRect, confidence: Float) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

private struct PixelBufferBox: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer

    init(_ pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}

enum OCRError: Error, LocalizedError {
    case noVideoFrame
    case requestNotInitialized
    case noTextFound

    var errorDescription: String? {
        switch self {
        case .noVideoFrame:
            return "No video frame available for OCR"
        case .requestNotInitialized:
            return "OCR request not properly initialized"
        case .noTextFound:
            return "No text found in the specified region"
        }
    }
}
