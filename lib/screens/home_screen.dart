import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:drvx/services/disk_service.dart';

class HomeScreen extends StatefulWidget {
  final Set<String> threatHashes;

  const HomeScreen({super.key, required this.threatHashes});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<DiskInfo> _disks = [];
  DiskInfo? _selected;
  bool _loading = true;
  bool _scanning = false;
  int _scanTotal = 0;
  int _scanProcessed = 0;
  String _scanCurrent = '';
  String _scanStatus = '';
  List<ThreatMatch> _threats = [];

  // Store scan results per partition so they persist when re-selecting
  final Map<String, ScanResult> _scanResults = {};

  @override
  void initState() {
    super.initState();
    _refreshDisks();
  }

  Future<void> _refreshDisks() async {
    setState(() {
      _loading = true;
    });
    final disks = await DiskService.listDisks();
    setState(() {
      _disks = disks;
      _selected = disks.isNotEmpty ? disks.first : null;
      _loading = false;
    });
  }

  void _onDiskSelected(DiskInfo disk) {
    // Don't allow selection changes during an active scan
    if (_scanning) {
      return;
    }

    setState(() {
      _selected = disk;
      // Reset scanning state when selecting a different disk
      _scanTotal = 0;
      _scanProcessed = 0;
      _scanCurrent = '';
      _scanStatus = '';
      _threats = [];
    });
  }

  bool _shouldCancelScan = false;

