part of re_editor;

/// A function that builds an [InlineSpan] for a recognized pattern match.
///
/// [match] is the [Match] object from the regular expression.
/// [spans] is a list of the underlying syntax-highlighted [TextSpan]s
/// that this match covers. You can use their styles to merge with your own.
typedef PatternMatchBuilder = InlineSpan Function(
  Match match,
  List<TextSpan> spans,
);

/// Defines a pattern to be recognized in the editor's text,
/// with associated styling and interaction callbacks.
@immutable
class PatternRecognizer {
  /// The regular expression used to find matches in the text.
  final RegExp pattern;

  /// A builder function that constructs the [InlineSpan] for a match.
  /// This gives you full control over styling, including styling individual
  /// capture groups and adding gesture recognizers.
  final PatternMatchBuilder builder;

  /// The mouse cursor to display when hovering over the matched text.
  /// This is only used if the returned span from the [builder] doesn't
  /// already have a `mouseCursor`.
  final MouseCursor mouseCursor;

  /// Creates a pattern recognizer.
  ///
  /// The [pattern] is a [RegExp] that will be run against each line of text.
  /// For every match, the [builder] function is called to generate the
  /// corresponding [InlineSpan].
  const PatternRecognizer({
    required this.pattern,
    required this.builder,
    this.mouseCursor = SystemMouseCursors.click,
  });

  /// [DEPRECATED] Use the `builder` constructor instead for more control.
  @Deprecated('Use the default constructor with a `builder` for more flexibility.')
  factory PatternRecognizer.simple({
    required RegExp pattern,
    TextStyle? style,
    void Function(String match)? onTap,
    MouseCursor mouseCursor = SystemMouseCursors.click,
  }) {
    return PatternRecognizer(
      pattern: pattern,
      mouseCursor: mouseCursor,
      builder: (match, spans) {
        // Merge the styles from all underlying spans.
        TextStyle? mergedStyle = spans.fold<TextStyle?>(
          style,
          (previousValue, element) => previousValue == null
              ? element.style
              : previousValue.merge(element.style),
        );
        return TextSpan(
          text: match.group(0)!,
          style: mergedStyle,
          recognizer: TapGestureRecognizer()..onTap = () => onTap?.call(match.group(0)!),
        );
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PatternRecognizer &&
          runtimeType == other.runtimeType &&
          pattern == other.pattern &&
          builder == other.builder &&
          mouseCursor == other.mouseCursor;

  @override
  int get hashCode => Object.hash(pattern, builder, mouseCursor);
}