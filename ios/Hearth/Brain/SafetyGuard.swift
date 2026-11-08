// On-device check for signs that someone may be in danger (SPEC §2 and §7 SafetyGuard).
// Never blocks the chat: the UI shows gentle resources and the next reply is told to answer with care.
// The website has the same check in docs/app/js/brain/safety.js; keep the two in step.

import Foundation

enum SafetyLevel: String, Codable, Sendable {
    /// Nothing worrying.
    case none
    /// Heavy topic or a negated mention ("I would never kill myself"): show resources softly.
    case concern
    /// Someone may be in danger: show resources right away.
    case crisis
}

struct SafetyResource: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var detail: String
    var actionTitle: String
    var url: URL
}

enum SafetyGuard {
    static let resources: [SafetyResource] = [
        ("988-call", "988 Suicide & Crisis Lifeline", "Call 988 any time, day or night (US). Free and confidential.", "Call 988", "tel:988"),
        ("988-text", "Text the 988 Lifeline", "Text 988 to reach a trained counselor (US).", "Text 988", "sms:988"),
        ("crisis-text-line", "Crisis Text Line", "Text HOME to 741741 (US).", "Text HOME", "sms:741741&body=HOME"),
        ("dv-hotline", "National Domestic Violence Hotline", "If someone is hurting you, call 1-800-799-7233 or text START to 88788 (US).",
         "Abuse hotline", "tel:18007997233"),
        ("find-a-helpline", "Find a helpline", "Free, confidential helplines in other countries, at findahelpline.com.", "Other countries", "https://findahelpline.com"),
    ].compactMap { id, title, detail, action, link in
        URL(string: link).map { SafetyResource(id: id, title: title, detail: detail, actionTitle: action, url: $0) }
    }

    static let gentleMessage = "It sounds like things might feel really heavy right now. You don't have to carry this alone. If you're thinking about hurting yourself, you can call or text 988 any time (in the US), or text HOME to 741741 to talk with someone. Your chat will still be here."

    static func assess(_ text: String) -> SafetyLevel {
        var t = normalize(text)
        guard !t.isEmpty else { return .none }
        // Idioms and titles that only look alarming ("suicide squad", "cut myself some slack"). Only the phrase
        // goes, so the rest is still checked.
        for r in harmless { t = r.stringByReplacingMatches(in: t, range: BrainText.fullRange(t), withTemplate: " ") }

        var level = SafetyLevel.none
        // Talking about the topic ("suicide prevention") is a concern, and is removed so the bare words below
        // don't treat it as a crisis.
        for r in topics where BrainText.matches(r, t) {
            level = .concern
            t = r.stringByReplacingMatches(in: t, range: BrainText.fullRange(t), withTemplate: " ")
        }
        for r in crisis {
            for m in r.matches(in: t, range: BrainText.fullRange(t)) {
                guard let range = Range(m.range, in: t) else { continue }
                if isNegated(t, before: range.lowerBound) { level = .concern } else { return .crisis }
            }
        }
        // A bare word like "suicidal" or "overdosed" is a crisis when it's about the person writing, and a
        // concern when it's negated or about someone else ("my best friend overdosed in 2019").
        for r in mentions {
            for m in r.matches(in: t, range: BrainText.fullRange(t)) {
                guard let range = Range(m.range, in: t) else { continue }
                if isNegated(t, before: range.lowerBound) || aboutSomeoneElse(t, before: range.lowerBound) {
                    level = .concern
                } else {
                    return .crisis
                }
            }
        }
        if level == .none, concern.contains(where: { BrainText.matches($0, t) }) { level = .concern }
        return level
    }

    // MARK: - Patterns (matched against lowercased text with straight apostrophes)

