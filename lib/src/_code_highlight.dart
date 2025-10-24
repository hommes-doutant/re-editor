part of re_editor;

class _CodeHighlighter extends ValueNotifier<List<_HighlightResult>> {
  final BuildContext _context;
  final _CodeParagraphProvider _provider;
  final _CodeHighlightEngine _engine;

  CodeLineEditingController _controller;
  CodeHighlightTheme? _theme;

  int _highlightGeneration = 0;
  List<_HighlightResult> _highlightCache = [];

  // --- NEW FIELDS ---
  late _ChunkManager _chunkManager; // <<< ADD THIS
  final SplayTreeSet<int> _dirtyChunkIndices = SplayTreeSet<int>();
  bool _isProcessingDirtyChunks = false;
  int _documentGeneration = 0; // Tracks the version of the entire CodeLines object


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
    _chunkManager = _ChunkManager(_controller, _documentGeneration); // <<< INITIALIZE
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
    _processFullHighlight();
  }

  set theme(CodeHighlightTheme? value) {
    if (_theme == value) {
      return;
    }
    _theme = value;
    _engine.theme = value;
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

  void clearCache() {
    _provider.clearCache();
  }


  TextSpan _buildSpan(int index, TextStyle style) {
    final (chunkIndex, chunkStartLine) = _chunkManager.findChunkForLine(index);
    final lineInChunk = index - chunkStartLine;
    
    if (chunkIndex >= _chunkManager.chunkCount || lineInChunk >= _chunkManager[chunkIndex].results.length) {
       return TextSpan(text: _controller.codeLines[index].text, style: style);
    }
    
    final _HighlightResult result = _chunkManager[chunkIndex].results[lineInChunk];

    final String text = _controller.codeLines[index].text;
    if (result.nodes.isEmpty) {
      return TextSpan(
        text: text,
        style: style
      );
    }
    if (result.source == text) {
      return _buildSpanFromNodes(result.nodes, style);
    }
    // ... (the existing diffing logic remains here) ...
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
      midNode = _HighlightNode(text.substring(start, end), result.nodes[0].className);
    } else if (startNodes.length < result.nodes.length) {
      midNode = _HighlightNode(text.substring(start, end), result.nodes[startNodes.length].className);
    } else if (end > start){
      midNode = _HighlightNode(text.substring(start, end), result.nodes.last.className);
    } else {
      midNode = null;
    }
    return _buildSpanFromNodes([
      ...startNodes,
      if (midNode != null)
        midNode,
      ...endNodes
    ], style);
  }

  TextSpan _buildSpanFromNodes(List<_HighlightNode> nodes, TextStyle baseStyle) {
    return TextSpan(
      children: nodes.map((e) => TextSpan(
          text: e.value,
          style: _findStyle(e.className)
        )).toList(),
      style: baseStyle
    );
  }

  TextStyle? _findStyle(String? className) {
    if (className == null) {
      return null;
    }
    while(true) {
      final TextStyle? style = _theme?.theme[className];
      if (style != null) {
        return style;
      }
      final int pieceIndex = className!.indexOf('-');
      if (pieceIndex < 0) {
        break;
      }
      className = className.substring(pieceIndex + 1);
      if (className.isEmpty) {
        break;
      }
    }
    return null;
  }

  void _onCodesChanged() {
    final CodeLineEditingValue? preValue = _controller.preValue;
    if (preValue == null || _controller.codeLines == preValue.codeLines) {
      return;
    }

    _documentGeneration++;
    final int generation = _documentGeneration;
    _highlightGeneration++; 

    // Find difference range (same as before)
    int firstDiff = 0;
    while (firstDiff < preValue.codeLines.length &&
           firstDiff < _controller.codeLines.length &&
           preValue.codeLines[firstDiff] == _controller.codeLines[firstDiff]) {
      firstDiff++;
    }

    int lastDiffOld = preValue.codeLines.length - 1;
    int lastDiffNew = _controller.codeLines.length - 1;
    while (lastDiffOld >= firstDiff &&
           lastDiffNew >= firstDiff &&
           preValue.codeLines[lastDiffOld] == _controller.codeLines[lastDiffNew]) {
      lastDiffOld--;
      lastDiffNew--;
    }

    final int numDeleted = max(0, lastDiffOld - firstDiff + 1);
    final int numAdded = max(0, lastDiffNew - firstDiff + 1);

    // Use the ChunkManager to handle the structural changes
    final newDirtyChunks = _chunkManager.handleEdits(firstDiff, numDeleted, numAdded, generation);
    _dirtyChunkIndices.addAll(newDirtyChunks);
    
    // Trigger the processing loop
    _processDirtyChunks(generation);
  }
  
  void _rebuildChunks(int generation) {
    final newChunks = <_HighlightChunk>[];
    for (int i = 0; i < _controller.codeLines.length; i += _kHighlightChunkSize) {
      final int end = (i + _kHighlightChunkSize > _controller.codeLines.length) ? _controller.codeLines.length : i + _kHighlightChunkSize;
      final int lineCount = end - i;
      newChunks.add(_HighlightChunk.empty(lineCount, generation));
    }
    _chunkCache = newChunks;
    // Mark all chunks as dirty since the structure changed
    _dirtyChunkIndices.addAll(List.generate(newChunks.length, (i) => i));
  }
  
