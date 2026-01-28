import 'dart:async';
import 'dart:io'
    show Directory, File, HttpClient, HttpClientRequest, HttpClientResponse;

class ThreatService {
  ThreatService._();

  static Future<int> probeTotalFiles({int batchSize = 16}) async {
    final probeClient = HttpClient();
    probeClient.connectionTimeout = const Duration(seconds: 10);
    int probeIndex = 0;
    final Uri baseUri = Uri.parse('https://virusshare.com/hashfiles/');

    bool stop = false;
    while (!stop) {
      final int start = probeIndex;
      final int end = start + batchSize;
      final List<Future<int>> futures = [];
      for (int i = start; i < end; i++) {
        final fileName = 'VirusShare_${i.toString().padLeft(5, '0')}.md5';
        final uri = baseUri.replace(path: '${baseUri.path}$fileName');
        futures.add(_headStatus(probeClient, uri));
      }

      final results = await Future.wait(futures);
      for (final code in results) {
        if (code == 200) {
          probeIndex++;
          continue;
        }
        stop = true;
        break;
      }
    }

    probeClient.close(force: true);
    return probeIndex;
  }

  static Future<int> _headStatus(HttpClient client, Uri uri) async {
    try {
      final HttpClientRequest req = await client
          .openUrl('HEAD', uri)
          .timeout(const Duration(seconds: 8));
      final HttpClientResponse resp = await req.close().timeout(
        const Duration(seconds: 8),
      );
      return resp.statusCode;
    } catch (_) {
      return -1;
    }
  }

  /// Downloads missing files into [threatDir].
  ///
  /// Calls [onProgress] with (completed, total, status) as progress updates.
  static Future<void> downloadMissingFiles({
    required int totalFiles,
    required Directory threatDir,
    required void Function(int completed, int total, String status) onProgress,
    int concurrency = 6,
  }) async {
    final downloadClient = HttpClient();
    downloadClient.connectionTimeout = const Duration(seconds: 15);

    int completed = 0;
    int nextIndex = totalFiles - 1;

    Future<void> worker() async {
      while (true) {
        if (nextIndex < 0) break;
        final int index = nextIndex--;

        final fileName = 'VirusShare_${index.toString().padLeft(5, '0')}.md5';
        final outFile = File('${threatDir.path}/$fileName');
        if (await outFile.exists()) {
          completed++;
          onProgress(completed, totalFiles, 'Skipping $fileName (exists)');
          continue;
        }

        onProgress(completed, totalFiles, 'Downloading $fileName');
        try {
          final uri = Uri.parse('https://virusshare.com/hashfiles/$fileName');
          final req = await downloadClient
              .getUrl(uri)
              .timeout(const Duration(seconds: 15));
          final resp = await req.close().timeout(const Duration(seconds: 30));
          if (resp.statusCode == 200) {
            final sink = outFile.openWrite();
            await resp.pipe(sink);
            await sink.flush();
            await sink.close();
          } else {
            // ignore: avoid_print
            print('Failed to download $fileName: HTTP ${resp.statusCode}');
          }
        } catch (e) {
          // ignore: avoid_print
          print('Error downloading $fileName: $e');
        }

        completed++;
        onProgress(completed, totalFiles, '');
      }
    }

    final List<Future<void>> workers = [];
    for (int i = 0; i < concurrency; i++) {
      workers.add(worker());
    }

    await Future.wait(workers);
    downloadClient.close(force: true);
  }
}