    private static let crisis: [NSRegularExpression] = [
        // Ending one's life.
        #"\b(kill|kil|kll)(ing|in)?\s*(my\s?self|mysef|myslef|meself)\b"#,
        #"(?<![0-9])(?<![0-9] )\bkms\b"#,
        #"\bun-?aliv(e|ing)\s+(my\s?self|me)\b"#,
        #"\b(want|wanna|wanted|going|gonna|plan|planning)\s+(to\s+)?un-?alive\b"#,
        #"\bend(ing)?\s+(my|my\s+own)\s+life\b"#,
        #"\btak(e|ing)\s+my\s+(own\s+)?life\b"#,
        #"\bend\s+it\s+all\b"#,
        // "I'm going to end it tonight", "thinking about ending it" (not "end it with him" or "end it here").
        #"\b(i'?m|i\s+am|i'll|i\s+will|going\s+to|gonna|about\s+to|want\s+to|wanna|ready\s+to|plan(ning)?\s+(to|on)|think(ing)?\s+(about|of)|i\s+should(\s+just)?)\s+end(ing)?\s+it\b(?!\s+(with|for|between|here|there|early|off|properly|politely|nicely|amicably|on\s+(a|an|good|bad|friendly|the|that|this)|at\s+(that|this|the|\d)|by\s+(the|then|\w+day))\b)"#,
        #"\bways\s+to\s+(die|kill\s+my\s?self|end\s+(it|my\s+life))\b"#,
        // Wanting to die, or not to be alive.
        #"\b(want|wanna|wanted|wanting|wish|ready)\s+(to\s+)?die\b(?!\s+(of\s+(embarrassment|laughter|cuteness|boredom|shame)|laughing|from\s+laughing|happy))"#,
        #"\b(want|wanna|wanted|wanting|wish)\s+(to\s+)?be\s+dead\b"#,
        #"\brather\s+be\s+dead\b"#,
        #"\bi\s+should\s+(just\s+)?(die|be\s+dead)\b"#,
        // "I'm worthless and should die", "I deserve to die".
        #"\b(i'?m|i\s+am)\s+(\w+\s+){1,3}and\s+(i\s+)?(should|deserve\s+to)\s+(just\s+)?(die|be\s+dead)\b"#,
        #"\bi\s+(just\s+|really\s+)?deserve\s+to\s+(die|be\s+dead)\b"#,
        #"\bwish(ed)?\s+i(\s+had|'d)\s+never\s+been\s+born\b"#,
        #"\bwish(ed)?\s+i\s+(was|were)\s+(dead|never\s+born|gone)\b"#,
        #"\bwish(ed)?\s+i\s+(wasn't|weren't|wasnt|werent)\s+(alive|here|born)\b"#,
        #"\b(don't|dont|do\s+not)\s+(want|wanna)\s+to\s+(be\s+alive|exist)\b"#,
        #"\b(don't|dont|do\s+not)\s+(want|wanna)\s+to\s+(live|be\s+here|be\s+alive|exist|wake\s+up)\s+any\s?more\b"#,
        #"\b(don't|dont|do\s+not)\s+(want|wanna)\s+to\s+live(?=\s*$|\s*[.!?,;]|\s+like\s+this)"#,
        #"\b(don't|dont|do\s+not)\s+(want|wanna)\s+to\s+wake\s+up\b(?!\s+(early|earlier|late|at|before|by|for|so|on|in|the|my|your|his|her|him|them|anyone|everyone|you|this|that)\b)"#,
        #"\b(not\s+sure|don't\s+know|dont\s+know|unsure)\s+(if\s+|whether\s+)?i\s+(want|wanna)\s+to\s+(live|be\s+alive|be\s+here|keep\s+going|go\s+on)(?=\s*$|\s*[.!?,;]|\s+any\s?more|\s+like\s+this)"#,
        #"\bno\s+longer\s+want\s+to\s+(live|be\s+alive|be\s+here|exist)\b"#,
        #"\b(stop|cease)\s+(existing|to\s+exist)\b"#,
        #"\b(don't|dont)\s+think\s+i\s+(want\s+to|can)\s+(live|go\s+on|be\s+alive|keep\s+going)\b"#,
        #"\b(hope|wish)\s+i\s+(don't|dont|never|won't|wont)\s+wake\s+up\b"#,
        #"\b(want|wanna)\s+to\s+(sleep|go\s+to\s+sleep)\s+forever\b"#,
        #"\b(sleep|asleep)\s+and\s+(not|never)\s+wake\s+up\b"#,
        #"\b(done\s+with|tired\s+of)\s+(life|living|being\s+alive)\b(?!\s+in\b)"#,
        #"\bno\s+(reason|point)\s+(to|in)\s+(live|living|go\s+on|going\s+on|being\s+alive|being\s+here)\b"#,
        #"\b(life|living)\s+(is\s+not|isn't|isnt|is\s+no\s+longer|ain't|aint)\s+worth\s+(it|living)\b"#,
        #"\bnot\s+worth\s+living\b"#,
        #"\bwhat'?s\s+the\s+point\s+(of|in)\s+(living|life|being\s+alive|going\s+on)\b"#,
        #"\b(don't|dont|do\s+not|can't|cant)\s+see\s+(the\s+|a\s+|any\s+)?point\s+(in|of)\s+(living|life|being\s+alive|going\s+on)\b"#,
        #"\b(can't|cant|cannot|can\s+not)\s+go\s+on\b(?!\s+(a|an|the|that|this|my|our|your|his|her|their|vacation|holiday|trips?|dates?|tour|stage|breaks?|rides?|social|line|live|air|tv|camera))"#,
        // Others being better off, or not being around much longer.
        #"\bbetter\s+off\s+(dead|without\s+me)\b"#,
        #"\b(happier|better(\s+off)?|easier)\s+(if|when|once)\s+(i\s+(was|were|am)\s+(dead|gone)|i'?m\s+(dead|gone)|i\s+(wasn't|weren't|wasnt|werent|was\s+not|were\s+not)\s+(here|around|alive)|i\s+(died|disappeared))\b"#,
        #"\b(nobody|no\s+one|noone)\s+would\s+(care|notice|miss\s+me)\s+if\s+i\s+(died|was\s+gone|were\s+gone|disappeared)\b"#,
        #"\b(won't|wont|will\s+not)\s+be\s+(a\s+burden|around|here)\s+(much\s+|for\s+much\s+|for\s+)?longer\b"#,
        // Hurting oneself on purpose (real accidents are left out, see `mishap`).
        #"(?<!accidentally )(?<!accidently )\b(hurt|hurting|harm|harming|harmed|cut|cutting|burn|burning|burned|burnt|starve|starving|starved)\s+my\s?self\b(?!(\s+(with|on)\s+(a|an|the|my)\s+\w+)?\s+"# + mishap + ")",
        // "I've been cutting again", "I started cutting again", "I can't stop cutting."
        #"\b(i'?ve|i\s+have|i'?m|i\s+am|i)\s+(been\s+|started\s+|starting\s+|begun\s+|gone\s+back\s+to\s+|back\s+to\s+)?cutting\s+again\b"#,
        #"\b(can't|cant|cannot)\s+stop\s+cutting(?=\s*$|\s*[.!?,;])"#,
        #"\b(hang|hanging|shoot|shooting|drown|drowning|poison|poisoning|stab|stabbing)\s+my\s?self\b"#,
        #"\bslit(ting)?\s+my\s+wrists?\b"#,
        #"\b(jump|jumping)\s+(off|from)\s+(a|the|this)\s+(bridge|building|roof|cliff|balcony)\b"#,
        // Pills: taken, saved up, or asked about in a way that only fits an overdose.
        #"\b(took|taken|swallowed|(going\s+to|gonna|about\s+to|want\s+to|wanna)\s+(take|swallow))\s+(a\s+(bunch|handful|lot|ton|bottle|box)\s+of|all\s+(of\s+)?(my|the)|too\s+many|way\s+too\s+many|so\s+many)\s+(\w+\s+)?(pills|meds|medications?|medicines?|tablets|painkillers)\b"#,
        #"\b(pills|meds|tablets|painkillers)\s+ready\b"#,
        #"\b(stockpil\w*|hoard\w*|sav(e|ed|ing))\s+(up\s+)?(my\s+|all\s+my\s+|the\s+)?(pills|meds|medications?|tablets|painkillers)\b"#,
        #"\b(lethal|fatal|deadly)\s+(dose|amount|overdose)\b"#,
        #"\bhow\s+many\s+(of\s+(my|these|the|those)\s+)?(\w+\s+)?(pills|meds|tablets|tylenol|advil|aspirin|ibuprofen|painkillers)\s+(would|will|does|do)\s+it\s+take\b"#,
        // Being in danger from someone.
        #"\b(i'?m|i\s+am)\s+(in\s+danger(?!\s+of\b)|not\s+safe(?!\s+to\b))"#,
        #"\b(don't|dont|do\s+not)\s+feel\s+safe\s+(at\s+home|with\s+(him|her|them|my\s+\w+))\b"#,
        #"\b(he|she|they|husband|wife|partner|boyfriend|girlfriend|fiance|fiancee|ex|dad|father|stepdad|stepfather|mom|mum|mother|stepmom|stepmother|parents|brother|sister|son|daughter|roommate|someone|somebody)('s|'re|\s+is|\s+are|\s+was|\s+keeps|\s+kept|\s+has|\s+have)?(\s+been)?(\s+(always|still|sometimes|often|just|really|even|again|started|starts))?\s+(hits|hit|beats|chokes|choked|strangles|strangled|kicks|slaps|slapped|punches|punched|shoves|abuses|abused|rapes|raped|hurts|hitting|beating|choking|strangling|kicking|slapping|punching|shoving|abusing|hurting)\s+me\b(?!\s+(at|in|to|up|out|off)\b|\s+with\s+(a\s+|an\s+|the\s+|some\s+|this\s+|that\s+)?(surprise|question|joke|pun|bill|ticket|fine|news|text|message|call|request|deadline|project|offer|compliment|idea|story)\b)"#,
        #"\bbeat(s|ing)?\s+me\s+up\b"#,
        #"\bthreaten(s|ed|ing)?\s+to\s+(kill|hurt|beat|stab|shoot)\s+me\b"#,
        #"\b(scared|afraid|terrified)\s+(that\s+)?(he|she|they)('ll|\s+will|\s+is\s+going\s+to|'s\s+going\s+to|\s+are\s+going\s+to|'re\s+going\s+to|\s+gonna|\s+might|\s+could|\s+would)\s+(kill|hurt)\s+me\b"#,
    ].compactMap { BrainText.regex($0) }