void _processDirtyChunks(int generation) async {
  // 1. Singleton Guard: Ensure only one processing loop runs at a time.
  // If a loop is already active, it will eventually pick up any newly
  // dirtied chunks we've added to the queue.
  if (_isProcessingDirtyChunks) {
    return;
  }
  _isProcessingDirtyChunks = true;

  // 2. The Main Loop: Continue as long as there's work to do.
  while (_dirtyChunkIndices.isNotEmpty) {
    // 3. Asynchronicity & UI Responsiveness: Yield to the event loop.
    // This prevents the highlighter from freezing the UI during large updates.
    await Future.delayed(Duration.zero);

    // 4. Cancellation Check (Post-Await): After yielding, a new edit might have
    // occurred. If our generation is stale, we must abort this entire run.
    if (generation != _documentGeneration) {
      _isProcessingDirtyChunks = false;
      return;
    }

    // 5. Dequeue the next chunk to process.
    // A SplayTreeSet efficiently gives us the lowest-indexed dirty chunk.
    final int chunkIndex = _dirtyChunkIndices.first;
    _dirtyChunkIndices.remove(chunkIndex);

    if (chunkIndex >= _chunkManager.chunkCount) {
      // This chunk index is no longer valid (e.g., document shrank). Skip it.
      continue;
    }

    // A Completer to wait for the isolate task to finish before the next loop iteration.
    // This is crucial for ensuring sequential propagation.
    final completer = Completer<void>();

    // 6. Prepare data for the isolate.
    final _HighlightChunk currentChunk = _chunkManager[chunkIndex];
    final _HighlightChunk oldChunk = _HighlightChunk(currentChunk.results, currentChunk.endState, currentChunk.generation); // Make a copy for later comparison.

    // The starting parser state is the end state of the previous chunk.
    final HighlightState? startState = chunkIndex > 0 ? _chunkManager[chunkIndex - 1].endState : null;

    // Calculate the line range for this chunk.
    final int startLine = chunkIndex * _kHighlightChunkSize;
    final int endLine = startLine + currentChunk.results.length;

    final chunkLines = <String>[];
    for (int i = startLine; i < endLine; i++) {
      chunkLines.add(_controller.codeLines[i].text);
    }
    final String text = chunkLines.join('\n');
    final String language = _theme?.languages.keys.firstOrNull ?? 'plaintext';

    // 7. Execute the highlighting task in the isolate.
    _engine.runChunk(text, language, startState, (result) {
      // 8. Handle the result in the callback.
      // Cancellation Check (Post-Isolate): The document could have changed AGAIN
      // while the isolate was busy. If so, discard this stale result.
      if (generation != _documentGeneration) {
        completer.complete();
        return;
      }

      // Update the chunk in our manager with the new results.
      currentChunk.results = result.lineResults;
      currentChunk.endState = result.endState;
      currentChunk.generation = generation;

      // 9. Propagation Logic: This is the key to correctness.
      // If the parser's state at the end of this chunk has changed, it means
      // the syntax change has "leaked" across the chunk boundary. We must
      // therefore mark the *next* chunk as dirty to be re-processed.
      final bool stateChanged = oldChunk.endState != currentChunk.endState;
      if (stateChanged && (chunkIndex + 1) < _chunkManager.chunkCount) {
        _dirtyChunkIndices.add(chunkIndex + 1);
      }

      // 10. Update the UI: Rebuild the flat list of results and notify listeners.
      _updateValueNotifier();

      // Signal that this iteration of the loop is complete.
      completer.complete();
    });

    // Wait for the current chunk to be processed before starting the next one.
    await completer.future;
  }

  // 11. Cleanup: All dirty chunks have been processed for this run.
  _isProcessingDirtyChunks = false;
}
  
  void _updateValueNotifier() {
    final newValue = <_HighlightResult>[];
    for (int i = 0; i < _chunkManager.chunkCount; i++) {
      newValue.addAll(_chunkManager[i].results);
    }
    value = newValue;
  }

  void _processFullHighlight() {
    _documentGeneration++;
    _highlightGeneration++;
    _dirtyChunkIndices.clear();

    // Rebuild via the manager
    _chunkManager = _ChunkManager(_controller, _documentGeneration);
    _dirtyChunkIndices.addAll(List.generate(_chunkManager.chunkCount, (i) => i));

    _processDirtyChunks(_documentGeneration);
  }
}

