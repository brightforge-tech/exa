import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/browser_session_repository.dart';
import '../../services/browser/browser_bridge.dart';
import '../../shared/providers.dart';

final browserSessionRepositoryProvider = Provider(
    (ref) => BrowserSessionRepository(ref.watch(appDatabaseProvider)));

const _defaultHomeUrl = 'https://www.google.com/';

class _BrowserTab {
  _BrowserTab({required this.sessionId, required this.initialUrl});

  final String sessionId;
  final String initialUrl;
  InAppWebViewController? controller;
  String title = 'New tab';
  String currentUrl = '';
}

/// Secure in-app browser (Phase 5). The user can log into web apps; nothing
/// is read from a page unless they explicitly tap "Send to Exa" and confirm.
class BrowserScreen extends ConsumerStatefulWidget {
  const BrowserScreen({super.key});

  @override
  ConsumerState<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends ConsumerState<BrowserScreen> {
  final List<_BrowserTab> _tabs = [];
  int _activeTab = 0;
  final _urlController = TextEditingController();
  bool _restored = false;
  BrowserBridge? _bridge;

  @override
  void initState() {
    super.initState();
    _restoreTabs();
    // Make open tabs readable by the agent's browser tools (reading page
    // content always asks the user first).
    final bridge = ref.read(browserBridgeProvider);
    bridge.register(
      listTabs: _listOpenTabs,
      snapshotTab: _takeSnapshot,
      openUrl: (url) => _newTab(url),
    );
    _bridge = bridge;
  }

  @override
  void dispose() {
    _bridge?.unregister(_takeSnapshot);
    _urlController.dispose();
    super.dispose();
  }

  Future<List<BrowserTabInfo>> _listOpenTabs() async => [
        for (var i = 0; i < _tabs.length; i++)
          BrowserTabInfo(
            index: i,
            title: _tabs[i].title,
            url: _tabs[i].currentUrl.isEmpty
                ? _tabs[i].initialUrl
                : _tabs[i].currentUrl,
            isActive: i == _activeTab,
          ),
      ];

  /// [tabIndex] null = active tab. Background tabs stay alive in the
  /// IndexedStack, so they are readable without switching to them.
  Future<BrowserPageSnapshot?> _takeSnapshot(int? tabIndex) async {
    final tab = tabIndex == null
        ? _current
        : (tabIndex >= 0 && tabIndex < _tabs.length
            ? _tabs[tabIndex]
            : null);
    final controller = tab?.controller;
    if (controller == null) return null;
    final title = await controller.getTitle() ?? 'Untitled page';
    final url = (await controller.getUrl())?.toString() ?? '';
    final text = (await controller.evaluateJavascript(
            source: 'document.body ? document.body.innerText : ""'))
        ?.toString();
    if (text == null || text.trim().isEmpty) return null;
    return BrowserPageSnapshot(
        title: title, url: url, text: text.trim());
  }

  Future<void> _restoreTabs() async {
    final sessions =
        await ref.read(browserSessionRepositoryProvider).listTabs();
    setState(() {
      _tabs.addAll([
        for (final session in sessions)
          _BrowserTab(
            sessionId: session['id'] as String,
            initialUrl: session['url'] as String,
          )..title = (session['title'] as String?) ?? 'Tab',
      ]);
      _restored = true;
    });
    if (_tabs.isEmpty) await _newTab();
  }

  Future<void> _newTab([String url = _defaultHomeUrl]) async {
    final sessionId =
        await ref.read(browserSessionRepositoryProvider).addTab(url);
    setState(() {
      _tabs.add(_BrowserTab(sessionId: sessionId, initialUrl: url));
      _activeTab = _tabs.length - 1;
    });
  }

  Future<void> _closeTab(int index) async {
    final tab = _tabs[index];
    await ref
        .read(browserSessionRepositoryProvider)
        .removeTab(tab.sessionId);
    setState(() {
      _tabs.removeAt(index);
      if (_activeTab >= _tabs.length) {
        _activeTab = _tabs.isEmpty ? 0 : _tabs.length - 1;
      }
    });
    if (_tabs.isEmpty) await _newTab();
  }

  _BrowserTab? get _current =>
      _tabs.isEmpty || _activeTab >= _tabs.length ? null : _tabs[_activeTab];

  void _navigateToInput() {
    final tab = _current;
    if (tab?.controller == null) return;
    var input = _urlController.text.trim();
    if (input.isEmpty) return;
    final hasScheme = input.startsWith('http://') ||
        input.startsWith('https://');
    final looksLikeUrl = hasScheme || input.contains('.');
    final url = hasScheme
        ? input
        : looksLikeUrl
            ? 'https://$input'
            : 'https://www.google.com/search?q=${Uri.encodeComponent(input)}';
    tab!.controller!.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  /// The consent flow: extract page text, show the user exactly what will
  /// be shared, store only on explicit approval.
  Future<void> _sharePageWithExa() async {
    final tab = _current;
    final controller = tab?.controller;
    if (controller == null) return;

    final title = await controller.getTitle() ?? 'Untitled page';
    final url = (await controller.getUrl())?.toString() ?? '';
    final text = (await controller.evaluateJavascript(
            source: 'document.body ? document.body.innerText : ""'))
        ?.toString();

    if (text == null || text.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not read any text from this page.')));
      }
      return;
    }
    if (!mounted) return;

    final approved = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Send this page to Exa?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(dialogContext).textTheme.titleSmall),
                Text(url,
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 8),
                Text('${text.trim().length} characters of page text will '
                    'be stored locally and become readable by the '
                    'assistant. It is only sent to the AI service when '
                    'you ask Exa something that uses it.'),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Share with Exa')),
            ],
          ),
        ) ??
        false;
    if (!approved || !mounted) return;

    await ref.read(browserContextRepositoryProvider).add(
          pageTitle: title,
          pageUrl: url,
          extractedText: text.trim(),
          sessionId: tab!.sessionId,
        );
    await ref.read(auditRepositoryProvider).log(
      'user',
      'browser_page_shared',
      detail: {'title': title, 'url': url},
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Page shared with Exa. Ask about it in the chat!')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_restored) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: TextField(
          controller: _urlController,
          decoration: InputDecoration(
            hintText: 'Search or enter URL',
            isDense: true,
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          ),
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _navigateToInput(),
        ),
        actions: [
          IconButton(
            tooltip: 'Send this page to Exa',
            icon: const Icon(Icons.auto_awesome),
            onPressed: _sharePageWithExa,
          ),
          _TabCountButton(
            count: _tabs.length,
            onPressed: _showTabSwitcher,
          ),
        ],
      ),
      body: IndexedStack(
        index: _activeTab,
        children: [
          for (final tab in _tabs)
            InAppWebView(
              key: ValueKey(tab.sessionId),
              initialUrlRequest:
                  URLRequest(url: WebUri(tab.initialUrl)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
                // Third-party logins (Google etc.) check the UA string.
                userAgent:
                    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile '
                    'Safari/537.36',
              ),
              onWebViewCreated: (controller) =>
                  tab.controller = controller,
              onTitleChanged: (controller, title) {
                setState(() => tab.title = title ?? tab.title);
                ref.read(browserSessionRepositoryProvider).updateTab(
                      tab.sessionId,
                      title: title,
                    );
              },
              onLoadStop: (controller, url) {
                final urlString = url?.toString() ?? '';
                setState(() => tab.currentUrl = urlString);
                if (_tabs.indexOf(tab) == _activeTab) {
                  _urlController.text = urlString;
                }
                ref.read(browserSessionRepositoryProvider).updateTab(
                      tab.sessionId,
                      url: urlString,
                    );
              },
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        // Left inset keeps the floating nav button from covering controls.
        child: Padding(
          padding: const EdgeInsets.only(left: 76),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => _current?.controller?.goBack(),
            ),
            IconButton(
              icon: const Icon(Icons.arrow_forward),
              onPressed: () => _current?.controller?.goForward(),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _current?.controller?.reload(),
            ),
            IconButton(
              icon: const Icon(Icons.home_outlined),
              onPressed: () => _current?.controller?.loadUrl(
                  urlRequest:
                      URLRequest(url: WebUri(_defaultHomeUrl))),
            ),
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'New tab',
              onPressed: () => _newTab(),
            ),
            ],
          ),
        ),
      ),
    );
  }

  void _showTabSwitcher() {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => ListView(
        padding: const EdgeInsets.all(8),
        children: [
          for (var i = 0; i < _tabs.length; i++)
            ListTile(
              selected: i == _activeTab,
              leading: const Icon(Icons.public),
              title: Text(_tabs[i].title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(_tabs[i].currentUrl,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  Navigator.pop(sheetContext);
                  _closeTab(i);
                },
              ),
              onTap: () {
                setState(() {
                  _activeTab = i;
                  _urlController.text = _tabs[i].currentUrl;
                });
                Navigator.pop(sheetContext);
              },
            ),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New tab'),
            onTap: () {
              Navigator.pop(sheetContext);
              _newTab();
            },
          ),
        ],
      ),
    );
  }
}

class _TabCountButton extends StatelessWidget {
  const _TabCountButton({required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'Tabs',
      onPressed: onPressed,
      icon: Container(
        width: 24,
        height: 24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(
              color: Theme.of(context).colorScheme.onSurface, width: 1.5),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text('$count',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(fontWeight: FontWeight.bold)),
      ),
    );
  }
}
