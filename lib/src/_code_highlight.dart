part of re_editor;

// A new class to hold the cached result for a single line.
// Crucially, it stores the parser state at the end of the line.
class _LineHighlightResult {
  final List<_HighlightNode> nodes;
  final HighlightResult? result; // The raw result which contains the end state.

  _LineHighlightResult(this.nodes, this.result);

  String get source => nodes.map((e) => e.value).join();
}


class _CodeHighlighter extends ValueNotifier<List<_HighlightResult>> {
  final BuildContext _context;
  final _CodeParagraphProvider _provider;
  final _CodeHighlightEngine _engine;

  CodeLineEditingController _controller;
  CodeHighlightTheme? _theme;

  // Cache for incremental highlighting. Maps line index to its result.
  final Map<int, _LineHighlightResult> _highlightCache = {};

  _CodeHighlighter({
    required BuildContext context,
    required CodeLineEditingController controller,
    CodeHighlightTheme? theme,
  })  : _context = context,
        _provider = _CodeParagraphProvider(),
        _controller = controller,
        _theme = theme,
        _engine = _CodeHighlightEngine(theme),
        super(const []) {
    _controller.addListener(_onCodesChanged);
    _processFullHighlight(); // Perform a full highlight on initialization.
  }

  set controller(CodeLineEditingController value) {
    if (_controller == value) {
      return;
    }
    _controller.removeListener(_onCodesChanged);
    _controller = value;
    _controller.addListener(_onCodesChanged);
    _highlightCache.clear(); // Clear cache for new controller
    _processFullHighlight();
  }

  set theme(CodeHighlightTheme? value) {
    if (_theme == value) {
      return;
    }
    _theme = value;
    _engine.theme = value;
    _highlightCache.clear(); // Clear cache for new theme
    _processFullHighlight();
  }

  @override
  void dispose() {
    _controller.removeListener(_onCodesChanged);
    _engine.dispose();
    super.dispose();
  }
  
  // This part of the code remains largely the same, it just consumes the results.
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
    // Diff logic remains the same...
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

  TextSpan _buildSpanFromNodes(List<_HighlightNode> nodes, TextStyle baseStyle) {
    return TextSpan(
        children: nodes
            .map((e) => TextSpan(text: e.value, style: _findStyle(e.className)))
            .toList(),
        style: baseStyle);
  }

  TextStyle? _findStyle(String? className) {
    if (className == null) return null;
    final theme = _theme?.theme;
    if (theme == null) return null;
    
    // This can be optimized, but for now, we'll keep it simple.
    // The original logic is fine.
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

  // The new brain of the operation. Decides whether to do a full or incremental highlight.
  void _onCodesChanged() {
    final CodeLineEditingValue? preValue = _controller.preValue;
    if (preValue == null || _controller.codeLines == preValue.codeLines) {
      return;
    }

    final CodeLines oldCodeLines = preValue.codeLines;
    final CodeLines newCodeLines = _controller.codeLines;

    // Heuristic: If the number of lines changed significantly, or if the cache is empty,
    // it's probably faster or necessary to do a full re-highlight.
    if (_highlightCache.isEmpty || (newCodeLines.length - oldCodeLines.length).abs() > 50) {
      _processFullHighlight();
      return;
    }

    // Find the first line that differs.
    int firstDirtyLine = -1;
    final int minLength = min(oldCodeLines.length, newCodeLines.length);
    for (int i = 0; i < minLength; i++) {
      if (oldCodeLines[i] != newCodeLines[i]) {
        firstDirtyLine = i;
        break;
      }
    }

    if (firstDirtyLine == -1) {
      // Lines are the same, but one document is longer. The first new/deleted line is the dirty one.
      if (newCodeLines.length != oldCodeLines.length) {
        firstDirtyLine = minLength;
      } else {
        // No change detected.
        return;
      }
    }
    
    _processIncrementalHighlight(firstDirtyLine);
  }

  void _processFullHighlight() {
    _engine.runFullHighlight(_controller.codeLines, (newCache) {
      _highlightCache.clear();
      _highlightCache.addAll(newCache);
      // Convert the new cache to the format the ValueNotifier expects.
      final results = _highlightCache.values.map((e) => _HighlightResult(e.nodes)).toList();
      value = results;
    });
  }

  void _processIncrementalHighlight(int dirtyLineIndex) {
    _engine.runIncrementalHighlight(
      _controller.codeLines, 
      _highlightCache, 
      dirtyLineIndex, 
      (updatedLines) {
        // Update our cache with the new results from the incremental run.
        _highlightCache.addAll(updatedLines);

        // If lines were deleted, we need to remove them from the cache.
        if (_controller.codeLines.length < _highlightCache.length) {
          _highlightCache.removeWhere((key, _) => key >= _controller.codeLines.length);
        }

        // Reconstruct the full list of results for the UI.
        final results = _highlightCache.values.map((e) => _HighlightResult(e.nodes)).toList();
        value = results;
    });
  }
}

class _CodeHighlightEngine {
  // We need two separate taskers, one for full and one for incremental,
  // to prevent them from interfering with each other's pending requests.
  late final _IsolateTasker<_FullHighlightRequest, Map<int, _LineHighlightResult>> _fullTasker;
  late final _IsolateTasker<_IncrementalHighlightRequest, Map<int, _LineHighlightResult>> _incrementalTasker;

