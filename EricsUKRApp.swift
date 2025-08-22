import SwiftUI
import UIKit
import AVFoundation
import AudioToolbox

// MARK: - Theme (Ukrainian colors)
struct AppTheme {
    static let flagBlue   = Color(red: 0/255, green: 87/255, blue: 184/255)
    static let flagYellow = Color(red: 255/255, green: 215/255, blue: 0/255)
    static let softBlue   = flagBlue.opacity(0.12)
    static let softYellow = flagYellow.opacity(0.12)
}

// MARK: - Data Models
struct VocabItem: Identifiable, Equatable {
    let id = UUID()
    let word: String
    let meaning: String
    let gender: String
    let categories: [String]
}
enum QuizPhase { case meaning, gender, done }

// Per-card UI/score state so going back doesn’t double-score
struct CardState: Equatable {
    var selectedMeaning: String? = nil
    var selectedGender: String? = nil
    var meaningWasCorrect: Bool? = nil
    var genderWasCorrect: Bool? = nil
    var phase: QuizPhase = .meaning
    var scoreGrantedMeaning: Bool = false
    var scoreGrantedGender: Bool = false
}

// MARK: - Settings
struct QuizSettings {
    @AppStorage("hapticsEnabled") var hapticsEnabled: Bool = true
    @AppStorage("shuffleEnabled") var shuffleEnabled: Bool = true
    @AppStorage("activeCategories") var activeCategoriesRaw: String = "" // CSV
    @AppStorage("sessionLength") var sessionLength: Int = 20  // 10, 20, 50, or 0 for All

    // TTS
    @AppStorage("speechEnabled") var speechEnabled: Bool = true
    @AppStorage("speechRate") var speechRate: Double = 0.5 // 0.2...0.9 UI range

    // Sounds
    @AppStorage("answerSoundsEnabled") var answerSoundsEnabled: Bool = true

    // UI
    @AppStorage("showInstructions") var showInstructions: Bool = true
    @AppStorage("hasSeenWelcome") var hasSeenWelcome: Bool = false

    var activeCategories: Set<String> {
        get {
            let trimmed = activeCategoriesRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return Set(trimmed.filter { !$0.isEmpty })
        }
        set { activeCategoriesRaw = newValue.sorted().joined(separator: ",") }
    }
}

// MARK: - Haptics & Sounds
struct Haptics {
    static func success(enabled: Bool) { guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func error(enabled: Bool) { guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
struct SoundFX {
    static let correctID: SystemSoundID = 1110
    static let wrongID: SystemSoundID = 1107
    static func playCorrect(enabled: Bool) { guard enabled else { return }; AudioServicesPlaySystemSound(correctID) }
    static func playWrong(enabled: Bool)   { guard enabled else { return }; AudioServicesPlaySystemSound(wrongID) }
}

// MARK: - Speech (Text-to-Speech)
final class SpeechManager {
    static let shared = SpeechManager()
    private let synth = AVSpeechSynthesizer()
    func speak(_ text: String, enabled: Bool, rate sliderRate: Double) {
        guard enabled else { return }
        let avRate = AVSpeechUtteranceDefaultSpeechRate + Float((sliderRate - 0.5)) * 0.4
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "uk-UA") ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
        u.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, avRate))
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }
}

// MARK: - ViewModel
final class QuizViewModel: ObservableObject {
    // Settings
    @Published var settings = QuizSettings()

    // Data
    @Published private(set) var fullDeck: [VocabItem] = []
    @Published private(set) var workingDeck: [VocabItem] = []

    // Quiz State
    @Published var currentIndex = 0
    @Published var phase: QuizPhase = .meaning
    @Published var score: Double = 0
    @Published var totalAsked: Int = 0
    @Published var meaningOptions: [String] = []
    @Published var selectedMeaning: String? = nil
    @Published var selectedGender: String? = nil

    // Per-card saved state
    private var stateByID: [UUID: CardState] = [:]

    // Back history (≤ 5)
    private var backHistory: [Int] = []
    private let backLimit = 5

    // Categories order
    let allCategories: [String] = [
        "Objects", "Food", "Family", "People", "Professions", "Time",
        "Weather", "Nature", "Places", "Transport", "School", "Abstract", "Home"
    ]

    init() {
        loadWords()
        rebuildWorkingDeck()
        ensureStateAndStart()
    }

