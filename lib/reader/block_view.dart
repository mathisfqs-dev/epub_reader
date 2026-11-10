import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';

import '../epub/epub.dart';
import '../theme/reader_theme.dart';

/// Text settings shared by every block of the reader.
@immutable
class BlockStyle {
  const BlockStyle({
    required this.theme,
    required this.fontSize,
    required this.lineHeight,
    required this.fontFamily,
    required this.justify,
  });

  final ReaderTheme theme;
  final double fontSize;
  final double lineHeight;
  final String? fontFamily;
  final bool justify;

  TextStyle get base => TextStyle(
    fontFamily: fontFamily,
    fontSize: fontSize,
    height: lineHeight,
    color: theme.text,
  );
}

/// Renders one [Block] of a chapter.
class BlockView extends StatefulWidget {
  const BlockView({
    super.key,
    required this.block,
    required this.style,
    required this.loadImage,
    this.onLink,
    this.maxImageHeight = 600,
    this.highlightSentence,
  });

  final Block block;
  final BlockStyle style;

  /// Returns the bytes of an image inside the EPUB.
  final Uint8List? Function(String path) loadImage;

  /// Called with the resolved `href` of a tapped link.
  final ValueChanged<String>? onLink;
  final double maxImageHeight;

  /// Index of the sentence being read aloud, highlighted.
  final int? highlightSentence;

  @override
  State<BlockView> createState() => BlockViewState();
}

class BlockViewState extends State<BlockView> {
  final _recognizers = <TapGestureRecognizer>[];
  final _textKey = GlobalKey();

  /// Index of the sentence under [globalPosition], or null if the point is
  /// not on this block's text.
  int? sentenceAt(Offset globalPosition) {
    final render = _paragraph(_textKey.currentContext?.findRenderObject());
    if (render == null || !render.attached) return null;
    final local = render.globalToLocal(globalPosition);
    if (!(Offset.zero & render.size).contains(local)) return null;
    final offset = render.getPositionForOffset(local).offset;
    final sentences = widget.block.sentences;
    for (var i = 0; i < sentences.length; i++) {
      if (offset < sentences[i].end) return i;
    }
    return sentences.isEmpty ? null : sentences.length - 1;
  }

  /// Bounds of sentence [index] in global coordinates, or null if the block
  /// isn't laid out.
  Rect? sentenceRect(int index) {
    final render = _paragraph(_textKey.currentContext?.findRenderObject());
    final sentences = widget.block.sentences;
    if (render == null || !render.attached || !render.hasSize) return null;
    if (index < 0 || index >= sentences.length) return null;
    final span = sentences[index];
    final boxes = render.getBoxesForSelection(
      TextSelection(baseOffset: span.start, extentOffset: span.end),
    );
    if (boxes.isEmpty) return null;
    var rect = boxes.first.toRect();
    for (final b in boxes.skip(1)) {
      rect = rect.expandToInclude(b.toRect());
    }
    return MatrixUtils.transformRect(render.getTransformTo(null), rect);
  }

