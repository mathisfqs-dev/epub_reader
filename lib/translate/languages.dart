/// Languages offered as translation targets. [name] is the English name, used
/// in the prompt; [label] is shown in the UI.
class TranslationLanguage {
  const TranslationLanguage(this.code, this.name, this.label);

  final String code;
  final String name;
  final String label;

  static const all = [
    TranslationLanguage('fr', 'French', 'Français'),
    TranslationLanguage('en', 'English', 'English'),
    TranslationLanguage('es', 'Spanish', 'Español'),
    TranslationLanguage('de', 'German', 'Deutsch'),
    TranslationLanguage('it', 'Italian', 'Italiano'),
    TranslationLanguage('pt', 'Portuguese', 'Português'),
  ];

  /// The language with [code], or one named after the code.
  static TranslationLanguage of(String code) =>
      all.where((l) => l.code == code).firstOrNull ??
      TranslationLanguage(code, code, code);

  /// Default target for a book in [source]: English for French books,
  /// French for every other language.
  static String defaultTargetFor(String source) => source == 'fr' ? 'en' : 'fr';
}
