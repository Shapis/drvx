using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

string mountsFile = "/proc/mounts";

// Parse command line arguments
var argsDict = args.Select((val, index) => new { val, index })
    .Where(x => x.val.StartsWith("--"))
    .ToDictionary(
        x => x.val,
        x =>
            x.index + 1 < args.Length && !args[x.index + 1].StartsWith("--")
                ? args[x.index + 1]
                : null
    );

void ShowHelp()
{
    Console.WriteLine("Usage: drxv [OPTIONS]");
    Console.WriteLine();
    Console.WriteLine("Options:");
    Console.WriteLine("  --help                 Show this help message and exit");
    Console.WriteLine(
        "  --list                 List available mount points (excluding system mounts)"
    );
    Console.WriteLine("  --partition <path>     Specify mount point to scan (e.g. /mnt/mydrive)");
    Console.WriteLine(
        "  --filter <.ext>        Only include files with given extension (e.g. .txt)"
    );
    Console.WriteLine("  --output <file>        Write results to a text file");
    Console.WriteLine("  --maxdepth <n>         Maximum directory recursion depth (default: 20)");
    Console.WriteLine();
    Console.WriteLine("Examples:");
    Console.WriteLine("  drxv --list");
    Console.WriteLine("  drxv --partition /mnt/usb --filter .txt --output files.txt");
    Console.WriteLine();
}

// Show help if --help is passed or no arguments
if (args.Length == 0 || argsDict.ContainsKey("--help"))
{
    ShowHelp();
    return;
}

// Mount listing
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

// Safe recursive enumerator with depth, symlink, and snapshot skipping
IEnumerable<string> SafeEnumerateFiles(string root, string searchPattern, int maxDepth = 20)
{
    var dirs = new Stack<(string path, int depth)>();
    var visited = new HashSet<string>();
    dirs.Push((root, 0));

    while (dirs.Count > 0)
    {
        var (currentDir, depth) = dirs.Pop();

        if (depth > maxDepth)
            continue;

        // if (Path.GetFileName(currentDir).Equals(".snapshots", StringComparison.OrdinalIgnoreCase))
        //     continue;

        DirectoryInfo dirInfo;
        try
        {
            dirInfo = new DirectoryInfo(currentDir);
            if (dirInfo.Attributes.HasFlag(FileAttributes.ReparsePoint))
                continue;

            string canonicalPath = Path.GetFullPath(dirInfo.FullName);
            if (visited.Contains(canonicalPath))
                continue;
            visited.Add(canonicalPath);
        }
        catch
        {
            continue;
        }

        string[] files = Array.Empty<string>();
        try
        {
            files = Directory.GetFiles(currentDir, searchPattern);
        }
        catch
        {
            continue;
        }

        foreach (var file in files)
            yield return file;

        string[] subDirs = Array.Empty<string>();
        try
        {
            subDirs = Directory.GetDirectories(currentDir);
        }
        catch
        {
            continue;
        }

        foreach (var subDir in subDirs)
            dirs.Push((subDir, depth + 1));
    }
}

// Handle --list
if (argsDict.ContainsKey("--list"))
{
    Console.WriteLine("Available mount points (partitions):");
    foreach (var (device, mountPoint, fsType) in GetMountPoints())
    {
        Console.WriteLine($"{mountPoint} ({device}) - {fsType}");
    }
    return;
}

// Require --partition
if (!argsDict.TryGetValue("--partition", out var partition) || string.IsNullOrEmpty(partition))
{
    Console.WriteLine("Error: You must specify a partition mount point using --partition");
    return;
}

if (!Directory.Exists(partition))
{
    Console.WriteLine($"Error: Mount point directory '{partition}' does not exist.");
    return;
}

// Optional: --filter
string? filter =
    argsDict.TryGetValue("--filter", out var ext) && !string.IsNullOrEmpty(ext)
        ? ext.StartsWith('.')
            ? ext
            : "." + ext
        : null;

// Optional: --output
string? outputFile = argsDict.TryGetValue("--output", out var outputPath) ? outputPath : null;

// Optional: --maxdepth
int maxDepth = 20;
if (
    argsDict.TryGetValue("--maxdepth", out var depthStr)
    && int.TryParse(depthStr, out int parsedDepth)
)
    maxDepth = parsedDepth;

try
{
    var files = SafeEnumerateFiles(partition, "*", maxDepth);
    if (filter != null)
        files = files.Where(f =>
            Path.GetExtension(f).Equals(filter, StringComparison.OrdinalIgnoreCase)
        );

    var fileList = files.ToList();

    if (outputFile != null)
    {
        File.WriteAllLines(outputFile, fileList);
        Console.WriteLine($"File list saved to {outputFile}");
    }
    else
    {
        foreach (var file in fileList)
            Console.WriteLine(file);
    }

    Console.WriteLine($"\nTotal scanned files: {fileList.Count}");
}
catch (UnauthorizedAccessException)
{
    Console.WriteLine(
        $"Access denied to {partition} or subfolders. Try running with elevated privileges (e.g., sudo)."
    );
}
catch (Exception e)
{
    Console.WriteLine($"Error: {e.Message}");
}