    /// What can follow "cut myself", "burned myself" or "hurt myself" in a real accident: "shaving",
    /// "on the stove", "at the gym". "On purpose" and "on my arms" don't count.
    private static let mishap: String = {
        let chore = #"(shaving|cooking|chopping|slicing|baking|cleaning|gardening|hiking|skiing|skating|climbing|running|dancing|lifting|exercising|training|working(\s+out)?|laughing|sneezing|coughing|playing\s+\w+|fixing\s+\w+|making\s+\w+|opening\s+\w+|cutting\s+\w+)"#
        let bodyPart = #"(arms?|wrists?|legs?|thighs?|stomach|skin|hips?|chest|face|hands?|fingers?|neck)"#
        return #"(by\s+accident|accidentally|((while|when)\s+(i\s+was\s+)?)?"# + chore
            + #"|on\s+(a|an|the|some)\s+(?!"# + bodyPart + #"\b)\w+|at\s+(the|work|practice|training)\b|in\s+the\s+(kitchen|garden|yard|shop|workshop|gym))"#
    }()

    /// Words that are a crisis when someone says them about themselves (see `aboutSomeoneElse`).
    private static let mentions: [NSRegularExpression] = [
        #"\bsu[ie]?[cs]+i?d(e|al|ial|el|le)?s?\b"#,
        #"\bsewer\s*-?\s*slide\b"#,
        #"\b(overdose|overdoses|overdosing|overdosed)\b"#,
        #"\bself[\s-]?(harm|harms|harming|harmed|injury|injuries|injure|injuring)\b"#,
        #"\bun-?aliv(e|ed|ing)\b"#,
    ].compactMap { BrainText.regex($0) }

