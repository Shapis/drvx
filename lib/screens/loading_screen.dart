import 'dart:async';
import 'dart:io' show Platform, Directory;
import 'package:flutter/material.dart';
import 'package:drvx/services/threat_service.dart';
import 'package:drvx/screens/home_screen.dart';
import 'package:drvx/data/test_hashes.dart';

class LoadingScreen extends StatefulWidget {
  const LoadingScreen({super.key});

  @override
  State<LoadingScreen> createState() => _LoadingScreenState();
}

class _LoadingScreenState extends State<LoadingScreen>
    with TickerProviderStateMixin {
  int totalFiles = 0;
  int completed = 0; // number of files processed (downloaded or skipped)
  int completedHashFiles = 0; // number of hash files loaded
  int totalHashFiles = 0; // total hash files to load
  int loadedHashes = 0; // number of hashes loaded
  bool busy = true; // scanning/downloading in progress
  String phase = 'Starting...'; // What we're currently doing
  String progressDetails = ''; // Progress numbers (shown below)
  Set<String> threatHashes = {};
  late AnimationController _idleAnimationController;

  @override
  void initState() {
    super.initState();
    _idleAnimationController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();
    _idleAnimationController.addListener(() {
      if (mounted && totalFiles == 0 && completed == 0) {
        setState(() {});
      }
    });
    _startLoading();
  }

  @override
  void dispose() {
    _idleAnimationController.dispose();
    super.dispose();
  }

  Future<void> _startLoading() async {
    // Detect platform
    String platformName = 'unknown';
    try {
      if (Platform.isAndroid) {
        platformName = 'android';
      } else if (Platform.isIOS)
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
          setState(() => phase = 'Checking available files...');
          try {
            final total = await ThreatService.probeTotalFiles();
            totalFiles = total;
            if (totalFiles == 0) {
              setState(() {
                busy = false;
                phase = 'No files found.';
              });
            } else {
              setState(() => phase = 'Downloading threat data...');
              await ThreatService.downloadMissingFiles(
                totalFiles: totalFiles,
                threatDir: threatDir,
                onProgress: (c, t, s) {
                  completed = c;
                  if (mounted) {
                    setState(() {
                      progressDetails = '$c / $t';
                    });
                  }
                },
              );

              // Load threat hashes into memory
              setState(() {
                phase = 'Loading threat hashes...';
                totalHashFiles = 0;
                completedHashFiles = 0;
                loadedHashes = 0;
                progressDetails = '';
              });
              threatHashes = await ThreatService.loadThreatHashes(
                threatDir,
                onProgress: (completed, total, hashCount) {
                  if (mounted) {
                    setState(() {
                      completedHashFiles = completed;
                      totalHashFiles = total;
                      loadedHashes = hashCount;
                      progressDetails =
                          '$completedHashFiles / $total files ($loadedHashes hashes)';
                    });
                  }
                },
              );

              // Merge test hashes
              threatHashes.addAll(TestHashes.getTestHashes());
              if (mounted) {
                setState(() {
                  loadedHashes = threatHashes.length;
                  progressDetails =
                      '$completedHashFiles / $totalHashFiles files (${threatHashes.length} hashes)';
                });
              }

              setState(() {
                busy = false;
                phase = 'Ready';
              });
            }
          } catch (e) {
            // ignore: avoid_print
            print('Failed to initialize directories or downloads: $e');
            setState(() {
              busy = false;
              phase = 'Error initializing storage';
            });
          }
        }
      } catch (e) {
        // ignore errors but log for debugging
        // ignore: avoid_print
        print('Failed to initialize directories or downloads: $e');
        setState(() {
          busy = false;
          phase = 'Error initializing storage';
        });
      }
    }

    // After work is done (or immediately if not Linux), wait briefly then navigate
    if (!mounted) return;
    // small delay so user can read the final status
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => HomeScreen(threatHashes: threatHashes)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Calculate progress: 33% for checking, 33% for downloads, 34% for hash loading
    double progress = 0.0;

    if (totalFiles == 0 && completed == 0) {
      // Checking files phase (0% to 33%) - show idle animation
      progress = 0.33 * _idleAnimationController.value;
    } else if (totalFiles > 0 && completedHashFiles == 0) {
      // Download phase (33% to 66%)
      double downloadProgress = (completed / totalFiles);
      progress = 0.33 + (downloadProgress * 0.33);
    } else if (totalHashFiles > 0) {
      // Hash loading phase (66% to 100%)
      double hashProgress = (completedHashFiles / totalHashFiles);
      progress = 0.66 + (hashProgress * 0.34);
    }

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              const SizedBox(height: 16),
              Text(phase),
              const SizedBox(height: 12),
              SizedBox(
                width: 300,
                child: LinearProgressIndicator(value: progress),
              ),
              const SizedBox(height: 8),
              Text(progressDetails),
            ] else ...[
              const Icon(
                Icons.check_circle_outline,
                size: 48,
                color: Colors.green,
              ),
              const SizedBox(height: 12),
              Text(phase),
            ],
          ],
        ),
      ),
    );
  }
}
