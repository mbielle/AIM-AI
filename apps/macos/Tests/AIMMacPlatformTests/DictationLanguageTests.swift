@testable import AIMMacPlatform
import Foundation
import XCTest

final class DictationLanguageTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    override func setUp() {
        for key in [DictationLanguage.detectedKey, DictationEngine.defaultsKey] { saved[key] = UserDefaults.standard.object(forKey: key) }
    }
    override func tearDown() {
        for (key, value) in saved { if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
    }

    func testAutomaticFollowsTheLanguageThePersonWritesIn() {
        let supported: Set<String> = ["en-US", "en-GB", "fr-FR", "fr-CA", "de-DE"]
        // Mac in English with a French region, person writing French: French (France), not English.
        XCTAssertEqual(DictationLanguage.locale("auto", preferred: ["en-FR"], detected: "fr", supported: supported).identifier, "fr-FR")
        XCTAssertEqual(DictationLanguage.locale("auto", preferred: ["en-CA"], detected: "fr", supported: supported).identifier, "fr-CA")
        XCTAssertEqual(DictationLanguage.locale("auto", preferred: ["en-FR"], detected: nil, supported: supported).identifier, "en-FR")
        XCTAssertEqual(DictationLanguage.locale("de-DE", preferred: ["en-FR"], detected: "fr", supported: supported).identifier, "de-DE")
    }

    func testLearningIgnoresShortTextAndRecordsTheWritingLanguage() {
        UserDefaults.standard.removeObject(forKey: DictationLanguage.detectedKey)
        DictationLanguage.learn(from: "ok")
        XCTAssertNil(DictationLanguage.detected)
        DictationLanguage.learn(from: "J'aurais besoin de ton aide pour effectuer des recherches sur Internet à propos des nouveaux modèles.")
        XCTAssertEqual(DictationLanguage.detected, "fr")
    }

    func testOpenAIKeyMakesGPTTranscribeTheDefaultUnlessALocalModelWasChosen() {
        UserDefaults.standard.removeObject(forKey: DictationEngine.defaultsKey)
        XCTAssertEqual(DictationEngine.effective(hasOpenAIKey: false), .apple)
        XCTAssertEqual(DictationEngine.effective(hasOpenAIKey: true), .openAI)
        DictationEngine.selected = .apple
        DictationEngine.adoptOpenAI()
        XCTAssertEqual(DictationEngine.effective(hasOpenAIKey: true), .openAI)
        DictationEngine.selected = .parakeet
        DictationEngine.adoptOpenAI()
        XCTAssertEqual(DictationEngine.effective(hasOpenAIKey: true), .parakeet)
    }
}