    func loadWords() {
        var items: [VocabItem] = []

        // Masculine
        items += [
            VocabItem(word: "стіл", meaning: "table",   gender: "masculine", categories: ["Objects","Home"]),
            VocabItem(word: "телефон", meaning: "phone", gender: "masculine", categories: ["Objects"]),
            VocabItem(word: "стілець", meaning: "chair", gender: "masculine", categories: ["Objects","Home"]),
            VocabItem(word: "будинок", meaning: "house", gender: "masculine", categories: ["Places","Home"]),
            VocabItem(word: "хліб", meaning: "bread",    gender: "masculine", categories: ["Food"]),
            VocabItem(word: "чай", meaning: "tea",       gender: "masculine", categories: ["Food"]),
            VocabItem(word: "суп", meaning: "soup",      gender: "masculine", categories: ["Food"]),
            VocabItem(word: "ніж", meaning: "knife",     gender: "masculine", categories: ["Objects","Food"]),
            VocabItem(word: "день", meaning: "day",      gender: "masculine", categories: ["Time"]),
            VocabItem(word: "вечір", meaning: "evening", gender: "masculine", categories: ["Time"]),
            VocabItem(word: "ранок", meaning: "morning", gender: "masculine", categories: ["Time"]),
            VocabItem(word: "тиждень", meaning: "week",  gender: "masculine", categories: ["Time"]),
            VocabItem(word: "місяць", meaning: "month",  gender: "masculine", categories: ["Time"]),
            VocabItem(word: "рік", meaning: "year",      gender: "masculine", categories: ["Time"]),
            VocabItem(word: "хлопець", meaning: "boy",   gender: "masculine", categories: ["People","Family"]),
            VocabItem(word: "чоловік", meaning: "man",   gender: "masculine", categories: ["People","Family"]),
            VocabItem(word: "брат", meaning: "brother",  gender: "masculine", categories: ["Family"]),
            VocabItem(word: "дядько", meaning: "uncle",  gender: "masculine", categories: ["Family"]),
            VocabItem(word: "друг", meaning: "friend (male)", gender: "masculine", categories: ["People"]),
            VocabItem(word: "вчитель", meaning: "teacher (male)", gender: "masculine", categories: ["Professions","School"]),
            VocabItem(word: "лікар", meaning: "doctor",  gender: "masculine", categories: ["Professions"]),
            VocabItem(word: "поліцейський", meaning: "policeman", gender: "masculine", categories: ["Professions"]),
            VocabItem(word: "магазин", meaning: "shop",  gender: "masculine", categories: ["Places"]),
            VocabItem(word: "ринок", meaning: "market",  gender: "masculine", categories: ["Places"]),
            VocabItem(word: "парк", meaning: "park",     gender: "masculine", categories: ["Places","Nature"]),
            VocabItem(word: "поїзд", meaning: "train",   gender: "masculine", categories: ["Transport"]),
            VocabItem(word: "автобус", meaning: "bus",   gender: "masculine", categories: ["Transport"]),
            VocabItem(word: "літак", meaning: "airplane", gender: "masculine", categories: ["Transport"]),
            VocabItem(word: "комп’ютер", meaning: "computer", gender: "masculine", categories: ["Objects"]),
            VocabItem(word: "світ", meaning: "world",    gender: "masculine", categories: ["Abstract"]),
            VocabItem(word: "день народження", meaning: "birthday", gender: "masculine", categories: ["Time","Abstract"]),
            VocabItem(word: "сон", meaning: "sleep",     gender: "masculine", categories: ["Abstract"]),
            VocabItem(word: "урок", meaning: "lesson",   gender: "masculine", categories: ["School"]),
            VocabItem(word: "клас", meaning: "classroom", gender: "masculine", categories: ["School"]),
            VocabItem(word: "спорт", meaning: "sport",   gender: "masculine", categories: ["Abstract"]),
            VocabItem(word: "дощ", meaning: "rain",      gender: "masculine", categories: ["Weather","Nature"]),
            VocabItem(word: "сніг", meaning: "snow",     gender: "masculine", categories: ["Weather","Nature"]),
            VocabItem(word: "вітер", meaning: "wind",    gender: "masculine", categories: ["Weather","Nature"]),
            VocabItem(word: "ліс", meaning: "forest",    gender: "masculine", categories: ["Nature"]),
            VocabItem(word: "берег", meaning: "shore",   gender: "masculine", categories: ["Nature","Places"])
        ]

        // Feminine
        items += [
            VocabItem(word: "книга", meaning: "book",    gender: "feminine", categories: ["Objects","School"]),
            VocabItem(word: "ручка", meaning: "pen",     gender: "feminine", categories: ["Objects","School"]),
            VocabItem(word: "газета", meaning: "newspaper", gender: "feminine", categories: ["Objects"]),
            VocabItem(word: "ложка", meaning: "spoon",   gender: "feminine", categories: ["Objects","Food"]),
            VocabItem(word: "тарілка", meaning: "plate", gender: "feminine", categories: ["Objects","Food"]),
            VocabItem(word: "чашка", meaning: "cup",     gender: "feminine", categories: ["Objects","Food"]),
            VocabItem(word: "ніч", meaning: "night",     gender: "feminine", categories: ["Time"]),
            VocabItem(word: "осінь", meaning: "autumn",  gender: "feminine", categories: ["Time","Weather"]),
            VocabItem(word: "весна", meaning: "spring",  gender: "feminine", categories: ["Time","Weather"]),
            VocabItem(word: "зима", meaning: "winter",   gender: "feminine", categories: ["Time","Weather"]),
            VocabItem(word: "дівчина", meaning: "girl",  gender: "feminine", categories: ["People","Family"]),
            VocabItem(word: "жінка", meaning: "woman",   gender: "feminine", categories: ["People","Family"]),
            VocabItem(word: "сестра", meaning: "sister", gender: "feminine", categories: ["Family"]),
            VocabItem(word: "тітка", meaning: "aunt",    gender: "feminine", categories: ["Family"]),
            VocabItem(word: "подруга", meaning: "friend (female)", gender: "feminine", categories: ["People"]),
            VocabItem(word: "вчителька", meaning: "teacher (female)", gender: "feminine", categories: ["Professions","School"]),
            VocabItem(word: "мама", meaning: "mom",      gender: "feminine", categories: ["Family"]),
            VocabItem(word: "донька", meaning: "daughter", gender: "feminine", categories: ["Family"]),
            VocabItem(word: "родина", meaning: "family", gender: "feminine", categories: ["Family"]),
            VocabItem(word: "вулиця", meaning: "street", gender: "feminine", categories: ["Places"]),
            VocabItem(word: "площа", meaning: "square",  gender: "feminine", categories: ["Places"]),
            VocabItem(word: "кімната", meaning: "room",  gender: "feminine", categories: ["Places","Home"]),
            VocabItem(word: "кухня", meaning: "kitchen", gender: "feminine", categories: ["Places","Home"]),
            VocabItem(word: "школа", meaning: "school",  gender: "feminine", categories: ["School","Places"]),
            VocabItem(word: "бібліотека", meaning: "library", gender: "feminine", categories: ["School","Places"]),
            VocabItem(word: "лікарня", meaning: "hospital", gender: "feminine", categories: ["Places"]),
            VocabItem(word: "країна", meaning: "country", gender: "feminine", categories: ["Places","Abstract"]),
            VocabItem(word: "музика", meaning: "music",  gender: "feminine", categories: ["Abstract"]),
            VocabItem(word: "мова", meaning: "language", gender: "feminine", categories: ["Abstract"]),
            VocabItem(word: "історія", meaning: "history", gender: "feminine", categories: ["Abstract"]),
            VocabItem(word: "робота", meaning: "job/work", gender: "feminine", categories: ["Abstract"]),
            VocabItem(word: "пісня", meaning: "song",    gender: "feminine", categories: ["Abstract"]),
            VocabItem(word: "їжа", meaning: "food",      gender: "feminine", categories: ["Food"]),
            VocabItem(word: "вода", meaning: "water",    gender: "feminine", categories: ["Food"]),
            VocabItem(word: "любов", meaning: "love",    gender: "feminine", categories: ["Abstract"])
        ]

        // Neuter
        items += [
            VocabItem(word: "вікно", meaning: "window",  gender: "neuter", categories: ["Objects","Home"]),
            VocabItem(word: "море", meaning: "sea",      gender: "neuter", categories: ["Nature","Places"]),
            VocabItem(word: "місто", meaning: "city",    gender: "neuter", categories: ["Places"]),
            VocabItem(word: "село", meaning: "village",  gender: "neuter", categories: ["Places"]),
            VocabItem(word: "поле", meaning: "field",    gender: "neuter", categories: ["Nature"]),
            VocabItem(word: "озеро", meaning: "lake",    gender: "neuter", categories: ["Nature"]),
            VocabItem(word: "небо", meaning: "sky",      gender: "neuter", categories: ["Nature"]),
            VocabItem(word: "сонце", meaning: "sun",     gender: "neuter", categories: ["Nature"]),
            VocabItem(word: "слово", meaning: "word",    gender: "neuter", categories: ["Abstract"]),
            VocabItem(word: "ім’я", meaning: "name",     gender: "neuter", categories: ["Abstract"]),
            VocabItem(word: "яблуко", meaning: "apple",  gender: "neuter", categories: ["Food"]),
            VocabItem(word: "молоко", meaning: "milk",   gender: "neuter", categories: ["Food"]),
            VocabItem(word: "яйце", meaning: "egg",      gender: "neuter", categories: ["Food"]),
            VocabItem(word: "м’ясо", meaning: "meat",    gender: "neuter", categories: ["Food"]),
            VocabItem(word: "цукор", meaning: "sugar",   gender: "neuter", categories: ["Food"]),
            VocabItem(word: "кіно", meaning: "cinema",   gender: "neuter", categories: ["Places"]),
            VocabItem(word: "радіо", meaning: "radio",   gender: "neuter", categories: ["Objects"]),
            VocabItem(word: "метро", meaning: "metro",   gender: "neuter", categories: ["Transport","Places"]),
            VocabItem(word: "кафе", meaning: "café",     gender: "neuter", categories: ["Places","Food"]),
            VocabItem(word: "завдання", meaning: "task", gender: "neuter", categories: ["School","Abstract"]),
            VocabItem(word: "питання", meaning: "question", gender: "neuter", categories: ["School","Abstract"]),
            VocabItem(word: "життя", meaning: "life",    gender: "neuter", categories: ["Abstract"]),
            VocabItem(word: "вік", meaning: "age",       gender: "neuter", categories: ["Abstract"]),
            VocabItem(word: "серце", meaning: "heart",   gender: "neuter", categories: ["Abstract"]),
            VocabItem(word: "обличчя", meaning: "face",  gender: "neuter", categories: ["People"])
        ]

        fullDeck = items
    }