  Future<void> _onScan() async {
    if (_selected == null) return;
    if (_selected!.mountpoint.isEmpty) {
      // Show dialog with instructions instead of failing silently
      final devPath = '/dev/${_selected!.name}';
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Disk not mounted'),
          content: Text(
            'The selected disk is not mounted. To scan files you must mount it first.\n\n'
            'Example (mount read-only from a terminal):\n'
            'sudo mount -o ro $devPath /mnt/your_mount_point\n\n'
            'Or use udisksctl (desktop-friendly):\n'
            'udisksctl mount -b $devPath --options ro\n\n'
            'After mounting, refresh the disk list and try scanning again.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _attemptMount(devPath);
              },
              child: const Text('Attempt mount'),
            ),
          ],
        ),
      );
      return;
    }

    setState(() {
      _scanning = true;
      _scanTotal = 0;
      _scanProcessed = 0;
      _scanCurrent = '';
      _scanStatus =
          'Starting scan (${widget.threatHashes.length} threat hashes loaded)...';
      _threats = [];
      _shouldCancelScan = false;
    });

    try {
      final result = await DiskService.scanDisk(
        disk: _selected!,
        threatHashes: widget.threatHashes,
        shouldCancel: () => _shouldCancelScan,
        onProgress: (p, t, path, status, threats) {
          if (_shouldCancelScan) return;
          setState(() {
            _scanProcessed = p;
            _scanTotal = t;
            _scanCurrent = path;
            _scanStatus = status;
            _threats = threats;
          });
        },
      );

      if (!_shouldCancelScan) {
        // Store the scan result for this partition
        _scanResults[_selected!.name] = result;

        setState(() {
          _scanStatus = 'Completed';
          _threats = result.threats;
        });
      } else {
        setState(() {
          _scanStatus = 'Cancelled';
        });
      }
    } catch (e) {
      if (!_shouldCancelScan) {
        setState(() {
          _scanStatus = 'Error: ${e.toString()}';
        });
      }
    } finally {
      setState(() {
        _scanning = false;
      });
    }
  }

  void _cancelScan() {
    setState(() {
      _shouldCancelScan = true;
      _scanning = false;
    });
  }

  Future<void> _attemptMount(String devPath) async {
    // show progress dialog
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        content: Row(
          children: const [
            SizedBox(width: 24, height: 24, child: CircularProgressIndicator()),
            SizedBox(width: 12),
            Expanded(child: Text('Attempting to mount read-only...')),
          ],
        ),
      ),
    );

    try {
      // Check if this is a disk device (like sda) - if so, try partitions first
      // Block devices ending in a letter (no number) are typically disks, not partitions
      final isRawDisk = !RegExp(r'\d$').hasMatch(devPath);

      if (isRawDisk) {
        // Try to mount first available partition instead
        Navigator.of(context).pop(); // close progress
        final tried = await _tryMountFirstPartition(devPath);
        if (tried) {
          return; // Successfully mounted a partition
        }
        // If no partition worked, show error
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Mount failed'),
            content: Text(
              '$devPath is a disk device, not a mountable partition.\n\n'
              'Attempted to mount partitions but none were found or all failed.\n\n'
              'To mount manually:\n'
              '1. List partitions: lsblk $devPath\n'
              '2. Mount a partition: udisksctl mount -b ${devPath}1\n\n'
              'Or refresh the disk list after mounting externally.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }

      // Try to mount the partition directly
      var result = await Process.run('udisksctl', [
        'mount',
        '-b',
        devPath,
        '--options',
        'ro',
      ]);

      var out = result.stdout?.toString() ?? '';
      var err = result.stderr?.toString() ?? '';

      // If --options flag failed, try without it
      if (result.exitCode != 0 && err.contains('option')) {
        result = await Process.run('udisksctl', ['mount', '-b', devPath]);
        out = result.stdout?.toString() ?? '';
        err = result.stderr?.toString() ?? '';
      }

      Navigator.of(context).pop(); // close progress

      if (result.exitCode == 0) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Mounted'),
            content: Text('Mounted successfully.\n$out'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        await _refreshDisks();
        return;
      }

      // Provide helpful error message
      final errorMsg = StringBuffer();
      errorMsg.writeln('Failed to mount $devPath');
      errorMsg.writeln();
      errorMsg.writeln('Error: $err');
      if (err.contains('Not authorized') || err.contains('polkit')) {
        errorMsg.writeln();
        errorMsg.writeln('You may need to:');
        errorMsg.writeln('1. Run the app with sudo (not recommended)');
        errorMsg.writeln('2. Add your user to the disk or storage group');
        errorMsg.writeln('3. Use the command line to mount manually:');
        errorMsg.writeln('   sudo mount -o ro $devPath /mnt');
      } else if (err.contains('already mounted')) {
        errorMsg.writeln();
        errorMsg.writeln('The disk may already be mounted.');
        errorMsg.writeln('Try refreshing the disk list.');
      } else if (err.contains('not mountable')) {
        errorMsg.writeln();
        errorMsg.writeln('This device cannot be mounted. It may be:');
        errorMsg.writeln(
          '- A disk without partitions (use fdisk/parted to create one)',
        );
        errorMsg.writeln('- An unformatted partition (needs a filesystem)');
        errorMsg.writeln('- A damaged or unsupported filesystem');
      }

      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Mount failed'),
          content: SingleChildScrollView(child: Text(errorMsg.toString())),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      Navigator.of(context).pop();
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Mount error'),
          content: Text('Failed to run mount command: ${e.toString()}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<bool> _tryMountFirstPartition(String devPath) async {
    try {
      final ls = await Process.run('lsblk', ['-J', '-o', 'NAME,TYPE', devPath]);
      if (ls.exitCode != 0) return false;
      final Map<String, dynamic> json = jsonDecode(ls.stdout as String);
      final List<dynamic> blockdevices =
          json['blockdevices'] as List<dynamic>? ?? [];
      if (blockdevices.isEmpty) return false;
      final dev = blockdevices.first as Map<String, dynamic>;
      final children = dev['children'] as List<dynamic>? ?? [];
      for (final c in children) {
        final Map<String, dynamic> mp = c as Map<String, dynamic>;
        final type = mp['type'] as String? ?? '';
        final name = mp['name'] as String? ?? '';
        if (type == 'part' && name.isNotEmpty) {
          final partPath = '/dev/$name';
          // show progress dialog
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              content: Row(
                children: const [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text('Attempting to mount partition read-only...'),
                  ),
                ],
              ),
            ),
          );

          var res = await Process.run('udisksctl', [
            'mount',
            '-b',
            partPath,
            '--options',
            'ro',
          ]);

          var out = res.stdout?.toString() ?? '';
          var err = res.stderr?.toString() ?? '';

          // Try without --options if it failed
          if (res.exitCode != 0 && err.contains('option')) {
            res = await Process.run('udisksctl', ['mount', '-b', partPath]);
            out = res.stdout?.toString() ?? '';
          }

          Navigator.of(context).pop();

          if (res.exitCode == 0) {
            await showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Mounted'),
                content: Text(
                  'Mounted partition $partPath successfully.\n$out',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
            await _refreshDisks();
            return true;
          }
        }
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanResultsView(ScanResult result) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Device info card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          _selected!.isPartition
                              ? Icons.source_rounded
                              : Icons.storage_rounded,
                          size: 28,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _selected!.name,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _selected!.isPartition
                                  ? 'Partition (${_selected!.size})'
                                  : 'Disk',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (!_selected!.isPartition) ...[
                    _buildInfoRow('Model', _selected!.model),
                    _buildInfoRow('Transport', _selected!.tran),
                  ] else ...[
                    _buildInfoRow('Parent Disk', _selected!.parentDisk ?? '—'),
                  ],
                  _buildInfoRow('Size', _selected!.size),
                  _buildInfoRow(
                    'Mount Point',
                    _selected!.mountpoint.isNotEmpty
                        ? _selected!.mountpoint
                        : 'Not mounted',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          // Scan results card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: result.threats.isEmpty
                              ? Colors.green.withOpacity(0.15)
                              : Colors.red.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          result.threats.isEmpty
                              ? Icons.check_circle_rounded
                              : Icons.warning_rounded,
                          size: 24,
                          color: result.threats.isEmpty
                              ? Colors.green
                              : Colors.red,
                        ),
                      ),
                      const SizedBox(width: 16),
                      const Text(
                        'Scan Results',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              Text(
                                result.scannedFiles.toString(),
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Files Scanned',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: result.threats.isEmpty
                                ? Colors.green.withOpacity(0.1)
                                : Colors.red.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: result.threats.isEmpty
                                  ? Colors.green.withOpacity(0.3)
                                  : Colors.red.withOpacity(0.3),
                              width: 2,
                            ),
                          ),
                          child: Column(
                            children: [
                              Text(
                                result.threats.length.toString(),
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                  color: result.threats.isEmpty
                                      ? Colors.green
                                      : Colors.red,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Threats Found',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (result.threats.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    Text(
                      'Detected Threats',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...result.threats.map(
                      (threat) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: Colors.red.withOpacity(0.3),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.dangerous_rounded,
                              color: Colors.red,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                threat.path,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 20),
                    Center(
                      child: Column(
                        children: [
                          Icon(
                            Icons.shield_rounded,
                            size: 48,
                            color: Colors.green.withOpacity(0.7),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'No threats detected',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.green.shade600,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Your system is secure',
                            style: TextStyle(
                              fontSize: 13,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        setState(() {
                          _scanResults.remove(_selected!.name);
                        });
                        _onScan();
                      },
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Scan Again'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: Row(
        children: [
          // Left pane: disk list
          Flexible(
            flex: 1,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                    Theme.of(context).colorScheme.surface,
                  ],
                ),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(24.0),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surface.withOpacity(0.3),
                      border: Border(
                        bottom: BorderSide(
                          color: Theme.of(
                            context,
                          ).colorScheme.primary.withOpacity(0.2),
                          width: 1,
                        ),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.storage,
                              color: Theme.of(context).colorScheme.onSurface,
                              size: 20,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'Devices',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.refresh,
                            color: Theme.of(context).colorScheme.onSurface,
                            size: 20,
                          ),
                          onPressed: _refreshDisks,
                          tooltip: 'Refresh',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _loading
                        ? Center(
                            child: CircularProgressIndicator(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: _disks.length,
                            itemBuilder: (context, index) {
                              final d = _disks[index];
                              final selected = d == _selected;

                              return Padding(
                                padding: EdgeInsets.only(
                                  left: d.isPartition ? 24.0 : 0,
                                  bottom: 8.0,
                                ),
                                child: Material(
                                  color: Colors.transparent,
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () => _onDiskSelected(d),
                                    child: Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(12),
                                        color: selected
                                            ? Theme.of(context)
                                                  .colorScheme
                                                  .primary
                                                  .withOpacity(0.15)
                                            : Colors.transparent,
                                        border: Border.all(
                                          color: selected
                                              ? Theme.of(
                                                  context,
                                                ).colorScheme.primary
                                              : Colors.transparent,
                                          width: 2,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(10),
                                            decoration: BoxDecoration(
                                              color: selected
                                                  ? Theme.of(
                                                      context,
                                                    ).colorScheme.primary
                                                  : Theme.of(context)
                                                        .colorScheme
                                                        .surfaceContainerHighest,
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                            child: Icon(
                                              d.isPartition
                                                  ? Icons.source_rounded
                                                  : Icons.storage_rounded,
                                              size: d.isPartition ? 18 : 24,
                                              color: selected
                                                  ? Colors.white
                                                  : Theme.of(
                                                      context,
                                                    ).colorScheme.primary,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  d.name,
                                                  style: TextStyle(
                                                    fontWeight: selected
                                                        ? FontWeight.bold
                                                        : (d.isPartition
                                                              ? FontWeight
                                                                    .normal
                                                              : FontWeight
                                                                    .w600),
                                                    fontSize: d.isPartition
                                                        ? 14
                                                        : 15,
                                                  ),
                                                ),
                                                const SizedBox(height: 4),
                                                Text(
                                                  d.isPartition
                                                      ? d.size
                                                      : '${d.model} • ${d.size}',
                                                  style: TextStyle(
                                                    fontSize: 12,
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .onSurfaceVariant,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                                if (d
                                                    .mountpoint
                                                    .isNotEmpty) ...[
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    d.mountpoint,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: Theme.of(context)
                                                          .colorScheme
                                                          .primary
                                                          .withOpacity(0.7),
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          if (d.mountpoint.isNotEmpty)
                                            Container(
                                              padding: const EdgeInsets.all(6),
                                              decoration: BoxDecoration(
                                                color: Colors.green.withOpacity(
                                                  0.15,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: const Icon(
                                                Icons.check_circle_rounded,
                                                color: Colors.green,
                                                size: 18,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),

          // Right pane: details and scan button
          Flexible(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.all(32.0),
              child: _selected == null
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.devices_rounded,
                            size: 64,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant.withOpacity(0.3),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No device selected',
                            style: TextStyle(
                              fontSize: 18,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    )
                  : _scanning
                  ? SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Scanning status card
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(24.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          _selected!.isPartition
                                              ? Icons.source_rounded
                                              : Icons.storage_rounded,
                                          size: 28,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _selected!.name,
                                              style: const TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              _selected!.isPartition
                                                  ? 'Partition (${_selected!.size})'
                                                  : 'Disk',
                                              style: TextStyle(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 20),
                                  if (!_selected!.isPartition) ...[
                                    _buildInfoRow('Model', _selected!.model),
                                    _buildInfoRow('Transport', _selected!.tran),
                                  ] else ...[
                                    _buildInfoRow(
                                      'Parent Disk',
                                      _selected!.parentDisk ?? '—',
                                    ),
                                  ],
                                  _buildInfoRow('Size', _selected!.size),
                                  _buildInfoRow(
                                    'Mount Point',
                                    _selected!.mountpoint.isNotEmpty
                                        ? _selected!.mountpoint
                                        : 'Not mounted',
                                  ),
                                  _buildInfoRow('Type', _selected!.type),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          // Scanning progress card
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(24.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 3,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      const Text(
                                        'Scanning in progress...',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 20),
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Column(
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              'Progress',
                                              style: TextStyle(
                                                fontSize: 13,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                              ),
                                            ),
                                            Text(
                                              '$_scanProcessed / ${_scanTotal > 0 ? _scanTotal : '?'} files',
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                          child: LinearProgressIndicator(
                                            value: _scanTotal > 0
                                                ? (_scanProcessed / _scanTotal)
                                                : null,
                                            minHeight: 8,
                                            backgroundColor: Theme.of(
                                              context,
                                            ).colorScheme.surface,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Container(
                                          padding: const EdgeInsets.all(16),
                                          decoration: BoxDecoration(
                                            color: _threats.isEmpty
                                                ? Colors.green.withOpacity(0.1)
                                                : Colors.red.withOpacity(0.1),
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            border: Border.all(
                                              color: _threats.isEmpty
                                                  ? Colors.green.withOpacity(
                                                      0.3,
                                                    )
                                                  : Colors.red.withOpacity(0.3),
                                              width: 2,
                                            ),
                                          ),
                                          child: Column(
                                            children: [
                                              Icon(
                                                _threats.isEmpty
                                                    ? Icons.shield_rounded
                                                    : Icons.warning_rounded,
                                                color: _threats.isEmpty
                                                    ? Colors.green
                                                    : Colors.red,
                                                size: 28,
                                              ),
                                              const SizedBox(height: 8),
                                              Text(
                                                _threats.length.toString(),
                                                style: TextStyle(
                                                  fontSize: 32,
                                                  fontWeight: FontWeight.bold,
                                                  color: _threats.isEmpty
                                                      ? Colors.green
                                                      : Colors.red,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                'Threats Found',
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerHighest
                                          .withOpacity(0.5),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.info_outline_rounded,
                                          size: 16,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            _scanStatus,
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (_scanCurrent.isNotEmpty) ...[
                                    const SizedBox(height: 12),
                                    Container(
                                      constraints: const BoxConstraints(
                                        maxHeight: 100,
                                      ),
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.surface,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .outline
                                              .withOpacity(0.2),
                                        ),
                                      ),
                                      child: SingleChildScrollView(
                                        child: Text(
                                          _scanCurrent,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontFamily: 'monospace',
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                  const SizedBox(height: 20),
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton.icon(
                                      onPressed: _cancelScan,
                                      icon: const Icon(Icons.stop_rounded),
                                      label: const Text('Stop Scan'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.red.shade600,
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : // Check if there are saved scan results for this partition
                    _scanResults.containsKey(_selected!.name)
                  ? _buildScanResultsView(_scanResults[_selected!.name]!)
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(24.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withOpacity(0.15),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Icon(
                                          _selected!.isPartition
                                              ? Icons.source_rounded
                                              : Icons.storage_rounded,
                                          size: 28,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                        ),
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _selected!.name,
                                              style: const TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              _selected!.isPartition
                                                  ? 'Partition (${_selected!.size})'
                                                  : 'Disk',
                                              style: TextStyle(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                                fontSize: 14,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 20),
                                  if (!_selected!.isPartition) ...[
                                    _buildInfoRow('Model', _selected!.model),
                                    _buildInfoRow('Transport', _selected!.tran),
                                  ] else ...[
                                    _buildInfoRow(
                                      'Parent Disk',
                                      _selected!.parentDisk ?? '—',
                                    ),
                                  ],
                                  _buildInfoRow('Size', _selected!.size),
                                  _buildInfoRow(
                                    'Mount Point',
                                    _selected!.mountpoint.isNotEmpty
                                        ? _selected!.mountpoint
                                        : 'Not mounted',
                                  ),
                                  _buildInfoRow('Type', _selected!.type),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          if (_selected!.isPartition) ...[
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(24.0),
                                child: Column(
                                  children: [
                                    Icon(
                                      Icons.security_rounded,
                                      size: 64,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary.withOpacity(0.5),
                                    ),
                                    const SizedBox(height: 16),
                                    const Text(
                                      'Ready to Scan',
                                      style: TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Click the button below to start scanning for threats',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                    const SizedBox(height: 24),
                                    SizedBox(
                                      width: double.infinity,
                                      child: ElevatedButton.icon(
                                        onPressed: _onScan,
                                        icon: const Icon(
                                          Icons.play_arrow_rounded,
                                        ),
                                        label: const Text('Start Scan'),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Theme.of(
                                            context,
                                          ).colorScheme.primary,
                                          foregroundColor: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ] else ...[
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(24.0),
                                child: Column(
                                  children: [
                                    Icon(
                                      Icons.info_outline_rounded,
                                      size: 64,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant
                                          .withOpacity(0.5),
                                    ),
                                    const SizedBox(height: 16),
                                    const Text(
                                      'Cannot Scan Disk',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      'Please select a partition from the list to perform a scan',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
