import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// HLS (.m3u8) Live match stream player.
///
/// Master Prompt Blueprint 3 — plays adaptive HTTP Live Streams for live
/// matches with a memory-safe Chewie/VideoPlayer lifecycle (controllers are
/// disposed together with the widget, and the stream URL switch re-initializes
/// the player instead of leaking the old controller).
class HLSVideoPlayer extends StatefulWidget {
  final String streamUrl;
  final String matchTitle;

  const HLSVideoPlayer({
    super.key,
    required this.streamUrl,
    required this.matchTitle,
  });

  @override
  State<HLSVideoPlayer> createState() => _HLSVideoPlayerState();
}

class _HLSVideoPlayerState extends State<HLSVideoPlayer> {
  late final VideoPlayerController _videoPlayerController;
  ChewieController? _chewieController;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  @override
  void didUpdateWidget(HLSVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Switching channels must not leak the previous controller.
    if (oldWidget.streamUrl != widget.streamUrl) {
      _videoPlayerController.dispose();
      _chewieController?.dispose();
      _chewieController = null;
      _hasError = false;
      _initializePlayer();
    }
  }

  Future<void> _initializePlayer() async {
    try {
      _videoPlayerController = VideoPlayerController.networkUrl(
        Uri.parse(widget.streamUrl),
      );
      await _videoPlayerController.initialize();

      _chewieController = ChewieController(
        videoPlayerController: _videoPlayerController,
        autoPlay: true,
        looping: false,
        aspectRatio: 16 / 9,
        allowFullScreen: true,
        allowedScreenSleep: false,
        errorBuilder: (context, errorMessage) {
          return Center(
            child: Text(
              'လိုင်းအဆင်မပြေပါ: $errorMessage',
              style: const TextStyle(color: Colors.white),
            ),
          );
        },
      );
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _videoPlayerController.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Container(
        height: 220,
        color: const Color(0xFF0F172A),
        child: Center(
          child: Text(
            'Live ထုတ်လွှင့်မှု ခေတ္တရပ်နားထားပါသည် — ${widget.matchTitle}',
            style: const TextStyle(color: Colors.redAccent, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: (_chewieController != null &&
              _chewieController!.videoPlayerController.value.isInitialized)
          ? Chewie(controller: _chewieController!)
          : Container(
              color: const Color(0xFF1E293B),
              child: const Center(
                child: CircularProgressIndicator(color: Colors.amber),
              ),
            ),
    );
  }
}