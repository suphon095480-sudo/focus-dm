// FocusDM — Instagram แบบมีแค่ แชท + สตอรี่ + ดูคลิปที่เพื่อนส่งมา (ไม่มีฟีดรีลส์ให้เลื่อน)
//
// หลักการ 2 ชั้น
//  1) ชั้นบังคับ (Dart): ดักทุก URL ที่เว็บ IG พยายามเปิด ถ้าเป็น /reels/ (ฟีด), /explore/,
//     โปรไฟล์ หรือลิงก์ภายนอก จะถูกบล็อก ไม่ว่าผู้ใช้จะกดปุ่มไหนก็ตาม
//  2) ชั้นตกแต่ง (CSS/JS): ซ่อนแถบล่างของ IG เอง, ซ่อนฟีดโพสต์ในแท็บสตอรี่, และล็อกการเลื่อน
//     ตอนดูคลิปเดี่ยว ชั้นนี้ขึ้นกับหน้าตาเว็บ IG จึงอาจต้องปรับเมื่อ IG เปลี่ยนหน้าเว็บ

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: _bg,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: _bg,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const FocusDmApp());
}

// ───────────────────────── ตั้งค่า ─────────────────────────

/// สีพื้นหลังเดียวกับโหมดมืดของ IG ทำให้แถบของแอพกลมกลืนกับหน้าเว็บ
const _bg = Color(0xFF0C1014);

const _inboxUrl = 'https://www.instagram.com/direct/inbox/';
const _storiesUrl = 'https://www.instagram.com/';

/// อนุญาตให้เปิดหน้าโปรไฟล์ได้ไหม (โปรไฟล์มีกริดโพสต์/รีลส์ให้เลื่อน จึงปิดไว้เป็นค่าเริ่มต้น)
const _allowProfiles = false;

// ใช้ User-Agent ของเบราว์เซอร์มือถือปกติ เพื่อให้ IG แสดงหน้าเว็บมือถือเต็ม ๆ
const _androidUa =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';
const _iosUa =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1';

/// CSS ตกแต่ง — ถ้า IG เปลี่ยนหน้าเว็บ ให้มาแก้ selector ตรงนี้
/// data-focusdm ถูกตั้งโดย JS ด้านล่าง: home | inbox | thread | story | clip | other
const _css = r'''
/* ซ่อนลิงก์ไปรีลส์/สำรวจ (การบล็อกจริงทำใน Dart อยู่แล้ว อันนี้แค่ไม่ให้เห็น) */
a[href="/reels/"], a[href="/reels"], a[href="/explore/"], a[href="/explore"] {
  display: none !important;
}
/* องค์ประกอบที่ JS ทำเครื่องหมายไว้ว่าต้องซ่อน (แถบล่างของ IG, ฟีดใต้แถบสตอรี่) */
[data-focusdm-hide] {
  display: none !important;
}
/* หน้าแรก: เหลือเฉพาะแถบสตอรี่ ซ่อนโพสต์และวงกลมโหลดฟีด */
html[data-focusdm="home"] article,
html[data-focusdm="home"] [role="progressbar"],
html[data-focusdm="home"] svg[aria-label="Loading..."],
html[data-focusdm="home"] svg[aria-label="Loading"],
html[data-focusdm="home"] svg[aria-label="กำลังโหลด..."] {
  display: none !important;
}
/* ตอนดูคลิปเดี่ยว: ห้ามเลื่อนหน้า */
html[data-focusdm="clip"], html[data-focusdm="clip"] body {
  overflow: hidden !important;
  overscroll-behavior: none !important;
}
''';

