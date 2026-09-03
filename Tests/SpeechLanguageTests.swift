import Foundation
import NaturalLanguage

@main
struct SpeechLanguageTests {
    static func main() {
        everyLanguageHasARegionQualifiedVoiceCode()
        speechCodeNeverEqualsTheBareRawValue()
        scriptDecidesWithoutGuessing()
        englishTechnicalWordsAreNotReadAsFrenchOrGerman()
        genuinelyForeignWordsSurviveTheFloor()
        multiWordTextTrustsDetection()
        emptyOrWhitespaceHasNoLanguage()
        print("SpeechLanguageTests: 7 passed")
    }

    /// 语音代码必须带地区码，否则系统挑出来的声音很意外。
    private static func everyLanguageHasARegionQualifiedVoiceCode() {
        for language in TranslationLanguage.allCases {
            let code = language.speechLanguageCode
            expect(
                code.contains("-") && code.split(separator: "-").count == 2,
                "\(language.rawValue) 的语音代码缺地区：\(code)"
            )
        }
    }

    /// 这是缺陷本体：`"en"` 会拿到澳洲口音，`"zh-Hant"` 会拿到普通话音。
    /// 只要有人图省事把 rawValue 直接传给合成器，这条就会红。
    private static func speechCodeNeverEqualsTheBareRawValue() {
        for language in TranslationLanguage.allCases {
            expect(
                language.speechLanguageCode != language.rawValue,
                "\(language.rawValue) 直接用了 rawValue 当语音代码"
            )
        }
    }

    /// 字形是确定的，不该走概率判断。
    private static func scriptDecidesWithoutGuessing() {
        let cases: [(String, TranslationLanguage)] = [
            ("こんにちは", .japanese),
            ("안녕하세요", .korean),
            ("Привет", .russian),
            ("спасибо", .russian),
            ("调度器", .simplifiedChinese),
            ("队列已清空。", .simplifiedChinese)
        ]

        for (text, expected) in cases {
            let actual = TranslationLanguage.speechLanguage(forSource: text)
            expect(
                actual == expected,
                "\(text) 应判为 \(expected.rawValue)，实际 "
                    + String(describing: actual)
            )
        }

        // 假名必须先于汉字判断，否则夹汉字的日文会被当成中文。
        expect(
            TranslationLanguage.speechLanguage(forSource: "東京に行きます")
                == .japanese,
            "夹汉字的日文被判成了中文"
        )

        // 谚文同理。
        expect(
            TranslationLanguage.speechLanguage(forSource: "韓國語 안녕")
                == .korean,
            "夹汉字的韩文被判成了中文"
        )
    }

    /// 用户报告场景的核心：划词最常选的英文技术词，不能用法语/德语音念。
    ///
    /// 这几个词在无约束识别下分别是 法语0.66 / 德语0.32 / 法语0.38 / 法语0.41，
    /// 加了候选集约束仍然是 法语0.80 / 德语0.70 / 法语0.68 / 法语0.60。
    private static func englishTechnicalWordsAreNotReadAsFrenchOrGerman() {
        let words = [
            "cache", "queue", "coroutine", "idempotent", "rollback",
            "scheduler", "sushi", "ephemeral", "algorithm", "throttle",
            "mutex", "payload", "middleware", "latency", "closure"
        ]

        for word in words {
            expect(
                TranslationLanguage.speechLanguage(forSource: word) == .english,
                "\(word) 没被判为英文，会用错语言的声音朗读"
            )
        }
    }

    /// 阈值不能高到把真外语单词也吞掉——否则 Bonjour 会用英文音念。
    private static func genuinelyForeignWordsSurviveTheFloor() {
        let cases: [(String, TranslationLanguage)] = [
            ("Bonjour", .french),
            ("croissant", .french),
            ("Kindergarten", .german),
            ("Schadenfreude", .german),
            ("gracias", .spanish),
            ("mañana", .spanish)
        ]

        for (word, expected) in cases {
            expect(
                TranslationLanguage.speechLanguage(forSource: word) == expected,
                "\(word) 被阈值吞掉了，应为 \(expected.rawValue)"
            )
        }
    }

    /// 两词以上识别就可信，此时不该再强行改判英文。
    private static func multiWordTextTrustsDetection() {
        let cases: [(String, TranslationLanguage)] = [
            ("The scheduler drains the queue.", .english),
            ("graceful shutdown", .english),
            ("Le planificateur vide la file d'attente.", .french),
            ("Der Planer leert die Warteschlange.", .german),
            ("El planificador vacía la cola.", .spanish)
        ]

        for (text, expected) in cases {
            expect(
                TranslationLanguage.speechLanguage(forSource: text) == expected,
                "\(text) 应判为 \(expected.rawValue)"
            )
        }
    }

    private static func emptyOrWhitespaceHasNoLanguage() {
        for text in ["", "   ", "\n\t"] {
            expect(
                TranslationLanguage.speechLanguage(forSource: text) == nil,
                "空文本不该判出语言"
            )
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("SpeechLanguageTests failed: \(message)")
        }
    }
}
