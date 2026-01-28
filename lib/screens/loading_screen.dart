import 'dart:async';
import 'dart:io' show Platform, Directory;
import 'package:flutter/material.dart';
import 'package:drvx/services/threat_service.dart';
import 'package:drvx/screens/home_screen.dart';

class LoadingScreen extends StatefulWidget {
  const LoadingScreen({super.key});

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen> {
  int totalFiles = 0;
  int completed = 0; // number of files processed (downloaded or skipped)
  bool busy = true; // scanning/downloading in progress
  String status = 'Starting...';

  @override
  void initState() {
    super.initState();
    _startLoading();
  }

  Future<void> _startLoading() async {
    // Detect platform
    String platformName = 'unknown';
    try {
      if (Platform.isAndroid)
        platformName = 'android';
      else if (Platform.isIOS)
        platformName = 'ios';
      else if (Platform.isLinux)
        platformName = 'linux';
      else if (Platform.isWindows)
        platformName = 'windows';
      else if (Platform.isMacOS)
        platformName = 'macos';
    } catch (_) {
      platformName = 'unknown';
    }

    // If running on Linux, create ~/.drvx and ~/.drvx/threat_hashes
    if (platformName == 'linux') {
      try {
        final home = Platform.environment['HOME'] ?? '';
        if (home.isNotEmpty) {
          final baseDir = Directory('$home/.drvx');
          if (!await baseDir.exists()) await baseDir.create(recursive: true);

          final threatDir = Directory('${baseDir.path}/threat_hashes');
          if (!await threatDir.exists()) {
            await threatDir.create(recursive: true);
          }

          // Delegate probing and downloads to ThreatService
          setState(() => status = 'Scanning available files...');
          try {
            final total = await ThreatService.probeTotalFiles();
            totalFiles = total;
            if (totalFiles == 0) {
              setState(() {
                busy = false;
                status = 'No files found.';
              });
            } else {
              await ThreatService.downloadMissingFiles(
                totalFiles: totalFiles,
                threatDir: threatDir,
                onProgress: (c, t, s) {
                  completed = c;
                  if (mounted) setState(() => status = s);
                },
              );

              setState(() {
                busy = false;
                status = 'Completed';
              });
            }
          } catch (e) {
            // ignore: avoid_print
            print('Failed to initialize directories or downloads: $e');
            setState(() {
              busy = false;
              status = 'Error initializing storage';
            });
          }
        }
      } catch (e) {
        // ignore errors but log for debugging
        // ignore: avoid_print
        print('Failed to initialize directories or downloads: $e');
        setState(() {
          busy = false;
          status = 'Error initializing storage';
        });
      }
    }

    // After work is done (or immediately if not Linux), wait briefly then navigate
    if (!mounted) return;
    // small delay so user can read the final status
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacement(MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final progress = (totalFiles > 0) ? (completed / totalFiles) : null;
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              const SizedBox(height: 16),
              Text(status),
              const SizedBox(height: 12),
              SizedBox(
                width: 300,
                child: LinearProgressIndicator(value: progress),
              ),
              const SizedBox(height: 8),
              Text(totalFiles > 0 ? '$completed / $totalFiles' : ''),
            ] else ...[
              const Icon(
                Icons.check_circle_outline,
                size: 48,
                color: Colors.green,
              ),
              const SizedBox(height: 12),
              Text(status),
            ],
          ],
        ),
      ),
    );
  }
}
