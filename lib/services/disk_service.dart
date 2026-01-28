import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:crypto/crypto.dart';

class DiskInfo {
  final String name;
  final String size;
  final String model;
  final String mountpoint;
  final String type;
  final String tran;
  final bool isPartition;
  final String? parentDisk;

  DiskInfo({
    required this.name,
    required this.size,
    required this.model,
    required this.mountpoint,
    required this.type,
    required this.tran,
    this.isPartition = false,
    this.parentDisk,
  });
}

class ThreatMatch {
  final String path;
  final String hash;

  ThreatMatch({required this.path, required this.hash});
}

class ScanResult {
  final int totalFiles;
  final int scannedFiles;
  final List<ThreatMatch> threats;

  ScanResult({
    required this.totalFiles,
    required this.scannedFiles,
    required this.threats,
  });
}

class DiskService {
  DiskService._();

  /// Recursively lists all files in a directory, skipping inaccessible directories
  static Stream<File> _listFilesRecursively(Directory dir) async* {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File) {
          yield entity;
        } else if (entity is Directory) {
          // Recursively list files in subdirectories
          yield* _listFilesRecursively(entity);
        }
      }
    } catch (e) {
      // Silently skip directories we can't read
      // ignore: avoid_print
      // print('Warning: Could not read directory ${dir.path}: $e');
    }
  }

  /// Returns a list of disks and their partitions (Linux via `lsblk -J`).
  static Future<List<DiskInfo>> listDisks() async {
    if (!Platform.isLinux) return [];

    try {
      final result = await Process.run('lsblk', [
        '-J',
        '-o',
        'NAME,SIZE,MODEL,MOUNTPOINT,TYPE,TRAN,FSTYPE',
      ]);
      if (result.exitCode != 0) return [];
      final Map<String, dynamic> json = jsonDecode(result.stdout as String);
      final List<dynamic> blockdevices = json['blockdevices'] as List<dynamic>;
      final List<DiskInfo> items = [];

      for (final dev in blockdevices) {
        final type = dev['type'] as String? ?? '';
        // Only process disk devices
        if (type != 'disk') continue;

        final name = dev['name'] as String? ?? '';
        final size = dev['size'] as String? ?? '';
        final model = dev['model'] as String? ?? '';
        final tran = dev['tran'] as String? ?? '';
        final mountpoint = (dev['mountpoint'] as String?) ?? '';

        // Add the disk itself
        items.add(
          DiskInfo(
            name: name,
            size: size,
            model: model,
            mountpoint: mountpoint,
            type: type,
            tran: tran,
            isPartition: false,
          ),
        );

        // Add all partitions under this disk
        final children = dev['children'] as List<dynamic>? ?? [];
        for (final child in children) {
          final childType = child['type'] as String? ?? '';
          final fstype = (child['fstype'] as String? ?? '').toLowerCase();

          // Skip swap partitions
          if (childType == 'part' && fstype != 'swap') {
            final partName = child['name'] as String? ?? '';
            final partSize = child['size'] as String? ?? '';
            final partMount = (child['mountpoint'] as String?) ?? '';

            items.add(
              DiskInfo(
                name: partName,
                size: partSize,
                model: '', // partitions don't have model
                mountpoint: partMount,
                type: childType,
                tran: '', // partitions don't have tran
                isPartition: true,
                parentDisk: name,
              ),
            );
          }
        }
      }
      return items;
    } catch (e) {
      // ignore: avoid_print
      print('DiskService.listDisks error: $e');
      return [];
    }
  }

  /// Scans every file under the disk's mountpoint, computing MD5 for each file.
  ///
  /// Calls [onProgress] with (processed, total, currentPath, status, threats). If the
  /// disk is not mounted (empty `mountpoint`) this will throw.
  ///
  /// If [threatHashes] is provided, compares each file's hash against the set
  /// and returns a [ScanResult] with any matches found.
  static Future<ScanResult> scanDisk({
    required DiskInfo disk,
    required void Function(
      int processed,
      int total,
      String currentPath,
      String status,
      List<ThreatMatch> threats,
    )
    onProgress,
    Set<String>? threatHashes,
    bool Function()? shouldCancel,
  }) async {
    final mount = disk.mountpoint;
    if (mount.isEmpty) throw Exception('Disk is not mounted: ${disk.name}');

    final root = Directory(mount);
    if (!await root.exists()) {
      throw Exception('Mount path does not exist: $mount');
    }

    final List<ThreatMatch> threats = [];

    // First pass: count files to provide a total
    int total = 0;
    final List<File> allFiles = [];
    try {
      await for (final file in _listFilesRecursively(root)) {
        if (shouldCancel?.call() ?? false) {
          onProgress(total, total, '', 'Cancelled', []);
          return ScanResult(totalFiles: total, scannedFiles: 0, threats: []);
        }
        allFiles.add(file);
        total++;
        // Report progress during counting phase every 100 files
        if (total % 100 == 0) {
          onProgress(0, total, file.path, 'Counting files...', []);
        }
      }
    } catch (e) {
      // If counting fails, start with what we have and continue
      onProgress(0, total, '', 'Counting interrupted, starting scan...', []);
    }

    // Use a synchronized counter for thread-safe updates
    var processed = 0;

    // Process files with concurrency limit of 8
    const concurrency = 8;
    int activeWorkers = 0;
    final completer = Completer<void>();
    int fileIndex = 0;

    Future<void> processFile(File file) async {
      if (shouldCancel?.call() ?? false) {
        return;
      }

      final path = file.path;

      try {
        // compute md5 digest via stream binding to avoid reading whole file into memory
        final digest = await md5.bind(file.openRead()).first;
        final md5Hex = digest.toString();

        // Check if this hash matches a threat
        if (threatHashes != null &&
            threatHashes.contains(md5Hex.toLowerCase())) {
          // Thread-safe add to threats list
          threats.add(ThreatMatch(path: path, hash: md5Hex));

          onProgress(
            processed,
            total,
            path,
            '⚠️ THREAT FOUND (${md5Hex.substring(0, 8)})',
            List.from(threats),
          );
        } else {
          // report digest in status (short form)
          onProgress(
            processed,
            total,
            path,
            'Read (${md5Hex.substring(0, 8)})',
            List.from(threats),
          );
        }
      } catch (e) {
        // ignore errors but report
        onProgress(
          processed,
          total,
          path,
          'Error reading: ${e.toString().split('\n').first}',
          List.from(threats),
        );
      }

      // Increment counter
      processed++;
      onProgress(processed, total, path, 'Scanning', List.from(threats));
    }

    void scheduleNext() {
      while (activeWorkers < concurrency && fileIndex < allFiles.length) {
        if (shouldCancel?.call() ?? false) {
          if (activeWorkers == 0) {
            completer.complete();
          }
          return;
        }

        final file = allFiles[fileIndex++];
        activeWorkers++;

        processFile(file).whenComplete(() {
          activeWorkers--;
          if (fileIndex < allFiles.length) {
            scheduleNext();
          } else if (activeWorkers == 0) {
            completer.complete();
          }
        });
      }

      if (fileIndex >= allFiles.length && activeWorkers == 0) {
        completer.complete();
      }
    }

    // Start initial workers
    scheduleNext();

    // Wait for all files to be processed
    await completer.future;

    return ScanResult(
      totalFiles: total,
      scannedFiles: processed,
      threats: threats,
    );
  }
}
