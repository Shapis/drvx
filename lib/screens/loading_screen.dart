import 'dart:async';
import 'dart:io' show Platform, Directory, HttpClient, File;
import 'package:flutter/material.dart';
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

          // Probe to find total files by checking sequential indexes in parallel batches
          setState(() => status = 'Scanning available files...');
          final probeClient = HttpClient();
          probeClient.connectionTimeout = const Duration(seconds: 10);
          int probeIndex = 0;
          const int batchSize = 16;
          final Uri baseUri = Uri.parse('https://virusshare.com/hashfiles/');

          bool stop = false;
          while (!stop) {
            final int start = probeIndex;
            final int end = start + batchSize;
            // Launch HEAD requests in parallel for batch
            final List<Future<int>> futures = [];
            for (int i = start; i < end; i++) {
              final fileName = 'VirusShare_${i.toString().padLeft(5, '0')}.md5';
              final uri = baseUri.replace(path: '${baseUri.path}$fileName');
              futures.add(
                Future<int>(() async {
                  try {
                    final req = await probeClient
                        .openUrl('HEAD', uri)
                        .timeout(const Duration(seconds: 8));
                    final resp = await req.close().timeout(
                      const Duration(seconds: 8),
                    );
                    return resp.statusCode;
                  } catch (_) {
                    return -1;
                  }
                }),
              );
            }

            final results = await Future.wait(futures);
            // Walk results in order to find first non-200
            for (int i = 0; i < results.length; i++) {
              final code = results[i];
              if (code == 200) {
                probeIndex++;
                continue;
              }
              stop = true;
              break;
            }
            // if none in batch failed, loop will continue
          }
          probeClient.close(force: true);

          totalFiles = probeIndex;
          if (totalFiles == 0) {
            setState(() {
              busy = false;
              status = 'No files found.';
            });
          } else {
            // Parallelize downloads with limited concurrency
            final downloadClient = HttpClient();
            downloadClient.connectionTimeout = const Duration(seconds: 15);
            final List<int> indices = List<int>.generate(totalFiles, (i) => i);
            const int concurrency = 6;
            final List<Future<void>> workers = [];
            for (int w = 0; w < concurrency; w++) {
              workers.add(
                Future<void>(() async {
                  while (true) {
                    int index;
                    // synchronous pop from the list
                    if (indices.isEmpty) break;
                    index = indices.removeLast();

                    final fileName =
                        'VirusShare_${index.toString().padLeft(5, '0')}.md5';
                    final outFile = File('${threatDir.path}/$fileName');
                    if (await outFile.exists()) {
                      completed++;
                      if (mounted)
                        setState(() => status = 'Skipping $fileName (exists)');
                      continue;
                    }

                    if (mounted)
                      setState(() => status = 'Downloading $fileName');
                    try {
                      final uri = Uri.parse(
                        'https://virusshare.com/hashfiles/$fileName',
                      );
                      final req = await downloadClient
                          .getUrl(uri)
                          .timeout(const Duration(seconds: 15));
                      final resp = await req.close().timeout(
                        const Duration(seconds: 30),
                      );
                      if (resp.statusCode == 200) {
                        final sink = outFile.openWrite();
                        await resp.pipe(sink);
                        await sink.flush();
                        await sink.close();
                      } else {
                        // ignore: avoid_print
                        print(
                          'Failed to download $fileName: HTTP ${resp.statusCode}',
                        );
                      }
                    } catch (e) {
                      // ignore: avoid_print
                      print('Error downloading $fileName: $e');
                    }

                    completed++;
                    if (mounted) setState(() {});
                  }
                }),
              );
            }

            await Future.wait(workers);
            downloadClient.close(force: true);
            setState(() {
              busy = false;
              status = 'Completed';
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