class _CodeHighlightEngine {
  late final _IsolateTasker<_HighlightPayload, List<_HighlightResult>> _tasker;
  late final _IsolateTasker<_PartialHighlightPayload, Map<int, _HighlightResult>> _partialTasker;
  late final _IsolateTasker<_PartialHighlightPayload, Map<int, _HighlightResult>> _initialLoadTasker;
  late final _IsolateTasker<_HighlightChunkPayload, _HighlightChunkResult> _chunkTasker;

  Highlight? _highlight;
  CodeHighlightTheme? _theme;

  _CodeHighlightEngine(final CodeHighlightTheme? theme) {
    this.theme = theme;
    _tasker = _IsolateTasker('CodeHighlightEngine', _run);
    _partialTasker = _IsolateTasker('PartialCodeHighlightEngine', _runPartial);
    _initialLoadTasker = _IsolateTasker('InitialCodeHighlightEngine', _runPartial);
    _chunkTasker = _IsolateTasker('ChunkCodeHighlightEngine', _runChunk);
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
    _initialLoadTasker.close();
    _chunkTasker.close();
  }

  void run(CodeLines codes, IsolateCallback<List<_HighlightResult>> callback) {
    if (_highlight == null) {
      callback([]);
      return;
    }
    _tasker.run(_createPayload(codes), callback);
  }
  
  void runChunk(String text, String language, HighlightState? startState, IsolateCallback<_HighlightChunkResult> callback) {
    if (_highlight == null) {
      callback(const _HighlightChunkResult([], null));
      return;
    }
    final payload = _HighlightChunkPayload(
      highlight: _highlight!,
      text: text,
      language: language,
      startState: startState,
    );
    _chunkTasker.run(payload, callback);
  }

  void runPartial(CodeLines codes, int dirtyLineIndex, IsolateCallback<Map<int, _HighlightResult>> callback) {
    if (_highlight == null) {
      callback({});
      return;
    }
    _partialTasker.run(_createPartialPayload(codes, dirtyLineIndex), callback);
  }

