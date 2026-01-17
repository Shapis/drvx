using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;

string mountsFile = "/proc/mounts";

// Parse args
var argsDict = args.Select((val, index) => new { val, index })
    .Where(x => x.val.StartsWith("--"))
    .ToDictionary(
        x => x.val,
        x =>
            x.index + 1 < args.Length && !args[x.index + 1].StartsWith("--")
                ? args[x.index + 1]
                : null
    );

// Mount info
IEnumerable<(string Device, string MountPoint, string FsType)> GetMountPoints()
{
    var excludeFsTypes = new HashSet<string>
    {
        "proc",
        "sysfs",
        "devtmpfs",
        "devpts",
        "tmpfs",
        "cgroup",
        "overlay",
        "squashfs",
        "fusectl",
        "securityfs",
        "pstore",
        "efivarfs",
        "debugfs",
        "tracefs",
        "configfs",
        "ramfs",
    };

    if (!File.Exists(mountsFile))
        yield break;

    foreach (var line in File.ReadLines(mountsFile))
    {
        var parts = line.Split(' ');
        if (parts.Length < 3)
            continue;

        var device = parts[0];
        var mountPoint = parts[1];
        var fsType = parts[2];

        if (excludeFsTypes.Contains(fsType))
            continue;

        yield return (device, mountPoint, fsType);
    }
}

string? FindMountPoint(string device)
{
    return GetMountPoints().FirstOrDefault(m => m.Device == device).MountPoint;
}

bool TryMountDevice(string device, out string mountPoint)
{
    string devName = Path.GetFileName(device);
    string targetDir = $"/mnt/drvx-{devName}";

    if (!Directory.Exists(targetDir))
        Directory.CreateDirectory(targetDir);

    var psi = new ProcessStartInfo
    {
        FileName = "sudo",
        ArgumentList = { "mount", device, targetDir },
        RedirectStandardError = true,
        UseShellExecute = false,
    };

    try
    {
        var proc = Process.Start(psi)!;
        proc.WaitForExit();

        if (proc.ExitCode == 0)
        {
            Console.WriteLine($"Mounted {device} to {targetDir}");
            mountPoint = targetDir;
            return true;
        }
        else
        {
            Console.WriteLine($"Failed to mount {device}: {proc.StandardError.ReadToEnd()}");
        }
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Error mounting {device}: {ex.Message}");
    }

    mountPoint = string.Empty;
    return false;
}

bool TryUnmount(string mountPoint)
{
    var psi = new ProcessStartInfo
    {
        FileName = "sudo",
        ArgumentList = { "umount", mountPoint },
        RedirectStandardError = true,
        UseShellExecute = false,
    };

    try
    {
        var proc = Process.Start(psi)!;
        proc.WaitForExit();
        return proc.ExitCode == 0;
    }
    catch
    {
        return false;
    }
}

// Safe recursive enumerator
IEnumerable<string> SafeEnumerateFiles(string root, string pattern, int maxDepth = 20)
{
    var dirs = new Stack<(string path, int depth)>();
    var visited = new HashSet<string>();
    dirs.Push((root, 0));

    while (dirs.Count > 0)
    {
        var (current, depth) = dirs.Pop();
        if (depth > maxDepth)
            continue;

        DirectoryInfo dirInfo;
        try
        {
            dirInfo = new DirectoryInfo(current);
            if (dirInfo.Attributes.HasFlag(FileAttributes.ReparsePoint))
                continue;
            var full = Path.GetFullPath(dirInfo.FullName);
            if (!visited.Add(full))
                continue;
        }
        catch
        {
            continue;
        }

        string[] files;
        try
        {
            files = Directory.GetFiles(current, pattern);
        }
        catch
        {
            continue;
        }

        foreach (var file in files)
            yield return file;

        string[] subDirs;
        try
        {
            subDirs = Directory.GetDirectories(current);
        }
        catch
        {
            continue;
        }

        foreach (var sub in subDirs)
            dirs.Push((sub, depth + 1));
    }
}

// Help
void ShowHelp()
{
    Console.WriteLine("Usage: drxv [OPTIONS]");
    Console.WriteLine();
    Console.WriteLine("Options:");
    Console.WriteLine("  --help                 Show this help message and exit");
    Console.WriteLine("  --list                 List available disks and partitions");
    Console.WriteLine(
        "  --partition <device|mount>  Device or mount point to scan (e.g. /dev/sda1 or /mnt/usb)"
    );
    Console.WriteLine(
        "  --filter <.ext>        Only include files with given extension (e.g. .txt)"
    );
    Console.WriteLine("  --output <file>        Write results to a text file");
    Console.WriteLine("  --maxdepth <n>         Maximum recursion depth (default: 20)");
    Console.WriteLine();
    Console.WriteLine("Examples:");
    Console.WriteLine("  drxv --list");
    Console.WriteLine("  drxv --partition /dev/sda1 --filter .txt");
}

