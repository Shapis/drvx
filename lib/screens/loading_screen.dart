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

          // Probe to find total files by checking sequential indexes until first non-200
          setState(() => status = 'Scanning available files...');
          final probeClient = HttpClient();
          probeClient.connectionTimeout = const Duration(seconds: 10);
          int probeIndex = 0;
          while (true) {
            final fileName =
                'VirusShare_${probeIndex.toString().padLeft(5, '0')}.md5';
            final uri = Uri.parse('https://virusshare.com/hashfiles/$fileName');
            try {
              final req = await probeClient
                  .openUrl('HEAD', uri)
                  .timeout(const Duration(seconds: 10));
              final resp = await req.close().timeout(
                const Duration(seconds: 10),
              );
              if (resp.statusCode == 200) {
                probeIndex++;
                continue;
              }
              break;
            } catch (_) {
              break;
            }
          }
          probeClient.close(force: true);

          totalFiles = probeIndex;
          if (totalFiles == 0) {
            setState(() {
              busy = false;
              status = 'No files found.';
            });
          } else {
            // Sequentially download missing files
            final downloadClient = HttpClient();
            downloadClient.connectionTimeout = const Duration(seconds: 15);
            for (int i = 0; i < totalFiles; i++) {
              final fileName = 'VirusShare_${i.toString().padLeft(5, '0')}.md5';
              final outFile = File('${threatDir.path}/$fileName');
              if (await outFile.exists()) {
                completed++;
                setState(() => status = 'Skipping $fileName (exists)');
                continue;
              }

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
              setState(() {});
            }
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

    // After work is done (or immediately if not Linux), navigate to HomeScreen
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
              const CircularProgressIndicator(),
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