    func rebuildWorkingDeck() {
        var deck = fullDeck
        let selected = settings.activeCategories
        if !selected.isEmpty {
            deck = deck.filter { !$0.categories.isEmpty && !selected.isDisjoint(with: Set($0.categories)) }
        }
        deck = settings.shuffleEnabled ? deck.shuffled() : deck

        // NEW: enforce session length
        let limit = settings.sessionLength  // 10 / 20 / 50 / 0 (All)
        if limit > 0, deck.count > limit {
            workingDeck = Array(deck.prefix(limit))
        } else {
            workingDeck = deck
        }

        currentIndex = 0
        backHistory.removeAll()
        stateByID.removeAll()
        score = 0
        totalAsked = 0
    }

    // Public so SettingsView can call it
    func ensureStateAndStart() {
        if let id = current?.id, stateByID[id] == nil { stateByID[id] = CardState() }
        restoreStateToUI()
        makeMeaningOptions()
    }

    var current: VocabItem? {
        guard workingDeck.indices.contains(currentIndex) else { return nil }
        return workingDeck[currentIndex]
    }

    var progress: Double {
        guard !workingDeck.isEmpty else { return 0 }
        let base = Double(currentIndex) / Double(workingDeck.count)
        switch phase {
        case .meaning: return base
        case .gender:  return min(1.0, base + (1.0 / Double(workingDeck.count)) * 0.5)
        case .done:    return min(1.0, base + (1.0 / Double(workingDeck.count)))
        }
    }

