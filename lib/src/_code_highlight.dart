part of re_editor;

class _CodeHighlighter extends ValueNotifier<List<_HighlightResult>> {
  final BuildContext _context;
  final _CodeParagraphProvider _provider;
  final _CodeHighlightEngine _engine;

  CodeLineEditingController _controller;
  CodeHighlightTheme? _theme;

  // The complete cache of highlight results for the document.
  // The list index corresponds to the line index.
  List<_HighlightResult> _highlightCache = [];

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
    _processFullHighlight();
  }

  set controller(CodeLineEditingController value) {
    if (_controller == value) {
      return;
    }
    _controller.removeListener(_onCodesChanged);
    _controller = value;
    _controller.addListener(_onCodesChanged);
    _highlightCache.clear();
    _processFullHighlight();
  }

  set theme(CodeHighlightTheme? value) {
    if (_theme == value) {
      return;
    }
    _theme = value;
    _engine.theme = value;
    _highlightCache.clear();
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

    if (_highlightCache.isEmpty || newCodeLines.length != oldCodeLines.length) {
      _processFullHighlight();
      return;
    }

    int firstDirtyLine = -1;
    for (int i = 0; i < newCodeLines.length; i++) {
      if (oldCodeLines[i] != newCodeLines[i]) {
        firstDirtyLine = i;
        break;
      }
    }

    if (firstDirtyLine != -1) {
      _processPartialHighlight(firstDirtyLine);
    }
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
        // Merge the partial results back into our main cache.
        partialResult.forEach((index, result) {
          if (index < _highlightCache.length) {
            _highlightCache[index] = result;
          }
        });
        // Notify listeners with the updated cache.
        value = List.of(_highlightCache);
    });
  }
}

class _CodeHighlightEngine {
  // A single tasker is enough, as our new _IsolateTasker handles "latest-only".
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

  // The main run method for full highlighting.
  void run(CodeLines codes, IsolateCallback<List<_HighlightResult>> callback) {
    if (_highlight == null) {
      callback([]);
      return;
    }
    _tasker.run(_createPayload(codes), callback);
  }

  // The new run method for partial highlighting.
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
    return _PartialHighlightPayload(
      highlight: _highlight!,
      codes: codes,
      dirtyLineIndex: dirtyLineIndex,
      language: _theme?.languages.keys.first ?? '', // Assuming one language
    );
  }

  @pragma('vm:entry-point')
  static List<_HighlightResult> _run(_HighlightPayload payload) {
    // This logic remains the same.
    final String code = payload.codes.asString(TextLineBreak.lf, false);
    final HighlightResult result;
    if (payload.languages.length == 1) {
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
    const int contextSize = 50; // Re-highlight 50 lines before and after.
    final int startLine = max(0, payload.dirtyLineIndex - contextSize);
    final int endLine = min(payload.codes.length, payload.dirtyLineIndex + contextSize);
    
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
      updatedResults[absoluteLineIndex] = renderer.lineResults[i];
    }
    
    return updatedResults;
  }
}

// Payload for full highlighting
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

// New payload for partial highlighting
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