const _jsTemplate = r'''
(function () {
  if (window.__focusdm) return;
  window.__focusdm = true;

  var style = document.createElement('style');
  style.id = 'focusdm-style';
  style.textContent = __CSS__;
  (document.head || document.documentElement).appendChild(style);

  function mode() {
    var p = location.pathname;
    if (/^\/(reel|reels|p|tv)\/[^\/]+/.test(p) && !/^\/reels\/(audio|videos)(\/|$)/.test(p)) return 'clip';
    if (p === '/') return 'home';
    if (p.indexOf('/stories/') === 0) return 'story';
    if (p === '/direct/' || p === '/direct/inbox/' || p === '/direct/inbox') return 'inbox';
    if (p.indexOf('/direct/') === 0) return 'thread';
    return 'other';
  }

  // ล็อกการเลื่อนเฉพาะตอนดูคลิปเดี่ยว (ถอด listener ออกเมื่อไม่ใช้ ไม่งั้นหน้าอื่นจะเลื่อนกระตุก)
  var locked = false;
  function lock(e) {
    if (e.cancelable) e.preventDefault();
  }
  function setLock(on) {
    if (on === locked) return;
    locked = on;
    var fn = on ? 'addEventListener' : 'removeEventListener';
    document[fn]('touchmove', lock, { passive: false, capture: true });
    document[fn]('wheel', lock, { passive: false, capture: true });
  }

  function clearFeed() {
    var hidden = document.querySelectorAll('[data-focusdm-hide="feed"]');
    for (var i = 0; i < hidden.length; i++) hidden[i].removeAttribute('data-focusdm-hide');
  }

  // ซ่อนแถบล่างของ IG เอง (บ้าน/ข้อความ/โปรไฟล์) เพราะแอพมีแถบของตัวเองอยู่แล้ว
  // หาจากองค์ประกอบที่ตรึงอยู่ล่างสุดของจอ ไม่ขึ้นกับชื่อคลาสของ IG
  function hideBottomBar() {
    var old = document.querySelector('[data-focusdm-hide="bar"]');
    if (old && old.isConnected) return;
    var els = document.elementsFromPoint(window.innerWidth / 2, window.innerHeight - 8);
    for (var i = 0; i < els.length; i++) {
      var n = els[i];
      while (n && n !== document.body && n !== document.documentElement) {
        var pos = getComputedStyle(n).position;
        if (pos === 'fixed' || pos === 'sticky') {
          var r = n.getBoundingClientRect();
          if (r.height < window.innerHeight * 0.3 && r.bottom > window.innerHeight - 4) {
            n.setAttribute('data-focusdm-hide', 'bar');
            return;
          }
          break;
        }
        n = n.parentElement;
      }
    }
  }

  // หน้าแรก: ซ่อนทุกอย่างที่อยู่ "ใต้" แถบสตอรี่ (ฟีดโพสต์/รีลส์แนะนำ/วงกลมโหลด)
  function hideFeed() {
    var links = Array.prototype.filter.call(
      document.querySelectorAll('a[href^="/stories/"]'),
      function (a) { return !a.closest('article'); }
    );
    if (links.length < 2) return;
    var first = links[0];
    var last = links[links.length - 1];
    var tray = first;
    while (tray && !tray.contains(last)) tray = tray.parentElement;
    if (!tray || tray === document.body || tray === document.documentElement) return;

    var n = tray;
    while (n && n !== document.body && n.parentElement !== document.body) {
      var s = n.nextElementSibling;
      while (s) {
        if (!s.hasAttribute('data-focusdm-hide')) s.setAttribute('data-focusdm-hide', 'feed');
        s = s.nextElementSibling;
      }
      n = n.parentElement;
    }
  }

  function tidy() {
    var m = mode();
    if (m === 'home' || m === 'inbox') hideBottomBar();
    if (m === 'home') hideFeed();
    else clearFeed();
  }

  // งานหนักทำแบบหน่วงเวลา (สูงสุดครั้งละ ~0.5 วินาที) เพื่อไม่ให้หน้าเว็บกระตุก
  var timer = null;
  function schedule(delay) {
    if (timer) return;
    timer = setTimeout(function () {
      timer = null;
      try { tidy(); } catch (e) {}
    }, delay === undefined ? 500 : delay);
  }
  new MutationObserver(function () { schedule(); })
    .observe(document.documentElement, { childList: true, subtree: true });

  // IG เป็น SPA เปลี่ยนหน้าโดยไม่โหลดใหม่ จึงเช็กโหมดเป็นระยะ (เบามาก ไม่แตะ DOM ถ้าโหมดไม่เปลี่ยน)
  var current = '';
  function syncMode() {
    var m = mode();
    if (m === current) return;
    current = m;
    document.documentElement.setAttribute('data-focusdm', m);
    setLock(m === 'clip');
    schedule(0);
  }
  syncMode();
  setInterval(syncMode, 400);
})();
''';

final _script = _jsTemplate.replaceFirst('__CSS__', jsonEncode(_css));

// ───────────────────── จัดประเภท URL ─────────────────────

enum _Kind { chat, stories, clip, other, blocked, external }

bool _isHost(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

_Kind _classify(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'about' || scheme == 'data' || scheme == 'blob') {
    return _Kind.other;
  }
  // instagram:// , intent:// ฯลฯ (IG ชอบพยายามเด้งไปเปิดแอพจริง) → บล็อก
  if (scheme != 'http' && scheme != 'https') return _Kind.external;

  final host = uri.host.toLowerCase();
  // facebook.com อนุญาตไว้เฉพาะเพื่อ "เข้าสู่ระบบด้วย Facebook"
  if (_isHost(host, 'facebook.com')) return _Kind.other;
  if (!_isHost(host, 'instagram.com')) return _Kind.external;

  final seg = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (seg.isEmpty) return _Kind.stories; // หน้าแรก → แสดงเฉพาะแถบสตอรี่

  switch (seg.first) {
    case 'direct':
      return _Kind.chat;
    case 'stories':
      return _Kind.stories;
    case 'reels':
      // /reels/ เฉย ๆ = ฟีดเลื่อนไม่รู้จบ → บล็อก
      // /reels/<code>/ = คลิปเดี่ยว (ลิงก์ที่เพื่อนส่งมา) → อนุญาต
      if (seg.length == 1 || seg[1] == 'audio' || seg[1] == 'videos') {
        return _Kind.blocked;
      }
      return _Kind.clip;
    case 'reel':
    case 'p':
    case 'tv':
      return seg.length >= 2 ? _Kind.clip : _Kind.blocked;
    case 'explore':
      return _Kind.blocked;
    case 'accounts':
    case 'challenge':
    case 'auth_platform':
    case 'oauth':
    case 'consent':
    case 'privacy':
    case 'legal':
    case 'web':
    case 'api':
    case 'graphql':
    case 'ajax':
      return _Kind.other; // หน้าล็อกอิน/ยืนยันตัวตน/ระบบหลังบ้าน
    default:
      // ส่วนที่เหลือคือหน้าโปรไฟล์ /<username>/
      return _allowProfiles ? _Kind.other : _Kind.blocked;
  }
}