    private func makeMeaningOptions() {
        meaningOptions = []
        guard let cur = current else { return }
        var options = Set([cur.meaning])
        var pool = workingDeck.shuffled()
        while options.count < 4, let next = pool.popLast() {
            if next.meaning != cur.meaning { options.insert(next.meaning) }
        }
        meaningOptions = Array(options).shuffled()
    }

    private func restoreStateToUI() {
        guard let id = current?.id else { return }
        let st = stateByID[id] ?? CardState()
        selectedMeaning = st.selectedMeaning
        selectedGender = st.selectedGender
        phase = st.phase
    }

    private func updateState(_ change: (inout CardState) -> Void) {
        guard let id = current?.id else { return }
        var st = stateByID[id] ?? CardState()
        change(&st)
        stateByID[id] = st
    }

    func submitMeaning(_ choice: String) {
        guard phase == .meaning, let cur = current else { return }
        updateState { st in
            st.selectedMeaning = choice
            let isCorrect = (choice == cur.meaning)
            st.meaningWasCorrect = isCorrect
            if isCorrect && !st.scoreGrantedMeaning {
                score += 0.5
                st.scoreGrantedMeaning = true
                Haptics.success(enabled: settings.hapticsEnabled)
                SoundFX.playCorrect(enabled: settings.answerSoundsEnabled)
            } else if !isCorrect {
                Haptics.error(enabled: settings.hapticsEnabled)
                SoundFX.playWrong(enabled: settings.answerSoundsEnabled)
            }
            st.phase = .gender
        }
        restoreStateToUI()
    }