    private static let topics: [NSRegularExpression] = [
        #"\bsuicide\s+(prevention|hotline|awareness|lifeline|line|rates?|statistics|stats|survivors?|research)\b"#,
        #"\b(movie|film|documentary|book|novel|show|series|episode|song|article|podcast|video|class|lecture|talk|essay|paper|report|course|training)\s+(about|on)\s+(suicide|self[\s-]?harm|overdoses?)\b"#,
        // Grief for someone else ("my friend took her own life") gets resources softly.
        #"\b(took|take|taking|taken)\s+(his|her|their)\s+own\s+li(fe|ves)\b"#,
    ].compactMap { BrainText.regex($0) }

    private static let concern: [NSRegularExpression] = [
        #"\b(nobody|no\s+one|noone)\s+would\s+(miss|notice)\s+me\b"#,
        #"\b(want|wanna)\s+(to\s+)?disappear\s+(forever|for\s+good)\b"#,
        #"\bwish\s+i\s+could\s+(disappear|vanish)\b"#,
        #"\b(can't|cant|cannot|can\s+not)\s+(take|do|handle)\s+(it|this)\s+any\s?more\b"#,
        #"\b(i'?m|i\s+am|feel\s+like|be|being)\s+(just\s+|such\s+|nothing\s+but\s+)?a\s+burden\b"#,
        #"\b(scared|afraid|terrified)\s+to\s+go\s+home\b"#,
        #"\babusive\s+(relationship|partner|husband|wife|boyfriend|girlfriend|marriage|home|parents?|dad|mom|father|mother)\b"#,
    ].compactMap { BrainText.regex($0) }

