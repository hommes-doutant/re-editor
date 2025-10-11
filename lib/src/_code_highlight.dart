part of re_editor;

class _Match {
  final int start;
  final int end;
  final String text;
  final PatternRecognizer recognizer;

  _Match(this.start, this.end, this.text, this.recognizer);
}

class _CodeHighlighter extends ValueNotifier<List<_HighlightResult>> {
  final BuildContext _context;
  final _CodeParagraphProvider _provider;
  final _CodeHighlightEngine _engine;

  CodeLineEditingController _controller;
  CodeHighlightTheme? _theme;
  List<PatternRecognizer>? _patternRecognizers; // Add this property

  List<_HighlightResult> _highlightCache = [];

  _CodeHighlighter({
    required BuildContext context,
    required CodeLineEditingController controller,
    CodeHighlightTheme? theme,
    List<PatternRecognizer>? patternRecognizers, // Add to constructor
  })  : _context = context,
        _provider = _CodeParagraphProvider(),
        _controller = controller,
        _theme = theme,
        _patternRecognizers = patternRecognizers,
        _engine = _CodeHighlightEngine(theme),
        super(const []) {
    _controller.addListener(_onCodesChanged);
    _processFullHighlight();
  }

  set controller(CodeLineEditingController value) {
    if (_controller == value) {
      return;
    }
    _controller.removeListener(_onCodesChanged);
    _controller = value;
    _controller.addListener(_onCodesChanged);
    // _highlightcache.clear();
    _processFullHighlight();
  }

  set theme(CodeHighlightTheme? value) {
    if (_theme == value) {
      return;
    }
    _theme = value;
    _engine.theme = value;
    // _highlightcache.clear();
    _processFullHighlight();
  }
  
  set patternRecognizers(List<PatternRecognizer>? value) {
    if (listEquals(_patternRecognizers, value)) {
      return;
    }
    _patternRecognizers = value;
    // _highlightcache.clear();
    _processFullHighlight();
  }


  @override
  void dispose() {
    _controller.removeListener(_onCodesChanged);
    _engine.dispose();
    super.dispose();
  }

  IParagraph build({
    required int index,
    required TextStyle style,
    required double maxWidth,
    int? maxLengthSingleLineRendering,
  }) {
    _provider.updateBaseStyle(style);
    _provider.updateMaxLengthSingleLineRendering(maxLengthSingleLineRendering);
    return _provider.build(
        _controller.buildTextSpan(
            context: _context,
            index: index,
            textSpan: _buildSpan(index, style),
            style: style),
        maxWidth);
  }

  TextSpan _buildSpan(int index, TextStyle style) {
    final String text = _controller.codeLines[index].text;
    if (index >= value.length) {
      return TextSpan(text: text, style: style);
    }
    final _HighlightResult result = value[index];
    if (result.nodes.isEmpty) {
      return TextSpan(text: text, style: style);
    }
    if (result.source == text) {
      return _buildSpanFromNodes(result.nodes, style);
    }
    final List<_HighlightNode> startNodes = [];
    int start = 0;
    int end = text.length;
    for (int i = 0; i < result.nodes.length && start < end; i++) {
      final String value = result.nodes[i].value;
      if (text.startsWith(value, start)) {
        startNodes.add(result.nodes[i]);
        start += value.length;
      } else {
        break;
      }
    }
    final List<_HighlightNode> endNodes = [];
    for (int i = result.nodes.length - 1; i >= 0 && start < end; i--) {
      final String value = result.nodes[i].value;
      if (text.substring(start, end).endsWith(value)) {
        endNodes.insert(0, result.nodes[i]);
        end -= value.length;
      } else {
        break;
      }
    }
    final _HighlightNode? midNode;
    if (startNodes.isEmpty) {
      midNode = _HighlightNode(text.substring(start, end), result.nodes.isEmpty ? null : result.nodes[0].className);
    } else if (startNodes.length < result.nodes.length) {
      midNode = _HighlightNode(text.substring(start, end), result.nodes[startNodes.length].className);
    } else if (end > start) {
      midNode = _HighlightNode(text.substring(start, end), result.nodes.last.className);
    } else {
      midNode = null;
    }
    return _buildSpanFromNodes(
        [...startNodes, if (midNode != null) midNode, ...endNodes], style);
  }
  
