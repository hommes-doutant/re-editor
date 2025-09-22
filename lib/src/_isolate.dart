part of re_editor;

typedef IsolateRunnable<Req, Res> = Res Function(Req req);
typedef IsolateCallback<Res> = void Function(Res res);

/// A wrapper to hold a request and its corresponding callback.
class _Request<Req, Res> {
  final Req request;
  final IsolateCallback<Res> callback;
  _Request(this.request, this.callback);
}

/// A smarter isolate task scheduler that only processes the latest request,
/// effectively cancelling any intermediate, outdated requests.
class _IsolateTasker<Req, Res> {
  final String name;
  final IsolateRunnable<Req, Res> _runnable;
  
  IsolateManager<Res, Req>? _isolateManager;
  _Request<Req, Res>? _pendingRequest;
  bool _isProcessing = false;

  _IsolateTasker(this.name, this._runnable) {
    _isolateManager = IsolateManager.create(
      _runnable,
      concurrent: 1, // We must use a concurrency of 1 for this logic to work.
    );
  }

  /// Schedules a request to be run. If another request is submitted before
  /// this one begins processing, this one will be discarded.
  void run(Req req, IsolateCallback<Res> callback) {
    _pendingRequest = _Request(req, callback);
    _ensureProcessing();
  }

  /// The core processing loop.
  void _ensureProcessing() async {
    // If a loop is already running, it will pick up the latest request. Do nothing.
    if (_isProcessing) {
      return;
    }

    _isProcessing = true;

    // Continue processing as long as there are pending requests.
    while (_pendingRequest != null) {
      // Pick up the latest request and clear the pending slot.
      final currentRequest = _pendingRequest!;
      _pendingRequest = null;

      // Execute the task in the isolate and wait for the result.
      final result = await _isolateManager?.compute(currentRequest.request);

      // After the task is complete, check if a *new* request has come in
      // while we were busy processing.
      if (_pendingRequest == null) {
        // No new request. This result is the latest, so we can use it.
        if (result != null) {
          currentRequest.callback(result);
        }
      } else {
        // A new request arrived. The result we just computed is stale. Discard it.
        // The loop will now immediately start processing the new pending request.
      }
    }

    _isProcessing = false;
  }

  void close() {
    // Clear any pending request and stop the isolate manager.
    _pendingRequest = null;
    _isolateManager?.stop();
    _isolateManager = null;
  }
}