/// Pocket TTS text preparation, which sherpa-onnx doesn't do.
///
/// Port of `prepare_text_prompt` from kyutai-labs/pocket-tts
/// (`pocket_tts/models/text_chunking.py`, MIT licence), through
/// `pocket_tts_export/text_prep.py`: keep the three in sync.
library;

/// The `text` section of a pack's `pocket.json`.
class PocketTextRules {
  const PocketTextRules({
    this.removeSemicolons = false,
    this.replaceCharacters = const {},
    this.padWithSpacesForShortInputs = false,
    this.capitalizeFirstLetter = true,
    this.appendTerminalPunctuation = true,
  });

  factory PocketTextRules.fromJson(Map<String, dynamic> json) =>
      PocketTextRules(
        removeSemicolons: json['remove_semicolons'] as bool? ?? false,
        replaceCharacters: {
          for (final MapEntry(:key, :value)
              in (json['replace_characters'] as Map<String, dynamic>? ?? {})
                  .entries)
            key: value as String,
        },
        padWithSpacesForShortInputs:
            json['pad_with_spaces_for_short_inputs'] as bool? ?? false,
        capitalizeFirstLetter: json['capitalize_first_letter'] as bool? ?? true,
        appendTerminalPunctuation:
            json['append_terminal_punctuation'] as bool? ?? true,
      );

  final bool removeSemicolons;

  /// Single characters to replace (the value may be empty: delete).
  final Map<String, String> replaceCharacters;
  final bool padWithSpacesForShortInputs;
  final bool capitalizeFirstLetter;
  final bool appendTerminalPunctuation;
}

/// Text ready for the model, and upstream's guess of how many frames to
/// generate after the end-of-speech signal.
typedef PreparedText = ({String text, int framesAfterEosGuess});

const _terminal = '.!?…';
const _weak = ',;:-–—';
const _closers = '"\'”’)]»';

final _spaces = RegExp(r'\s+');
final _markThenWeak = RegExp(r'([.!?…])\s*[,;:]');

List<String> _words(String s) =>
    s.trim().isEmpty ? const [] : s.trim().split(_spaces);

String _stripRight(String s, String chars) {
  var end = s.length;
  while (end > 0 && chars.contains(s[end - 1])) {
    end--;
  }
  return s.substring(0, end);
}

/// Ends [text] with a sentence mark: a trailing `,` `;` `:` or dash becomes
/// a full stop, closing quotes and brackets stay after it.
String ensureTerminalPunctuation(String text) {
  final core = _stripRight(text, '$_closers ');
  final closers = text.substring(core.length).trim();
  if (core.isEmpty || _terminal.contains(core[core.length - 1])) return text;
  if (_weak.contains(core[core.length - 1])) {
    return '${_stripRight(core, '$_weak ')}.$closers';
  }
  return '$text.';
}

/// Prepares one sentence for Pocket TTS. Returns null when nothing is left
/// to say.
PreparedText? preparePocketText(String text, PocketTextRules rules) {
  text = text.trim();
  final replace = rules.replaceCharacters;
  if (replace.isNotEmpty) {
    final b = StringBuffer();
    for (final rune in text.runes) {
      final c = String.fromCharCode(rune);
      b.write(replace[c] ?? c);
    }
    text = _words(b.toString()).join(' ');
    // '"Hi?", she said' -> 'Hi?, she said' once the quotes are gone: keep
    // the sentence mark only.
    text = text.replaceAllMapped(_markThenWeak, (m) => m[1]!);
  }
  if (text.isEmpty) return null;
  text = text.replaceAll('\n', ' ').replaceAll('\r', ' ').replaceAll('  ', ' ');
  if (rules.removeSemicolons) text = text.replaceAll(';', ',');
  final guess = _words(text).length <= 4 ? 3 : 1;
  if (rules.capitalizeFirstLetter) {
    final first = String.fromCharCode(text.runes.first);
    text = first.toUpperCase() + text.substring(first.length);
  }
  if (rules.appendTerminalPunctuation) text = ensureTerminalPunctuation(text);
  if (rules.padWithSpacesForShortInputs && _words(text).length < 5) {
    text = '${' ' * 8}$text';
  }
  return (text: text, framesAfterEosGuess: guess);
}