  List<InlineSpan> _applyPatternRecognizers(String text, TextStyle? originalStyle) {
    if (_patternRecognizers == null || _patternRecognizers!.isEmpty) {
      return [TextSpan(text: text, style: originalStyle)];
    }

    final List<_Match> allMatches = [];
    for (final recognizer in _patternRecognizers!) {
      for (final match in recognizer.pattern.allMatches(text)) {
        allMatches.add(_Match(match.start, match.end, match.group(0)!, recognizer));
      }
    }

    if (allMatches.isEmpty) {
      return [TextSpan(text: text, style: originalStyle)];
    }

    // Sort matches by start index to process them in order
    allMatches.sort((a, b) => a.start.compareTo(b.start));

    final List<InlineSpan> spans = [];
    int lastMatchEnd = 0;

    for (final match in allMatches) {
      // Ignore overlapping matches
      if (match.start < lastMatchEnd) {
        continue;
      }

      // Add the text before this match
      if (match.start > lastMatchEnd) {
        spans.add(TextSpan(
          text: text.substring(lastMatchEnd, match.start),
          style: originalStyle,
        ));
      }

      // Add the matched, tappable text
      spans.add(TextSpan(
        text: match.text,
        style: originalStyle?.merge(match.recognizer.style) ?? match.recognizer.style,
        recognizer: TapGestureRecognizer()..onTap = () => match.recognizer.onTap?.call(match.text),
        mouseCursor: match.recognizer.mouseCursor,
      ));

      lastMatchEnd = match.end;
    }

    // Add any remaining text after the last match
    if (lastMatchEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastMatchEnd),
        style: originalStyle,
      ));
    }

    return spans;
  }

  TextSpan _buildSpanFromNodes(List<_HighlightNode> nodes, TextStyle baseStyle) {
    if (_patternRecognizers == null || _patternRecognizers!.isEmpty || nodes.isEmpty) {
      return TextSpan(
        children: nodes
            .map((node) => TextSpan(text: node.value, style: _findStyle(node.className)))
            .toList(),
        style: baseStyle,
      );
    }

    final plainText = nodes.map((e) => e.value).join();
    
    // 1. Find all non-overlapping matches from all recognizers.
    final List<Match> allMatches = [];
    for (final recognizer in _patternRecognizers!) {
      allMatches.addAll(recognizer.pattern.allMatches(plainText));
    }

    if (allMatches.isEmpty) {
      return TextSpan(
        children: nodes
            .map((node) => TextSpan(text: node.value, style: _findStyle(node.className)))
            .toList(),
        style: baseStyle,
      );
    }

    // Sort matches and remove overlaps (earliest, longest match wins).
    allMatches.sort((a, b) {
      final start = a.start.compareTo(b.start);
      if (start != 0) return start;
      return (b.end - b.start).compareTo(a.end - a.start);
    });

    final List<Match> deoverlappedMatches = [];
    int lastMatchEnd = -1;
    for (final match in allMatches) {
      if (match.start >= lastMatchEnd) {
        deoverlappedMatches.add(match);
        lastMatchEnd = match.end;
      }
    }
    
    // 2. Reconstruct the line span by iterating through the text.
    final List<InlineSpan> finalSpans = [];
    int cursor = 0;
    int nodeCursor = 0;
    int currentNodeIndex = 0;

    // Helper to get the underlying syntax spans for a text range
    List<TextSpan> getSpansForRange(int start, int end) {
      final result = <TextSpan>[];
      int tempCursor = 0;
      for (final node in nodes) {
        final nodeStart = tempCursor;
        final nodeEnd = nodeStart + node.value.length;
        if (nodeEnd <= start) {
          tempCursor = nodeEnd;
          continue;
        }
        if (nodeStart >= end) {
          break;
        }

        final int effectiveStart = max(start, nodeStart);
        final int effectiveEnd = min(end, nodeEnd);
        result.add(TextSpan(
          text: plainText.substring(effectiveStart, effectiveEnd),
          style: _findStyle(node.className),
        ));
        tempCursor = nodeEnd;
      }
      return result;
    }

    // Process each valid match
    for (final match in deoverlappedMatches) {
      // Add the plain text segment before the match
      if (match.start > cursor) {
        finalSpans.addAll(getSpansForRange(cursor, match.start));
      }

      // Use the recognizer's builder to create the span for the match
      final recognizer = _patternRecognizers!.firstWhere((r) => r.pattern == match.pattern);
      final underlyingSpans = getSpansForRange(match.start, match.end);
      final builtSpan = recognizer.builder(match, underlyingSpans);

      // Apply default mouse cursor if the builder didn't provide one
      if (builtSpan is TextSpan && builtSpan.mouseCursor == null) {
        finalSpans.add(TextSpan(
          text: builtSpan.text,
          children: builtSpan.children,
          style: builtSpan.style,
          recognizer: builtSpan.recognizer,
          mouseCursor: recognizer.mouseCursor,
        ));
      } else {
        finalSpans.add(builtSpan);
      }
      
      cursor = match.end;
    }

    // Add any remaining text after the last match
    if (cursor < plainText.length) {
      finalSpans.addAll(getSpansForRange(cursor, plainText.length));
    }

    return TextSpan(children: finalSpans, style: baseStyle);
  }
  


  TextStyle? _findStyle(String? className) {
    if (className == null) return null;
    final theme = _theme?.theme;
    if (theme == null) return null;
    
    String current = className;
    while (true) {
      final style = theme[current];
      if (style != null) return style;
      final index = current.indexOf('-');
      if (index < 0) break;
      current = current.substring(index + 1);
      if (current.isEmpty) break;
    }
    return null;
  }

  void _onCodesChanged() {
    final CodeLineEditingValue? preValue = _controller.preValue;
    if (preValue == null || _controller.codeLines == preValue.codeLines) {
      return;
    }

    final CodeLines oldCodeLines = preValue.codeLines;
    final CodeLines newCodeLines = _controller.codeLines;

    if (_highlightCache.isEmpty) {
      _processFullHighlight();
      return;
    }
    
    // --- START OF MODIFIED LOGIC ---
    // A more robust heuristic is needed for deciding between partial and full highlight.

    const int kPartialHighlightThreshold = 100; // Lines changed threshold

    // 1. Calculate the diff to find the exact range of changed lines.
    int firstDiff = 0;
    while (firstDiff < oldCodeLines.length &&
           firstDiff < newCodeLines.length &&
           oldCodeLines[firstDiff] == newCodeLines[firstDiff]) {
      firstDiff++;
    }

    int lastDiffOld = oldCodeLines.length - 1;
    int lastDiffNew = newCodeLines.length - 1;
    while (lastDiffOld >= firstDiff &&
           lastDiffNew >= firstDiff &&
           oldCodeLines[lastDiffOld] == newCodeLines[lastDiffNew]) {
      lastDiffOld--;
      lastDiffNew--;
    }

    final int numDeleted = max(0, lastDiffOld - firstDiff + 1);
    final int numAdded = max(0, lastDiffNew - firstDiff + 1);

    // 2. New Heuristic: If the number of added lines is large, do a full highlight.
    // This correctly handles large paste operations.
    if (numAdded > kPartialHighlightThreshold) {
      _processFullHighlight();
      return;
    }

    // 3. For smaller changes, manipulate the cache and do a partial highlight.
    // This logic handles both modifications and small insertions/deletions.
    final newPlaceholders = List.generate(numAdded, (_) => _HighlightResult([]));
    _highlightCache.replaceRange(firstDiff, firstDiff + numDeleted, newPlaceholders);

    // Immediately update the UI if the structure changed (lines added/removed).
    // This prevents highlighting from being misaligned.
    if (numAdded != numDeleted) {
      value = List.of(_highlightCache);
    }
    
    _processPartialHighlight(firstDiff);
    // --- END OF MODIFIED LOGIC ---
  }

  void _processFullHighlight() {
    _engine.run(_controller.codeLines, (results) {
        _highlightCache = results;
        value = results;
    });
  }

  void _processPartialHighlight(int dirtyLineIndex) {
    _engine.runPartial(
      _controller.codeLines, 
      dirtyLineIndex, 
      (partialResult) {
        partialResult.forEach((index, result) {
          if (index < _highlightCache.length) {
            _highlightCache[index] = result;
          }
        });
        value = List.of(_highlightCache);
    });
  }
}