// ───────────────────────── UI ─────────────────────────

class FocusDmApp extends StatelessWidget {
  const FocusDmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FocusDM',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.indigo,
        scaffoldBackgroundColor: _bg,
      ),
      home: const _FocusHome(),
    );
  }
}

class _FocusHome extends StatefulWidget {
  const _FocusHome();

  @override
  State<_FocusHome> createState() => _FocusHomeState();
}

class _FocusHomeState extends State<_FocusHome> {
  late final WebViewController _web;
  int _tab = 0; // 0 = แชท, 1 = สตอรี่
  bool _inClip = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(_bg)
      ..setUserAgent(Platform.isIOS ? _iosUa : _androidUa)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onUrlChange: (change) => _onUrlChange(change.url),
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
            _web.runJavaScript(_script);
          },
        ),
      )
      ..loadRequest(Uri.parse(_inboxUrl));
  }

  void _say(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// ชั้นบังคับ #1: การนำทางแบบโหลดหน้าใหม่
  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    if (!request.isMainFrame) return NavigationDecision.navigate;
    final uri = Uri.tryParse(request.url);
    if (uri == null) return NavigationDecision.prevent;

    switch (_classify(uri)) {
      case _Kind.blocked:
        _say('หน้านี้ถูกซ่อนไว้เพื่อให้โฟกัส');
        return NavigationDecision.prevent;
      case _Kind.external:
        _say('ลิงก์ภายนอกถูกบล็อก');
        return NavigationDecision.prevent;
      default:
        return NavigationDecision.navigate;
    }
  }

  /// ชั้นบังคับ #2: IG เป็น SPA เปลี่ยนหน้าด้วย pushState ซึ่งไม่ผ่าน onNavigationRequest
  /// จึงต้องฟัง URL change ด้วย ถ้าหลุดไปหน้าที่ห้าม ให้ดีดกลับ
  void _onUrlChange(String? url) {
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    final kind = _classify(uri);
    if (kind == _Kind.blocked) {
      _say('หน้านี้ถูกซ่อนไว้เพื่อให้โฟกัส');
      _web.loadRequest(Uri.parse(_tab == 1 ? _storiesUrl : _inboxUrl));
      return;
    }
    if (!mounted) return;
    setState(() {
      _inClip = kind == _Kind.clip;
      if (kind == _Kind.chat) _tab = 0;
      if (kind == _Kind.stories) _tab = 1;
    });
  }

  void _selectTab(int index) {
    setState(() {
      _tab = index;
      _inClip = false;
    });
    _web.loadRequest(Uri.parse(index == 0 ? _inboxUrl : _storiesUrl));
  }

  Future<void> _goBack() async {
    if (await _web.canGoBack()) {
      await _web.goBack();
    } else if (_inClip) {
      _selectTab(_tab);
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        backgroundColor: _bg,
        body: SafeArea(
          child: Stack(
            children: [
              WebViewWidget(controller: _web),
              if (_loading)
                const LinearProgressIndicator(
                  minHeight: 2,
                  backgroundColor: Colors.transparent,
                ),
              if (_inClip)
                Positioned(
                  top: 8,
                  left: 8,
                  child: FloatingActionButton.small(
                    heroTag: 'back',
                    onPressed: _goBack,
                    tooltip: 'กลับไปแชท',
                    child: const Icon(Icons.arrow_back),
                  ),
                ),
            ],
          ),
        ),
        bottomNavigationBar: DecoratedBox(
          decoration: const BoxDecoration(
            color: _bg,
            border: Border(
              top: BorderSide(color: Colors.white12, width: 0.5),
            ),
          ),
          child: NavigationBar(
            height: 60,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            indicatorColor: Colors.white12,
            labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
            selectedIndex: _tab,
            onDestinationSelected: _selectTab,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                selectedIcon: Icon(Icons.chat_bubble),
                label: 'แชท',
              ),
              NavigationDestination(
                icon: Icon(Icons.auto_stories_outlined),
                selectedIcon: Icon(Icons.auto_stories),
                label: 'สตอรี่',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