    func submitGender(_ choice: String) {
        guard phase == .gender, let cur = current else { return }
        updateState { st in
            st.selectedGender = choice
            let isCorrect = (choice == cur.gender)
            st.genderWasCorrect = isCorrect
            if isCorrect && !st.scoreGrantedGender {
                score += 0.5
                st.scoreGrantedGender = true
                Haptics.success(enabled: settings.hapticsEnabled)
                SoundFX.playCorrect(enabled: settings.answerSoundsEnabled)
            } else if !isCorrect {
                Haptics.error(enabled: settings.hapticsEnabled)
                SoundFX.playWrong(enabled: settings.answerSoundsEnabled)
            }
            if st.phase != .done { totalAsked += 1 }
            st.phase = .done
        }
        restoreStateToUI()
    }

    func next() {
        if backHistory.last != currentIndex {
            backHistory.append(currentIndex)
            if backHistory.count > backLimit { backHistory.removeFirst(backHistory.count - backLimit) }
        }
        if currentIndex + 1 < workingDeck.count {
            currentIndex += 1
        } else {
            rebuildWorkingDeck()
        }
        if let id = current?.id, stateByID[id] == nil { stateByID[id] = CardState() }
        restoreStateToUI()
        makeMeaningOptions()
    }

    func previous() {
        guard let prevIndex = backHistory.popLast() else { return }
        currentIndex = prevIndex
        if let id = current?.id, stateByID[id] == nil { stateByID[id] = CardState() }
        restoreStateToUI()
        makeMeaningOptions()
    }

    var canGoBack: Bool { !backHistory.isEmpty }

    var scoreText: String { String(format: "Score: %.1f / %d", score, totalAsked) }
    var counterText: String { workingDeck.isEmpty ? "" : "Word \(currentIndex + 1) of \(workingDeck.count)" }

    func resetScore() {
        score = 0; totalAsked = 0
        for (id, var st) in stateByID {
            st.scoreGrantedMeaning = false
            st.scoreGrantedGender = false
            stateByID[id] = st
        }
    }

    // TTS proxy
    func speakCurrentWord() {
        guard let w = current?.word else { return }
        SpeechManager.shared.speak(w, enabled: settings.speechEnabled, rate: settings.speechRate)
    }
}

// MARK: - Welcome / Gender Guide
struct WelcomeView: View {
    var dismissAction: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Flag header
                    HStack(spacing: 0) { AppTheme.flagBlue; AppTheme.flagYellow }
                        .frame(height: 8).mask(RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, 2)

                    Text("Welcome! Ласкаво просимо!")
                        .font(.largeTitle).fontWeight(.bold)

