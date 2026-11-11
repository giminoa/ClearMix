import ClearMixCore
import Foundation

/// Lightweight Turkish / English string selector driven by user preference.
enum L10n {
    static func text(_ tr: String, _ en: String, lang: ClearMixSettings.Language) -> String {
        lang == .turkish ? tr : en
    }

    static func profileName(_ profile: ClearMixSettings.Profile, lang: ClearMixSettings.Language) -> String {
        switch profile {
        case .standard: return text("Standart", "Standard", lang: lang)
        case .gaming:   return text("Oyun", "Gaming", lang: lang)
        case .meeting:  return text("Toplantı", "Meeting", lang: lang)
        case .streaming: return text("Yayın", "Streaming", lang: lang)
        }
    }

    static func eqPresetName(_ preset: Equalizer.Preset, lang: ClearMixSettings.Language) -> String {
        switch preset {
        case .flat:      return text("Düz", "Flat", lang: lang)
        case .bassBoost: return text("Bas Güçlendirme", "Bass Boost", lang: lang)
        case .vocal:     return text("Vokal", "Vocal", lang: lang)
        case .podcast:   return "Podcast"
        case .gaming:    return text("Oyun", "Gaming", lang: lang)
        case .treble:    return text("Tiz", "Treble", lang: lang)
        case .night:     return text("Gece Modu", "Night", lang: lang)
        }
    }
}