  Highlight? _highlight;
  CodeHighlightTheme? _theme;

  _CodeHighlightEngine(final CodeHighlightTheme? theme) {
    this.theme = theme;
    _fullTasker = _IsolateTasker('FullCodeHighlightEngine', _runFull);
    _incrementalTasker = _IsolateTasker('IncrementalCodeHighlightEngine', _runIncremental);
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
    _fullTasker.close();
    _incrementalTasker.close();
  }

  // Method to trigger a full, stateful highlight.
  void runFullHighlight(CodeLines codes, IsolateCallback<Map<int, _LineHighlightResult>> callback) {
    if (_highlight == null) {
      callback({});
      return;
    }
    _fullTasker.run(_FullHighlightRequest(highlight: _highlight!, codes: codes), callback);
  }

  // Method to trigger an incremental highlight.
  void runIncrementalHighlight(CodeLines codes, Map<int, _LineHighlightResult> oldCache, int dirtyLineIndex, IsolateCallback<Map<int, _LineHighlightResult>> callback) {
    if (_highlight == null) {
      callback({});
      return;
    }
    _incrementalTasker.run(_IncrementalHighlightRequest(
      highlight: _highlight!, 
      codes: codes, 
      oldCache: oldCache, 
      dirtyLineIndex: dirtyLineIndex
    ), callback);
  }

  // Isolate entry point for a full highlight.
  @pragma('vm:entry-point')
  static Map<int, _LineHighlightResult> _runFull(_FullHighlightRequest payload) {
    final newCache = <int, _LineHighlightResult>{};
    HighlightResult? previousResult;
    for (int i = 0; i < payload.codes.length; i++) {
      final line = payload.codes[i].text;
      final result = payload.highlight.highlight(
        code: line,
        language: 'dart', // Assuming dart for simplicity, can be made dynamic
        continuation: previousResult,
      );
      final renderer = _HighlightLineRenderer();
      result.render(renderer);
      newCache[i] = _LineHighlightResult(renderer.lineResults.first.nodes, result);
      previousResult = result;
    }
    return newCache;
  }

  // Isolate entry point for an incremental highlight.
  @pragma('vm:entry-point')
  static Map<int, _LineHighlightResult> _runIncremental(_IncrementalHighlightRequest payload) {
    final updatedLines = <int, _LineHighlightResult>{};
    
    // Get the state from the line *before* the first dirty line.
    final HighlightResult? startState = payload.dirtyLineIndex > 0
        ? payload.oldCache[payload.dirtyLineIndex - 1]?.result
        : null;

    HighlightResult? previousResult = startState;
    for (int i = payload.dirtyLineIndex; i < payload.codes.length; i++) {
      final line = payload.codes[i].text;
      final result = payload.highlight.highlight(
        code: line,
        language: 'dart',
        continuation: previousResult,
      );
      final renderer = _HighlightLineRenderer();
      result.render(renderer);
      
      updatedLines[i] = _LineHighlightResult(renderer.lineResults.first.nodes, result);
      
      final oldEndState = payload.oldCache[i]?.result?.endState;
      final newEndState = result.endState;
      
      // The stabilization check!
      if (oldEndState == newEndState) {
        break; // Stop processing, the rest of the file is unchanged.
      }
      
      previousResult = result;
    }
    return updatedLines;
  }
}

// Payloads for isolate communication.
class _FullHighlightRequest {
  final Highlight highlight;
  final CodeLines codes;
  const _FullHighlightRequest({required this.highlight, required this.codes});
}

class _IncrementalHighlightRequest {
  final Highlight highlight;
  final CodeLines codes;
  final Map<int, _LineHighlightResult> oldCache;
  final int dirtyLineIndex;
  const _IncrementalHighlightRequest({required this.highlight, required this.codes, required this.oldCache, required this.dirtyLineIndex});
}


// These classes remain the same
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