                    Text("A quick guide to **Ukrainian noun gender** before you practice.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Group {
                        Text("**Masculine (чол. рід)**")
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("• Usually ends in a **consonant** or **-й**: _стіл_, _хліб_, _телефон_.")
                            Text("• Some nouns ending in **-ь** are masculine: _кінь_ “horse”, _день_ “day”.")
                            Text("• Nouns for **male people** are masculine: _хлопець_ “boy”, _чоловік_ “man”.")
                            Text("• ⚠️ A few masculine nouns end in **-о**: _тато_ “dad”, _дядько_ “uncle”.")
                        }
                    }

                    Group {
                        Text("**Feminine (жін. рід)**")
                            .font(.headline).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("• Commonly ends in **-а / -я**: _книга_, _вода_, _історія_.")
                            Text("• Many nouns ending in **-ь** are feminine: _ніч_ “night”, _любов_ “love”, _сіль_ “salt”.")
                            Text("• Abstract **-ість** words are feminine: _швидкість_ “speed”, _молодість_ “youth”.")
                            Text("• Female people/roles are feminine: _жінка_, _вчителька_.")
                        }
                    }

                    Group {
                        Text("**Neuter (сер. рід)**")
                            .font(.headline).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("• Often ends in **-о / -е**: _вікно_, _море_, _місто_.")
                            Text("• Some end in **-я** (special pattern): _ім’я_ “name”, _плем’я_ “tribe_.")
                            Text("• Many **-ко** diminutives are neuter: _яблуко_ “apple”.")
                        }
                    }

                    Group {
                        Text("**Tips**")
                            .font(.headline).padding(.top, 6)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("• Endings are great **rules of thumb**, but there are **exceptions**.")
                            Text("• When in doubt, check a dictionary; your ear will improve with exposure.")
                            Text("• This app quizzes **meaning first**, then **gender** to reinforce both.")
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ready to practice?")
                            .font(.headline).padding(.top, 10)
                        Text("You can change settings (shuffle, sounds, pronunciation, categories) anytime with the gear icon.")
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("Gender Guide")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismissAction()
                    } label: {
                        Text("Start practicing")
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }
}

// MARK: - Settings UI
struct SettingsView: View {
    @ObservedObject var vm: QuizViewModel
    @Environment(\.dismiss) var dismiss
    @State private var showWelcome = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    // Flag header strip
                    HStack(spacing: 0) { AppTheme.flagBlue; AppTheme.flagYellow }
                        .frame(height: 6).mask(RoundedRectangle(cornerRadius: 6))
                        .padding(.vertical, 6)
                    Text("Customize your practice and learn how the app works.")
                        .font(.subheadline).foregroundColor(.secondary)
                }

                Section(header: Text("Instructions")) {
                    Toggle("Show quick instructions", isOn: $vm.settings.showInstructions)
                    Button {
                        showWelcome = true
                    } label: {
                        Label("Open Gender Guide", systemImage: "book.fill")
                    }
                }

                Section(header: Text("Feedback")) {
                    Toggle("Haptics (ding/buzz feel)", isOn: $vm.settings.hapticsEnabled)
                    Toggle("Answer sounds", isOn: $vm.settings.answerSoundsEnabled)
                    Toggle("Pronounce word (Ukrainian)", isOn: $vm.settings.speechEnabled)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Speech rate")
                            Spacer()
                            Text(String(format: "%.2f", vm.settings.speechRate))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $vm.settings.speechRate, in: 0.2...0.9)
                    }
                }

                Section(header: Text("Session Length")) {
                    Picker("Number of words", selection: $vm.settings.sessionLength) {
                        Text("10").tag(10)
                        Text("20").tag(20)
                        Text("50").tag(50)
                        Text("All").tag(0)   // 0 means no limit
                    }
                    .pickerStyle(.segmented)

                    Text(vm.settings.sessionLength == 0
                         ? "Practice with all available words."
                         : "Practice with \(vm.settings.sessionLength) words per session.")
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    Button("Apply to current deck") {
                        vm.rebuildWorkingDeck()
                        vm.ensureStateAndStart()
                    }
                }
                
                Section(header: Text("Deck Behavior")) {
                    Toggle("Shuffle deck", isOn: $vm.settings.shuffleEnabled)
                        .onChange(of: vm.settings.shuffleEnabled) {
                            vm.rebuildWorkingDeck()
                            vm.ensureStateAndStart()
                        }
                }

                Section(header: Text("Categories")) {
                    CategoryGrid(vm: vm)
                }

                if !vm.settings.activeCategories.isEmpty {
                    Section(header: Text("Active Filters")) {
                        Text(vm.settings.activeCategories.sorted().joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        vm.rebuildWorkingDeck()
                        vm.ensureStateAndStart()
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView {
                showWelcome = false
            }
            .presentationDetents([.large])
        }
    }
}