  void runInitialLoadChunk(CodeLines codes, int dirtyLineIndex, IsolateCallback<Map<int, _HighlightResult>> callback) {
    if (_highlight == null) {
      callback({});
      return;
    }
    _initialLoadTasker.run(_createPartialPayload(codes, dirtyLineIndex), callback);
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
  static _HighlightChunkResult _runChunk(_HighlightChunkPayload payload) {
    final result = payload.highlight.highlight(
      code: payload.text,
      language: payload.language,
      state: payload.startState,
    );
    final renderer = _HighlightLineRenderer();
    result.render(renderer);
    return _HighlightChunkResult(renderer.lineResults, result.state);
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

const int _kHighlightChunkSize = 50; // Configurable chunk size

class _ChunkManager {
  final List<_HighlightChunk> _chunks = [];
  final CodeLineEditingController _controller;
  int _documentGeneration;

  _ChunkManager(this._controller, this._documentGeneration) {
    _rebuild();
  }

  int get chunkCount => _chunks.length;
  _HighlightChunk operator [](int index) => _chunks[index];

  /// Finds the chunk index and the starting line number for that chunk
  /// for a given global line index.
  (int, int) findChunkForLine(int lineIndex) {
    // This can be optimized with a binary search if we cache cumulative line counts.
    // For now, a linear scan is simple and correct.
    int currentLine = 0;
    for (int i = 0; i < _chunks.length; i++) {
      final chunk = _chunks[i];
      if (lineIndex < currentLine + chunk.results.length) {
        return (i, currentLine);
      }
      currentLine += chunk.results.length;
    }
    // Should not happen if lineIndex is valid
    return (_chunks.length - 1, currentLine - _chunks.last.results.length);
  }

  /// Rebuilds all chunks from scratch.
  void _rebuild() {
    _chunks.clear();
    for (int i = 0; i < _controller.codeLines.length; i += _kHighlightChunkSize) {
      final int end = (i + _kHighlightChunkSize > _controller.codeLines.length) ? _controller.codeLines.length : i + _kHighlightChunkSize;
      final int lineCount = end - i;
      _chunks.add(_HighlightChunk.empty(lineCount, _documentGeneration));
    }
  }

  /// Handles insertions and deletions of lines, returning a set of dirty chunk indices.
  SplayTreeSet<int> handleEdits(int startLine, int numDeleted, int numAdded, int newGeneration) {
    _documentGeneration = newGeneration;
    final dirtyChunks = SplayTreeSet<int>();

    if (_chunks.isEmpty) {
      _rebuild();
      if (_chunks.isNotEmpty) {
        dirtyChunks.add(0);
      }
      return dirtyChunks;
    }

    final (startChunkIndex, chunkStartLine) = findChunkForLine(startLine);
    final lineInChunk = startLine - chunkStartLine;

    // --- The Core Logic ---
    // For simplicity and robustness, a common strategy is to invalidate and
    // partially rebuild the chunks around the edit boundary.

    // 1. Invalidate the starting chunk.
    dirtyChunks.add(startChunkIndex);

    // 2. Adjust the content of the starting chunk.
    final startChunk = _chunks[startChunkIndex];
    final originalEndState = startChunk.endState;

    // Remove deleted lines from the chunk's results cache
    if (numDeleted > 0) {
      final int deleteCountInChunk = min(numDeleted, startChunk.results.length - lineInChunk);
      startChunk.results.removeRange(lineInChunk, lineInChunk + deleteCountInChunk);
    }
    // Add placeholders for new lines
    if (numAdded > 0) {
      final placeholders = List.generate(numAdded, (_) => _HighlightResult([]));
      startChunk.results.insertAll(lineInChunk, placeholders);
    }
    startChunk.generation = _documentGeneration;

    // 3. Balance the chunks. If a chunk becomes too large, split it.
    // If it becomes too small, merge it with a neighbor.
    _balanceChunksFrom(startChunkIndex);

    // 4. Invalidate the next chunk if the start chunk's size changed,
    // as this implies its end state is now invalid.
    if (numAdded != numDeleted && startChunkIndex + 1 < _chunks.length) {
       dirtyChunks.add(startChunkIndex + 1);
    }

    return dirtyChunks;
  }

  /// Balances chunk sizes starting from a given index.
  void _balanceChunksFrom(int index) {
    for (int i = index; i < _chunks.length; i++) {
      final chunk = _chunks[i];

      // Split oversized chunks
      if (chunk.results.length > _kHighlightChunkSize * 2) {
        final int splitPoint = chunk.results.length ~/ 2;
        final newChunkLines = chunk.results.sublist(splitPoint);
        chunk.results.removeRange(splitPoint, chunk.results.length);
        // Mark both as needing full re-evaluation
        chunk.endState = null;
        final newChunk = _HighlightChunk(newChunkLines, null, _documentGeneration);
        _chunks.insert(i + 1, newChunk);
      }
      // Note: Merging undersized chunks can also be implemented here for
      // documents that see a lot of deletions, but splitting is often sufficient.
    }
  }
}

class _HighlightChunk {
  // The results for each line within this chunk.
  List<_HighlightResult> results;
  // The parser state at the END of this chunk.
  HighlightState? endState;
  // A generation marker to know if this chunk's data is from the latest document version.
  int generation;

  _HighlightChunk(this.results, this.endState, this.generation);

  factory _HighlightChunk.empty(int lineCount, int generation) {
    return _HighlightChunk(
      List.generate(lineCount, (_) => _HighlightResult([])),
      null,
      generation,
    );
  }
}

class _HighlightChunkPayload {
  final Highlight highlight;
  final String text;
  final String language;
  final HighlightState? startState;

  const _HighlightChunkPayload({
    required this.highlight,
    required this.text,
    required this.language,
    this.startState,
  });
}

class _HighlightChunkResult {
  final List<_HighlightResult> lineResults;
  final HighlightState? endState;

  const _HighlightChunkResult(this.lineResults, this.endState);
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