class _CodeHighlightEngine {
  late final _IsolateTasker<_HighlightPayload, List<_HighlightResult>> _tasker;
  late final _IsolateTasker<_PartialHighlightPayload, Map<int, _HighlightResult>> _partialTasker;

  Highlight? _highlight;
  CodeHighlightTheme? _theme;

  _CodeHighlightEngine(final CodeHighlightTheme? theme) {
    this.theme = theme;
    _tasker = _IsolateTasker('CodeHighlightEngine', _run);
    _partialTasker = _IsolateTasker('PartialCodeHighlightEngine', _runPartial);
  }

  set theme(CodeHighlightTheme? value) {
    if (_theme == value) return;
    _theme = value;
    final Map<String, CodeHighlightThemeMode>? modes = _theme?.languages;
    if (modes == null) {
      _highlight = null;
    } else {
      _highlight = Highlight();
      _highlight!.registerLanguages(modes.map((key, value) => MapEntry(key, value.mode)));
      for (final plugin in _theme!.plugins) {
        _highlight!.addPlugin(plugin);
      }
    }
  }

  void dispose() {
    _tasker.close();
    _partialTasker.close();
  }

  void run(CodeLines codes, IsolateCallback<List<_HighlightResult>> callback) {
    if (_highlight == null) {
      callback([]);
      return;
    }
    _tasker.run(_createPayload(codes), callback);
  }

  void runPartial(CodeLines codes, int dirtyLineIndex, IsolateCallback<Map<int, _HighlightResult>> callback) {
    if (_highlight == null) {
      callback({});
      return;
    }
    _partialTasker.run(_createPartialPayload(codes, dirtyLineIndex), callback);
  }

