import Foundation
import NaturalLanguage

@main
struct TranslationLanguageTests {
    static func main() {
        everyLanguageMapsBackFromNLLanguage()
        chinesePairsWithEnglishBothWays()
        otherLanguagesFallBackToChinese()
        sourceNameNeverEchoesRawCodeForKnownLanguages()
        sourceNameDegradesToCodeInsteadOfGuessing()
        detectionCoversTheDocumentedSourceLanguages()
        chineseOriginalUsesEnglishSpeechWhenTargetIsChinese()
        englishOriginalKeepsChineseSpeechWhenTargetIsChinese()
        unrecognizedOriginalKeepsThePreferredTarget()
        print("TranslationLanguageTests: 9 passed")
    }

    /// `matching` 用于判断「原文是否已经是目标语言」，漏掉任何一个都会让
    /// 该语言走进「源 → 同一个源」的方向。
    private static func everyLanguageMapsBackFromNLLanguage() {
        for language in TranslationLanguage.allCases {
            expect(
                TranslationLanguage.matching(language.nlLanguage) == language,
                "\(language.rawValue) did not map back from its NLLanguage"
            )
        }
    }

    /// 选中文的人选中一段中文要的是英文，反过来也一样。
    private static func chinesePairsWithEnglishBothWays() {
        expect(
            TranslationLanguage.simplifiedChinese.counterpart == .english,
            "simplified chinese must fall back to english"
        )
        expect(
            TranslationLanguage.traditionalChinese.counterpart == .english,
            "traditional chinese must fall back to english"
        )
        expect(
            TranslationLanguage.english.counterpart == .simplifiedChinese,
            "english must fall back to simplified chinese"
        )
    }

    /// 其余语言被选为目标语言时，原文同语种就翻回中文——这是中文用户的默认预期。
    private static func otherLanguagesFallBackToChinese() {
        for language in TranslationLanguage.allCases
        where language != .simplifiedChinese
            && language != .traditionalChinese
            && language != .english {
            expect(
                language.counterpart == .simplifiedChinese,
                "\(language.rawValue) must fall back to simplified chinese"
            )
        }
    }

    /// counterpart 必须真的改变语言，否则会生成「日文 → 日文」这种指令。
    private static func sourceNameNeverEchoesRawCodeForKnownLanguages() {
        for language in TranslationLanguage.allCases {
            expect(
                language.counterpart != language,
                "\(language.rawValue) counterpart must differ from itself"
            )
            let name = TranslationLanguage.sourceName(for: language.nlLanguage)
            expect(
                name == language.displayName,
                "known language \(language.rawValue) must use its display name"
            )
        }
    }

    /// 认出列表之外的语言时如实说出它，而不是假装成英文——这正是原缺陷。
    private static func sourceNameDegradesToCodeInsteadOfGuessing() {
        let name = TranslationLanguage.sourceName(for: NLLanguage("tr"))
        expect(
            name != TranslationLanguage.english.displayName,
            "an unlisted language must never be reported as english"
        )
        expect(!name.isEmpty, "source name must not be empty")
    }

    /// README 承诺的源语言都要能被识别，否则方向指令会退化成「未识别」。
    private static func detectionCoversTheDocumentedSourceLanguages() {
        let samples: [(TranslationLanguage, String)] = [
            (.english, "The scheduler drains the queue on a background actor."),
            (.japanese, "スケジューラはバックグラウンドのアクターでキューを処理します。"),
            (.korean, "스케줄러는 백그라운드 액터에서 큐를 처리합니다."),
            (.french, "Le planificateur vide la file d'attente en arrière-plan."),
            (.german, "Der Planer leert die Warteschlange im Hintergrund."),
            (.spanish, "El planificador vacía la cola en segundo plano."),
            (.russian, "Планировщик очищает очередь в фоновом акторе."),
            (.simplifiedChinese, "调度器会在后台 actor 中清空队列。")
        ]

        for (expected, text) in samples {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            guard let dominant = recognizer.dominantLanguage else {
                fatalError("TranslationLanguageTests failed: no language for \(text)")
            }
            expect(
                TranslationLanguage.matching(dominant) == expected,
                "expected \(expected.rawValue) for: \(text)"
            )
        }
    }

    /// 原文已经是目标语言时，译文走 counterpart，喇叭必须跟译文而不是设置项。
    ///
    /// 设置里选「简体中文」、划一段中文，面板上是英文；喇叭若仍用 zh-CN，
    /// 听起来像功能坏了。
    private static func chineseOriginalUsesEnglishSpeechWhenTargetIsChinese() {
        let original = "调度器会在后台 actor 中清空队列。"
        let spoken = TranslationLanguage.resolvedTranslationLanguage(
            forOriginal: original,
            preferred: .simplifiedChinese
        )
        expect(
            spoken == .english,
            "中文原文 + 目标中文，译文应是英文，喇叭却是 \(spoken.rawValue)"
        )
        expect(
            spoken.speechLanguageCode == "en-US",
            "英文译文必须用 en-US，不能把设置里的 zh-Hans 直接交给合成器"
        )
    }

    /// 普通路径：原文不是目标语言，译文就是设置里的目标语言。
    private static func englishOriginalKeepsChineseSpeechWhenTargetIsChinese() {
        let original = "The scheduler drains the queue on a background actor."
        let spoken = TranslationLanguage.resolvedTranslationLanguage(
            forOriginal: original,
            preferred: .simplifiedChinese
        )
        expect(
            spoken == .simplifiedChinese,
            "英文原文 + 目标中文，译文应是中文，实际 \(spoken.rawValue)"
        )
        expect(
            spoken.speechLanguageCode == "zh-CN",
            "中文译文必须用 zh-CN"
        )
    }

    /// 认不出源语言时，Ollama 只固定目标语言；喇叭必须与这条规则一致，
    /// 不能自己再猜一次。
    private static func unrecognizedOriginalKeepsThePreferredTarget() {
        let spoken = TranslationLanguage.resolvedTranslationLanguage(
            forOriginal: "12345",
            preferred: .japanese
        )
        expect(
            spoken == .japanese,
            "认不出源语言时喇叭应跟设置的目标语言，实际 \(spoken.rawValue)"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("TranslationLanguageTests failed: \(message)")
        }
    }
}
