/// Lets the agent read pages open in the Browser tab.
///
/// The browser screen registers callbacks while it is alive; the
/// `list_browser_tabs` / `read_current_browser_page` tools call them.
/// Reading page content always requires user confirmation in chat.
class BrowserPageSnapshot {
  final String title;
  final String url;
  final String text;

  const BrowserPageSnapshot({
    required this.title,
    required this.url,
    required this.text,
  });
}

class BrowserTabInfo {
  final int index;
  final String title;
  final String url;
  final bool isActive;

  const BrowserTabInfo({
    required this.index,
    required this.title,
    required this.url,
    required this.isActive,
  });

  Map<String, Object?> toAgentJson() => {
        'tab_index': index,
        'title': title,
        'url': url,
        'active': isActive,
      };
}

typedef BrowserTabLister = Future<List<BrowserTabInfo>> Function();

/// [tabIndex] null reads the active tab.
typedef BrowserTabSnapshotter = Future<BrowserPageSnapshot?> Function(
    int? tabIndex);

class BrowserBridge {
  BrowserTabLister? _listTabs;
  BrowserTabSnapshotter? _snapshotTab;
  void Function(String url)? _openUrl;

  bool get isAvailable => _snapshotTab != null;

  void register({
    required BrowserTabLister listTabs,
    required BrowserTabSnapshotter snapshotTab,
    void Function(String url)? openUrl,
  }) {
    _listTabs = listTabs;
    _snapshotTab = snapshotTab;
    _openUrl = openUrl;
  }

  void unregister(BrowserTabSnapshotter snapshotTab) {
    // Only clear if a newer screen hasn't already replaced it.
    if (_snapshotTab == snapshotTab) {
      _snapshotTab = null;
      _listTabs = null;
      _openUrl = null;
    }
  }

  /// Opens a URL in a new browser tab if the browser screen is alive.
  /// Returns false when the caller should fall back (e.g. persist the tab
  /// to browser_sessions so it appears when the browser first opens).
  bool requestOpenUrl(String url) {
    final opener = _openUrl;
    if (opener == null) return false;
    opener(url);
    return true;
  }

  /// Open tabs, or empty when the browser hasn't been opened this session.
  Future<List<BrowserTabInfo>> listTabs() async {
    final lister = _listTabs;
    if (lister == null) return const [];
    try {
      return await lister();
    } catch (_) {
      return const [];
    }
  }

  /// Snapshot of a tab ([tabIndex] null = active tab), or null when the
  /// browser isn't open, the index is invalid, or the page has no text.
  Future<BrowserPageSnapshot?> takeSnapshot({int? tabIndex}) async {
    final snapshotter = _snapshotTab;
    if (snapshotter == null) return null;
    try {
      return await snapshotter(tabIndex);
    } catch (_) {
      return null;
    }
  }
}
