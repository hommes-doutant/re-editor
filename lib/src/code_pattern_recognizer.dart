part of re_editor;

/// Defines a pattern to be recognized in the editor's text,
/// with associated styling and interaction callbacks.
@immutable
class PatternRecognizer {
  /// The regular expression used to find matches in the text.
  final RegExp pattern;

  /// The style to apply to the matched text. This will be merged
  /// with any existing syntax highlighting styles.
  final TextStyle? style;

  /// A callback that is invoked when a user taps on the matched text.
  /// The callback receives the exact string that was matched.
  final void Function(String match)? onTap;

  /// The mouse cursor to display when hovering over the matched text.
  /// Defaults to [SystemMouseCursors.click].
  final MouseCursor mouseCursor;

  /// Creates a pattern recognizer.
  ///
  /// The [pattern] is a [RegExp] that will be run against the text.
  /// For every match, the [style] will be applied, and an [onTap]
  /// handler will be attached.
  const PatternRecognizer({
    required this.pattern,
    this.style,
    this.onTap,
    this.mouseCursor = SystemMouseCursors.click,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PatternRecognizer &&
          runtimeType == other.runtimeType &&
          pattern == other.pattern &&
          style == other.style &&
          onTap == other.onTap &&
          mouseCursor == other.mouseCursor;

  @override
  int get hashCode => Object.hash(pattern, style, onTap, mouseCursor);
}