    private static let harmless: [NSRegularExpression] = [
        #"\bsuicide\s+(squad|doors?|kings?|blonde|sprints?|drills?|runs?|missions?|burpees?|wings)\b"#,
        #"\bvirgin\s+suicides\b"#,
        #"\bkill(ing|ed)?\s+my\s?self\s+(laugh\w*|trying|working|studying)\b"#,
        #"\bcut(ting)?\s+my\s?self\s+(a|an|some|off|short|loose|slack|out|free)\b"#,
        #"\bburn(ing|ed|t)?\s+my\s?self\s+out\b"#,
        #"\bshoot(ing)?\s+my\s?self\s+in\s+the\s+foot\b"#,
        #"\bhills?\s+(that\s+)?(i|i'd|i'll|i'm|im)\s+(\w+\s+){0,3}?die\s+on\b"#,
        #"\b(die|dye)\s+(my|her|his|their|the|our)\s+hair\b"#,
        #"\boverdos(e|ed|ing)\s+on\s+(coffee|caffeine|sugar|chocolate|cuteness|candy|carbs|sweets|cookies|tv|netflix|anime|fun|vitamin\s+c)\b"#,
    ].compactMap { BrainText.regex($0) }

    // MARK: - Helpers

    private static func normalize(_ text: String) -> String {
        BrainText.oneLine(BrainText.fold(text).replacingOccurrences(of: "\u{200B}", with: ""))
    }

    private static let negators: Set<String> = ["never", "not", "don't", "dont", "won't", "wont", "wouldn't", "wouldnt",
                                                "didn't", "didnt", "isn't", "isnt", "wasn't", "wasnt", "ain't", "aint",
                                                "stopped", "quit"]
    /// Small words that may stand between a negator and what it negates ("not really going to", "no way I'd").
    private static let bridgeWords: Set<String> = ["going", "to", "gonna", "ever", "really", "actually", "even", "truly",
                                                   "seriously", "want", "wanna", "trying", "planning", "be", "been",
                                                   "feeling", "feel", "i", "i'd", "i'll", "i'm", "im", "would", "will"]
    private static let clauseWords: Set<String> = ["but", "and", "so", "because", "though", "although"]

    /// The words of the clause just before `index`. A comma or "but"/"and"... starts a new clause.
    private static func clauseBefore(_ text: String, _ index: String.Index) -> [String] {
        var clause = text[..<index]
        if let stop = clause.lastIndex(where: { ".,;:!?".contains($0) }) {
            clause = clause[clause.index(after: stop)...]
        }
        let words = clause.split(separator: " ").map(String.init)
        guard let j = words.lastIndex(where: { clauseWords.contains($0) }) else { return words }
        return Array(words[(j + 1)...])
    }

    /// True when a negator governs the match with only small words between them: "I would never kill myself",
    /// "I'm not going to hurt myself", "I used to cut myself", "no way I'd". Typed without a comma,
    /// "I'm not okay I want to die" is still a crisis: "okay" stands between "not" and the rest.
    private static func isNegated(_ text: String, before index: String.Index) -> Bool {
        let words = clauseBefore(text, index)
        for i in words.indices.reversed() {
            let word = words[i]
            let previous = i > words.startIndex ? words[i - 1] : ""
            if negators.contains(word) || (word == "to" && previous == "used") || (word == "way" && previous == "no") {
                return true
            }
            if !bridgeWords.contains(word) { return false }
        }
        return false
    }

    private static let me = BrainText.regex(#"\b(i|i'm|im|i've|ive|i'd|i'll|me|myself)\b"#)
    private static let someoneElse = BrainText.regex(#"\b(he|she|they|he's|she's|they're|his|her|their|him|them|someone|somebody|my\s+(friend|best\s+friend|mom|mum|mother|dad|father|brother|sister|son|daughter|wife|husband|partner|girlfriend|boyfriend|cousin|aunt|uncle|grandma|grandpa|grandmother|grandfather|roommate|coworker|neighbou?r|kid|child))\b"#)

    /// True when the nearest person named before the match, in the same clause, is someone else:
    /// "my brother is suicidal", "she overdosed last year". "I feel suicidal" is about the writer.
    private static func aboutSomeoneElse(_ text: String, before index: String.Index) -> Bool {
        let clause = clauseBefore(text, index).joined(separator: " ")
        func lastMatch(_ r: NSRegularExpression?) -> Int {
            guard let r, let m = r.matches(in: clause, range: BrainText.fullRange(clause)).last else { return -1 }
            return m.range.location
        }
        return lastMatch(someoneElse) > lastMatch(me)
    }
}