if (args.Length == 0 || argsDict.ContainsKey("--help"))
{
    ShowHelp();
    return;
}

// --list
if (argsDict.ContainsKey("--list"))
{
    Console.WriteLine("Available disks and partitions:\n");
    var sysBlockPath = "/sys/block";
    if (!Directory.Exists(sysBlockPath))
    {
        Console.WriteLine("Error: /sys/block not found. Are you on Linux?");
        return;
    }

    foreach (var deviceDir in Directory.GetDirectories(sysBlockPath))
    {
        var deviceName = Path.GetFileName(deviceDir);
        var devicePath = $"/dev/{deviceName}";

        if (
            deviceName.StartsWith("loop")
            || deviceName.StartsWith("ram")
            || deviceName.StartsWith("zram")
        )
            continue;

        Console.WriteLine($"{devicePath}");

        var partDirs = Directory
            .GetDirectories(deviceDir)
            .Where(p => Path.GetFileName(p).StartsWith(deviceName));

        foreach (var part in partDirs)
        {
            var partName = Path.GetFileName(part);
            var partPath = $"/dev/{partName}";
            var sizeFile = Path.Combine(part, "size");
            string sizeText = File.Exists(sizeFile) ? File.ReadAllText(sizeFile).Trim() : "0";

            if (long.TryParse(sizeText, out long sectors))
            {
                double mbSize = sectors * 512 / 1024.0 / 1024.0;
                Console.WriteLine($"  └─ {partPath} ({mbSize:F1} MB)");
            }
        }

        Console.WriteLine();
    }

    return;
}

// --partition
if (!argsDict.TryGetValue("--partition", out var partition) || string.IsNullOrWhiteSpace(partition))
{
    Console.WriteLine("Error: You must specify a partition or mount point with --partition");
    return;
}

string? realMount = null;
bool wasAutoMounted = false;

if (Directory.Exists(partition))
{
    realMount = partition;
}
else if (File.Exists(partition) && partition.StartsWith("/dev/"))
{
    realMount = FindMountPoint(partition);
    if (realMount == null)
    {
        Console.WriteLine($"'{partition}' is not mounted.");
        Console.Write("Would you like to attempt mounting it? [Y/n]: ");
        var confirm = Console.ReadLine()?.Trim().ToLowerInvariant();
        if (confirm == "" || confirm == "y" || confirm == "yes")
        {
            if (TryMountDevice(partition, out var mountedPath))
            {
                realMount = mountedPath;
                wasAutoMounted = true;
            }
            else
            {
                Console.WriteLine("Failed to mount the device.");
                return;
            }
        }
        else
        {
            return;
        }
    }
}
else
{
    Console.WriteLine($"Error: '{partition}' is not a valid mount point or device.");
    return;
}

if (realMount == null || !Directory.Exists(realMount))
{
    Console.WriteLine("Error: Unable to use the selected partition.");
    return;
}

// Optional arguments
string? filter =
    argsDict.TryGetValue("--filter", out var ext) && !string.IsNullOrEmpty(ext)
        ? ext.StartsWith('.')
            ? ext
            : "." + ext
        : null;

string? outputFile = argsDict.TryGetValue("--output", out var path) ? path : null;
int maxDepth = 20;
if (argsDict.TryGetValue("--maxdepth", out var depthStr) && int.TryParse(depthStr, out int parsed))
    maxDepth = parsed;

try
{
    var files = SafeEnumerateFiles(realMount, "*", maxDepth);
    if (filter != null)
        files = files.Where(f =>
            Path.GetExtension(f).Equals(filter, StringComparison.OrdinalIgnoreCase)
        );

    var fileList = files.ToList();

    if (outputFile != null)
    {
        File.WriteAllLines(outputFile, fileList);
        Console.WriteLine($"Saved to {outputFile}");
    }
    else
    {
        foreach (var file in fileList)
            Console.WriteLine(file);
    }

    Console.WriteLine($"\nTotal scanned files: {fileList.Count}");
}
finally
{
    if (wasAutoMounted && realMount != null)
    {
        Console.WriteLine($"\nUnmounting {realMount}...");
        if (TryUnmount(realMount))
            Console.WriteLine("Unmounted successfully.");
        else
            Console.WriteLine("Warning: Failed to unmount.");
    }
}
