import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Plays a public YouTube video via the official IFrame Player API inside an
/// [InAppWebView]. The key trick is giving the page a real YouTube origin
/// (`baseUrl` = youtube-nocookie.com + a matching `origin` param), which is what
/// `enablejsapi=1` requires — without it the embed errors out (e.g. 152).
///
/// Exposes play/pause/seek/mute via a [GlobalKey] to its state, and reports
/// ready/state/error back through callbacks.
class YouTubeWebViewPlayer extends StatefulWidget {
  final String videoId;
  final bool autoPlay;
  final bool showControls;
  final ValueChanged<int>? onStateChanged; // -1,0,1,2,3,5
  final VoidCallback? onReady;
  final ValueChanged<int>? onError;

  const YouTubeWebViewPlayer({
    super.key,
    required this.videoId,
    this.autoPlay = true,
    this.showControls = true,
    this.onStateChanged,
    this.onReady,
    this.onError,
  });

  @override
  State<YouTubeWebViewPlayer> createState() => YouTubeWebViewPlayerState();
}

class YouTubeWebViewPlayerState extends State<YouTubeWebViewPlayer> {
  InAppWebViewController? _controller;
  bool _isReady = false;

  static const String _origin = 'https://www.youtube-nocookie.com';

  String _buildHtml() {
    final autoplay = widget.autoPlay ? 1 : 0;
    final controls = widget.showControls ? 1 : 0;
    final id = widget.videoId;
    // Always start muted for autoplay; unmute after the 'playing' event.
    return '''
<!DOCTYPE html><html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<meta name="referrer" content="strict-origin-when-cross-origin">
<style>*{margin:0;padding:0;overflow:hidden}html,body{width:100%;height:100%;background:#000}
#player{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
</head><body>
<iframe id="player" width="100%" height="100%"
  src="$_origin/embed/$id?enablejsapi=1&autoplay=$autoplay&mute=1&controls=$controls&playsinline=1&fs=1&iv_load_policy=3&rel=0&modestbranding=1&origin=$_origin"
  frameborder="0"
  allow="autoplay; encrypted-media; fullscreen; picture-in-picture; accelerometer; clipboard-write; gyroscope"
  referrerpolicy="strict-origin-when-cross-origin" allowfullscreen></iframe>
<script>
  var tag=document.createElement('script');tag.src='https://www.youtube.com/iframe_api';
  var s=document.getElementsByTagName('script')[0];s.parentNode.insertBefore(tag,s);
  var player;
  function onYouTubeIframeAPIReady(){
    player=new YT.Player('player',{events:{
      onReady:function(e){window.flutter_inappwebview.callHandler('onReady');},
      onStateChange:function(e){window.flutter_inappwebview.callHandler('onStateChange', e.data);},
      onError:function(e){window.flutter_inappwebview.callHandler('onError', e.data);}
    }});
  }
</script></body></html>
''';
  }

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data: _buildHtml(),
        baseUrl: WebUri(_origin), // <-- the origin trick
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        mediaPlaybackRequiresUserGesture: false,
        allowsInlineMediaPlayback: true,
        transparentBackground: true,
        supportMultipleWindows: false,
        javaScriptCanOpenWindowsAutomatically: false,
      ),
      onWebViewCreated: (c) {
        _controller = c;
        c.addJavaScriptHandler(
          handlerName: 'onReady',
          callback: (_) {
            _isReady = true;
            widget.onReady?.call();
          },
        );
        c.addJavaScriptHandler(
          handlerName: 'onStateChange',
          callback: (args) {
            if (args.isEmpty) return;
            final state = (args[0] as num).toInt();
            // Unmute once actually playing (still counts as a user gesture).
            if (state == 1 && widget.autoPlay) {
              Future.delayed(const Duration(milliseconds: 300), () {
                if (!mounted || _controller == null) return;
                _controller!.evaluateJavascript(source: '''
                  var mp=document.getElementById('movie_player');
                  if(mp&&mp.unMute){mp.unMute();mp.setVolume(100);}
                  else{var f=document.getElementById('player');
                    if(f){f.contentWindow.postMessage('{"event":"command","func":"unMute","args":""}','*');
                          f.contentWindow.postMessage('{"event":"command","func":"setVolume","args":[100]}','*');}}
                ''');
              });
            }
            widget.onStateChanged?.call(state);
          },
        );
        c.addJavaScriptHandler(
          handlerName: 'onError',
          callback: (args) {
            if (args.isNotEmpty) widget.onError?.call((args[0] as num).toInt());
          },
        );
      },
    );
  }

  Future<void> play() => _eval('player.playVideo()', 'mp.playVideo()', 'v.play()');
  Future<void> pause() =>
      _eval('player.pauseVideo()', 'mp.pauseVideo()', 'v.pause()');

  Future<void> seekTo(int seconds) => _eval(
        'player.seekTo($seconds,true);player.playVideo()',
        'mp.seekTo($seconds,true)',
        'v.currentTime=$seconds',
      );

  bool get isReady => _isReady;

  Future<void> _eval(String api, String mp, String raw) async {
    await _controller?.evaluateJavascript(source:
        'try{if(typeof player!=="undefined"&&player&&player.seekTo){$api;}'
        'else{var mp=document.getElementById("movie_player");if(mp){$mp;}'
        'else{var v=document.querySelector("video");if(v){$raw;}}}}catch(e){}');
  }

  @override
  void dispose() {
    _controller?.evaluateJavascript(source:
        'var mp=document.getElementById("movie_player");if(mp&&mp.stopVideo)mp.stopVideo();'
        'else{var v=document.querySelector("video");if(v)v.pause();}');
    _controller = null;
    super.dispose();
  }
}
