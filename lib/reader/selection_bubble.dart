import 'package:flutter/material.dart';

import '../theme/reader_theme.dart';

/// A button of the [SelectionBubble].
class SelectionAction {
  const SelectionAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
}

/// Small toolbar shown above selected text (below it when there is no room
/// above), offering [actions] on the selection.
class SelectionBubble extends StatelessWidget {
  const SelectionBubble({
    super.key,
    required this.anchors,
    required this.actions,
    this.minTop = 0,
  });

  /// Global positions: above the selection's first line ([primaryAnchor])
  /// and below its last one ([secondaryAnchor]).
  final TextSelectionToolbarAnchors anchors;
  final List<SelectionAction> actions;

  /// The bubble goes below the selection if it would end above this (global
  /// y, e.g. the bottom of the app bar).
  final double minTop;

  static const _height = 40.0;
  static const _gap = 6.0;

  @override
  Widget build(BuildContext context) {
    final reader = ReaderTheme.of(context);
    final above = anchors.primaryAnchor - const Offset(0, _gap);
    final below =
        (anchors.secondaryAnchor ?? anchors.primaryAnchor) +
        const Offset(0, _gap);
    return CustomSingleChildLayout(
      delegate: TextSelectionToolbarLayoutDelegate(
        anchorAbove: above,
        anchorBelow: below,
        fitsAbove: above.dy - _height >= minTop,
      ),
      child: Material(
        color: reader.surface,
        elevation: 4,
        shape: StadiumBorder(side: BorderSide(color: reader.divider)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: _height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, a) in actions.indexed) ...[
                if (i > 0) VerticalDivider(width: 1, color: reader.divider),
                TextButton.icon(
                  onPressed: a.onPressed,
                  icon: Icon(a.icon, size: 18),
                  label: Text(a.label),
                  style: TextButton.styleFrom(
                    foregroundColor: reader.accent,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: const RoundedRectangleBorder(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