  /// The paragraph under [node] (Text adds wrappers such as a MouseRegion).
  static RenderParagraph? _paragraph(RenderObject? node) {
    if (node is RenderParagraph) return node;
    RenderParagraph? found;
    node?.visitChildren((child) => found ??= _paragraph(child));
    return found;
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final block = widget.block;
    final s = widget.style;
    final size = s.fontSize;

    switch (block.type) {
      case BlockType.image:
        return _image(context);
      case BlockType.separator:
        return Padding(
          padding: EdgeInsets.symmetric(vertical: size * 1.2),
          child: Center(
            child: Container(
              width: size * 6,
              height: 1,
              color: s.theme.divider,
            ),
          ),
        );
      case BlockType.heading:
        const scales = {1: 1.7, 2: 1.45, 3: 1.25, 4: 1.1};
        return Padding(
          padding: EdgeInsets.only(
            top: size * (block.level <= 2 ? 2.0 : 1.2),
            bottom: size * 0.9,
          ),
          child: _text(
            s.base.copyWith(
              fontSize: size * (scales[block.level] ?? 1.0),
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
            TextAlign.center,
          ),
        );
      case BlockType.paragraph:
        return Padding(
          padding: EdgeInsets.only(bottom: size * 0.75),
          child: _text(s.base, s.justify ? TextAlign.justify : TextAlign.start),
        );
      case BlockType.quote:
        return Padding(
          padding: EdgeInsets.only(
            left: size * 1.6,
            right: size,
            bottom: size * 0.75,
          ),
          child: _text(s.base, s.justify ? TextAlign.justify : TextAlign.start),
        );
      case BlockType.verse:
        return Padding(
          padding: EdgeInsets.only(left: size * 1.6, bottom: size * 1.0),
          child: _text(s.base, TextAlign.start),
        );
      case BlockType.caption:
        return Padding(
          padding: EdgeInsets.only(bottom: size * 1.2),
          child: _text(
            s.base.copyWith(
              fontSize: size * 0.85,
              fontStyle: FontStyle.italic,
              color: s.theme.secondaryText,
            ),
            TextAlign.center,
          ),
        );
      case BlockType.footnote:
        return Padding(
          padding: EdgeInsets.only(left: size, bottom: size * 0.6),
          child: _text(
            s.base.copyWith(
              fontSize: size * 0.82,
              color: s.theme.secondaryText,
            ),
            TextAlign.start,
          ),
        );
    }
  }

  Widget _text(TextStyle style, TextAlign align) {
    final block = widget.block;
    final h = widget.highlightSentence;
    final range = h != null && h >= 0 && h < block.sentences.length
        ? block.sentences[h]
        : null;
    final spans = <InlineSpan>[];
    var start = 0;
    for (final inline in block.inlines) {
      final end = start + inline.text.length;
      if (range == null || range.end <= start || range.start >= end) {
        spans.add(_span(inline, style));
      } else {
        // Split the run at the highlighted sentence's edges.
        final a = (range.start - start).clamp(0, inline.text.length);
        final b = (range.end - start).clamp(0, inline.text.length);
        final t = inline.text;
        if (a > 0) spans.add(_span(inline.withText(t.substring(0, a)), style));
        spans.add(
          _span(
            inline.withText(t.substring(a, b)),
            style,
            background: widget.style.theme.highlight,
          ),
        );
        if (b < t.length) {
          spans.add(_span(inline.withText(t.substring(b)), style));
        }
      }
      start = end;
    }
    return Text.rich(
      key: _textKey,
      TextSpan(style: style, children: spans),
      textAlign: align,
      textScaler: TextScaler.noScaling,
    );
  }

  InlineSpan _span(Inline inline, TextStyle base, {Color? background}) {
    var text = inline.text;
    var style = TextStyle(backgroundColor: background);
    if (inline.italic) style = style.copyWith(fontStyle: FontStyle.italic);
    if (inline.bold) style = style.copyWith(fontWeight: FontWeight.w700);
    if (inline.superscript) {
      style = style.copyWith(fontSize: (base.fontSize ?? 16) * 0.7);
    }
    if (inline.smallCaps) {
      // Same length keeps character offsets valid (selection, read-aloud).
      final upper = text.toUpperCase();
      if (upper.length == text.length) {
        text = upper;
        style = style.copyWith(
          fontSize: (base.fontSize ?? 16) * 0.82,
          letterSpacing: (base.fontSize ?? 16) * 0.04,
        );
      }
    }
    final href = inline.href;
    if (href != null) {
      final accent = widget.style.theme.accent;
      style = style.copyWith(
        color: accent,
        decoration: TextDecoration.underline,
        decorationColor: accent.withValues(alpha: 0.4),
      );
      if (widget.onLink != null) {
        final recognizer = TapGestureRecognizer()
          ..onTap = () => widget.onLink!(href);
        _recognizers.add(recognizer);
        return TextSpan(
          text: text,
          style: style,
          recognizer: recognizer,
          mouseCursor: SystemMouseCursors.click,
        );
      }
    }
    return TextSpan(text: text, style: style);
  }

  Widget _image(BuildContext context) {
    final block = widget.block;
    final s = widget.style;
    final bytes = block.imagePath == null
        ? null
        : widget.loadImage(block.imagePath!);
    final placeholder = Text(
      block.imageAlt ?? '[image]',
      textAlign: TextAlign.center,
      style: s.base.copyWith(
        fontStyle: FontStyle.italic,
        color: s.theme.secondaryText,
        fontSize: s.fontSize * 0.85,
      ),
    );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: s.fontSize * 0.8),
      child: Center(
        child: bytes == null
            ? placeholder
            : ConstrainedBox(
                constraints: BoxConstraints(maxHeight: widget.maxImageHeight),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    semanticLabel: block.imageAlt,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stack) => placeholder,
                  ),
                ),
              ),
      ),
    );
  }
}