struct CategoryGrid: View {
    @ObservedObject var vm: QuizViewModel
    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(vm.allCategories, id: \.self) { cat in
                let selected = vm.settings.activeCategories.contains(cat)
                Button {
                    var set = vm.settings.activeCategories
                    if selected { set.remove(cat) } else { set.insert(cat) }
                    vm.settings.activeCategories = set
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        Text(cat).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 10)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selected ? AppTheme.softBlue : Color(.systemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(selected ? AppTheme.flagBlue : Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Main Quiz UI
struct ContentView: View {
    @ObservedObject var viewModel: QuizViewModel
    @State private var showingSettings = false
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showWelcome = false

    var body: some View {
        VStack(spacing: 14) {
            // Flag stripe header
            HStack(spacing: 0) { AppTheme.flagBlue; AppTheme.flagYellow }
                .frame(height: 6)
                .mask(RoundedRectangle(cornerRadius: 6))
                .padding(.top, 6)

            // Header row
            HStack {
                Button {
                    viewModel.previous()
                } label: {
                    Image(systemName: "chevron.left")
                        .imageScale(.large)
                        .padding(8)
                }
                .disabled(!viewModel.canGoBack)
                .opacity(viewModel.canGoBack ? 1 : 0.35)
                .accessibilityLabel("Previous word")

                Spacer()
                Text(viewModel.scoreText).font(.headline)
                Spacer()

                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .imageScale(.large)
                        .padding(8)
                }
                .accessibilityLabel("Settings")
            }

            // Counter & progress
            HStack {
                Text(viewModel.counterText).font(.subheadline).foregroundColor(.secondary)
                Spacer()
            }

            ProgressView(value: viewModel.progress)
                .progressViewStyle(.linear)
                .tint(AppTheme.flagBlue)

            if let item = viewModel.current {
                // Word + speaker
                HStack(spacing: 8) {
                    Text(item.word)
                        .font(.system(size: 44, weight: .bold))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Button { viewModel.speakCurrentWord() } label: {
                        Image(systemName: "speaker.wave.2.fill")
                            .imageScale(.large)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(AppTheme.softBlue))
                    }
                    .accessibilityLabel("Pronounce word")
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)

                // Step 1: Meaning
                if viewModel.phase == .meaning {
                    Text("Select the meaning").font(.subheadline).foregroundColor(.secondary)
                    ForEach(viewModel.meaningOptions, id: \.self) { option in
                        Button { viewModel.submitMeaning(option) } label: {
                            Text(option)
                                .padding()
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(option == viewModel.selectedMeaning
                                              ? (option == item.meaning ? Color.green.opacity(0.2) : Color.red.opacity(0.18))
                                              : Color(.systemBackground))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(option == viewModel.selectedMeaning
                                                ? (option == item.meaning ? Color.green : Color.red)
                                                : Color.secondary.opacity(0.25), lineWidth: 1)
                                )
                        }
                        .disabled(viewModel.selectedMeaning != nil)
                    }
                }

                // Step 2: Gender
                if viewModel.phase == .gender {
                    Text("Select the gender").font(.subheadline).foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        ForEach(["masculine", "feminine", "neuter"], id: \.self) { g in
                            Button { viewModel.submitGender(g) } label: {
                                Text(g.capitalized)
                                    .padding(.vertical, 12)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(g == viewModel.selectedGender
                                                  ? (g == item.gender ? Color.green.opacity(0.2) : Color.red.opacity(0.18))
                                                  : Color(.systemBackground))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(g == viewModel.selectedGender
                                                    ? (g == item.gender ? Color.green : Color.red)
                                                    : Color.secondary.opacity(0.25), lineWidth: 1)
                                    )
                            }
                            .disabled(viewModel.selectedGender != nil)
                        }
                    }
                }

                // Step 3: Done
                if viewModel.phase == .done {
                    VStack(spacing: 6) {
                        Text("Correct meaning: \(item.meaning)")
                        Text("Correct gender: \(item.gender.capitalized)")
                    }
                    Button {
                        viewModel.next()
                    } label: {
                        Text("Next word")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(AppTheme.softBlue)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.flagBlue, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.top, 6)
                }
            } else {
                Text("No words loaded.").foregroundColor(.secondary)
            }

            Spacer()

            // Footer: reset
            Button("Reset score") { viewModel.resetScore() }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(AppTheme.softYellow)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.flagYellow, lineWidth: 1))
                )
        }
        .padding()
        .onAppear {
            if !hasSeenWelcome { showWelcome = true }
        }
        .sheet(isPresented: $showWelcome, onDismiss: {
            hasSeenWelcome = true
        }) {
            WelcomeView {
                hasSeenWelcome = true
                showWelcome = false
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(vm: viewModel)
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - App Entry
@main
struct UkrainianGendersApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: QuizViewModel())
        }
    }
}

