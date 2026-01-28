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
        onProgress: (p, t, path, status) {
          if (_shouldCancelScan) return;
          setState(() {
            _scanProcessed = p;
            _scanTotal = t;
            _scanCurrent = path;
            _scanStatus = status;
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
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildScanResultsView(ScanResult result) {
    return Column(
      children: [
        // Upper part: Disk/partition info
        Flexible(
          flex: 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _selected!.isPartition ? Icons.dashboard : Icons.storage,
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selected!.name,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          _selected!.isPartition
                              ? 'Partition (${_selected!.size})'
                              : 'Disk',
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
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
        const Divider(),
        // Lower part: Scan results
        Flexible(
          flex: 1,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    result.threats.isEmpty ? Icons.check_circle : Icons.warning,
                    size: 24,
                    color: result.threats.isEmpty ? Colors.green : Colors.red,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Scan Results',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildInfoRow('Files Scanned', result.scannedFiles.toString()),
              const SizedBox(height: 8),
              _buildInfoRow(
                'Threats Detected',
                result.threats.length.toString(),
              ),
              if (result.threats.isNotEmpty) ...[
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: result.threats.length,
                    itemBuilder: (context, index) {
                      final threat = result.threats[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 6.0),
                        child: Padding(
                          padding: const EdgeInsets.all(6.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                threat.path,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Hash: ${threat.hash}',
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ] else ...[
                const SizedBox(height: 8),
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.check_circle,
                        size: 32,
                        color: Colors.green,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'No threats detected',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.green.shade600,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
              ],
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: () {
                  // Remove cached results and start a new scan
                  setState(() {
                    _scanResults.remove(_selected!.name);
                  });
                  _onScan();
                },
                icon: const Icon(Icons.search),
                label: const Text('Scan Again'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // Left pane: disk list
          Flexible(
            flex: 1,
            child: Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Connected Disks',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh),
                          onPressed: _refreshDisks,
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : ListView.separated(
                            itemCount: _disks.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final d = _disks[index];
                              final selected = d == _selected;

                              // Visual distinction for partitions
                              return ListTile(
                                selected: selected,
                                dense: d.isPartition,
                                contentPadding: EdgeInsets.only(
                                  left: d.isPartition ? 32.0 : 16.0,
                                  right: 16.0,
                                  top: 4.0,
                                  bottom: 4.0,
                                ),
                                leading: d.isPartition
                                    ? const Icon(
                                        Icons.subdirectory_arrow_right,
                                        size: 16,
                                      )
                                    : const Icon(Icons.storage),
                                title: Text(
                                  d.name,
                                  style: TextStyle(
                                    fontWeight: d.isPartition
                                        ? FontWeight.normal
                                        : FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(
                                  d.isPartition
                                      ? '${d.size}${d.mountpoint.isNotEmpty ? ' • ${d.mountpoint}' : ''}'
                                      : '${d.model} • ${d.size}',
                                ),
                                trailing: d.mountpoint.isNotEmpty
                                    ? const Icon(
                                        Icons.check_circle,
                                        color: Colors.green,
                                      )
                                    : (d.isPartition
                                          ? const Icon(
                                              Icons.circle_outlined,
                                              size: 16,
                                            )
                                          : null),
                                onTap: () => _onDiskSelected(d),
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
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: _selected == null
                  ? const Center(child: Text('No disk selected'))
                  : _scanning
                  ? Column(
                      children: [
                        // Upper part: Disk/partition info
                        Flexible(
                          flex: 1,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    _selected!.isPartition
                                        ? Icons.dashboard
                                        : Icons.storage,
                                    size: 32,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _selected!.name,
                                          style: const TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        Text(
                                          _selected!.isPartition
                                              ? 'Partition (${_selected!.size})'
                                              : 'Disk',
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
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
                            ],
                          ),
                        ),
                        const Divider(),
                        // Lower part: Scan progress
                        Flexible(
                          flex: 1,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Status: $_scanStatus'),
                              const SizedBox(height: 8),
                              LinearProgressIndicator(
                                value: _scanTotal > 0
                                    ? (_scanProcessed / _scanTotal)
                                    : null,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Files: $_scanProcessed / ${_scanTotal > 0 ? _scanTotal : '?'}',
                              ),
                              if (_threats.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  '⚠️ Threats found: ${_threats.length}',
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 12),
                              Expanded(
                                child: SingleChildScrollView(
                                  child: Text(_scanCurrent),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  ElevatedButton.icon(
                                    onPressed: null,
                                    icon: const Icon(Icons.pause),
                                    label: const Text('Scanning...'),
                                  ),
                                  const SizedBox(width: 12),
                                  ElevatedButton.icon(
                                    onPressed: _cancelScan,
                                    icon: const Icon(Icons.stop),
                                    label: const Text('Cancel'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red.shade400,
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : // Check if there are saved scan results for this partition
                    _scanResults.containsKey(_selected!.name)
                  ? _buildScanResultsView(_scanResults[_selected!.name]!)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _selected!.isPartition
                                  ? Icons.dashboard
                                  : Icons.storage,
                              size: 32,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _selected!.name,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    _selected!.isPartition
                                        ? 'Partition (${_selected!.size})'
                                        : 'Disk',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
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
                        const Spacer(),
                        if (_selected!.isPartition) ...[
                          // Only partitions can be scanned
                          Row(
                            children: [
                              ElevatedButton.icon(
                                onPressed: _scanning ? null : _onScan,
                                icon: const Icon(Icons.search),
                                label: Text(_scanning ? 'Scanning...' : 'Scan'),
                              ),
                              const SizedBox(width: 12),
                              ElevatedButton.icon(
                                onPressed: _scanning
                                    ? _cancelScan
                                    : _refreshDisks,
                                icon: Icon(
                                  _scanning ? Icons.stop : Icons.refresh,
                                ),
                                label: Text(_scanning ? 'Cancel' : 'Refresh'),
                              ),
                            ],
                          ),
                        ] else ...[
                          // Disks cannot be scanned directly
                          Text(
                            'Select a partition to scan',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: _refreshDisks,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Refresh'),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