  _HighlightPayload _createPayload(CodeLines codes) {
    final Map<String, CodeHighlightThemeMode> modes = _theme?.languages ?? {};
    return _HighlightPayload(
      highlight: _highlight!,
      codes: codes,
      languages: modes.keys.toList(),
      maxSizes: modes.values.map((e) => e.maxSize).toList(),
      maxLineLengths: modes.values.map((e) => e.maxLineLength).toList(),
    );
  }

  _PartialHighlightPayload _createPartialPayload(CodeLines codes, int dirtyLineIndex) {
    final String language = _theme?.languages.keys.isNotEmpty == true 
      ? _theme!.languages.keys.first 
      : 'plaintext';
    return _PartialHighlightPayload(
      highlight: _highlight!,
      codes: codes,
      dirtyLineIndex: dirtyLineIndex,
      language: language,
    );
  }

  @pragma('vm:entry-point')
  static List<_HighlightResult> _run(_HighlightPayload payload) {
    final String code = payload.codes.asString(TextLineBreak.lf, false);
    final HighlightResult result;
    if (payload.languages.isEmpty) {
      result = payload.highlight.highlight(code: code, language: 'plaintext');
    } else if (payload.languages.length == 1) {
      result = payload.highlight.highlight(code: code, language: payload.languages.first);
    } else {
      result = payload.highlight.highlightAuto(code, payload.languages);
    }
    final _HighlightLineRenderer renderer = _HighlightLineRenderer();
    result.render(renderer);
    return renderer.lineResults;
  }

  @pragma('vm:entry-point')
  static Map<int, _HighlightResult> _runPartial(_PartialHighlightPayload payload) {
    const int contextSize = 50;
    final int startLine = max(0, payload.dirtyLineIndex - contextSize);
    final int endLine = min(payload.codes.length, payload.dirtyLineIndex + contextSize + 1);
    
    if (startLine >= endLine) {
      return {};
    }

    final List<String> linesToHighlight = [];
    for (int i = startLine; i < endLine; i++) {
      linesToHighlight.add(payload.codes[i].text);
    }

    final String textChunk = linesToHighlight.join('\n');
    final HighlightResult result = payload.highlight.highlight(code: textChunk, language: payload.language);
    
    final _HighlightLineRenderer renderer = _HighlightLineRenderer();
    result.render(renderer);
    
    final Map<int, _HighlightResult> updatedResults = {};
    for (int i = 0; i < renderer.lineResults.length; i++) {
      final int absoluteLineIndex = startLine + i;
      if (absoluteLineIndex < payload.codes.length) {
         updatedResults[absoluteLineIndex] = renderer.lineResults[i];
      }
    }
    
    return updatedResults;
  }
}

class _HighlightPayload {
  final Highlight highlight;
  final CodeLines codes;
  final List<String> languages;
  final List<int> maxSizes;
  final List<int> maxLineLengths;

  const _HighlightPayload({
    required this.highlight, required this.codes, required this.languages,
    required this.maxSizes, required this.maxLineLengths,
  });
}

class _PartialHighlightPayload {
  final Highlight highlight;
  final CodeLines codes;
  final int dirtyLineIndex;
  final String language;

  const _PartialHighlightPayload({
    required this.highlight, required this.codes, 
    required this.dirtyLineIndex, required this.language,
  });
}

class _HighlightResult {
  final List<_HighlightNode> nodes;
  _HighlightResult(this.nodes);
  String get source => nodes.map((e) => e.value).join();
}

class _HighlightNode {
  final String? className;
  final String value;
  const _HighlightNode(this.value, [this.className]);
}

class _HighlightLineRenderer implements HighlightRenderer {
  final List<_HighlightResult> lineResults;
  final List<String?> classNames;
  _HighlightLineRenderer()
      : lineResults = [_HighlightResult([])],
        classNames = [];

  @override
  void addText(String text) {
    final String? className = classNames.isEmpty ? null : classNames.last;
    final List<String> lines = text.split(TextLineBreak.lf.value);
    lineResults.last.nodes.add(_HighlightNode(lines.first, className));
    if (lines.length > 1) {
      for (int i = 1; i < lines.length; i++) {
        lineResults.add(_HighlightResult([_HighlightNode(lines[i], className)]));
      }
    }
  }

  @override
  void openNode(DataNode node) {
    final String? className = classNames.isEmpty ? null : classNames.last;
    String? newClassName;
    if (className == null || node.scope == null) {
      newClassName = node.scope;
    } else {
      newClassName = '$className-${node.scope!}';
    }
    newClassName = newClassName?.split('.')[0];
    classNames.add(newClassName);
  }

  @override
  void closeNode(DataNode node) {
    if (classNames.isNotEmpty) {
      classNames.removeLast();
    }
  }
}