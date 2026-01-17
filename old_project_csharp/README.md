# Drvx Partition Scanner

**Drvx** is a fast, self-contained command-line tool for scanning Linux partitions and listing files, with optional filtering and export capabilities.

---

## ✨ Features

- 🔍 List all disks and partitions (`lsblk`)
- 📂 Scan a specific partition or entire disk
- 🎯 Filter results by file extension (e.g. `.txt`, `.mp3`, `.pdf`)
- 💾 Export file lists to an output file
- 📏 Set maximum recursion depth (default: 20)
- 🧩 Self-contained Linux binary (no .NET install required)
- 🛠️ Works in live or recovery environments

---

## 🧪 Usage

```bash
drvx [OPTIONS]
```

| Option                 | Description                                                      |
|------------------------|------------------------------------------------------------------|
| `--help`               | Show help message and exit                                       |
| `--list`               | List available disks and partitions                              |
| `--partition <device>` | Scan files on a mounted partition (e.g. `/dev/sda1`)             |
| `--disk <device>`      | Scan files on all mounted partitions of a disk (e.g. `/dev/sda`) |
| `--filter <.ext>`      | Only include files with given extension (e.g. `.mp4`, `.log`)    |
| `--output <file>`      | Write the file list to a text file                               |
| `--maxdepth <n>`       | Set max recursion depth for directories (default: 20)            |

---

## 📚 Examples

```bash
# List disks and partitions
drvx --list

# Scan all files on a mounted partition
drvx --partition /dev/sda1

# Scan all mounted partitions on a disk for .txt files
drvx --disk /dev/sda --filter .txt

# Output the result to a text file
drvx --partition /dev/sda1 --output files.txt

# Limit directory scan depth to 5
drvx --disk /dev/sdb --maxdepth 5
```

---

## 📋 Requirements

- 🐧 Linux system
- `lsblk` available in `PATH`
- .NET SDK 9.0+ (only required to build from source)

---

## 🏗 Building from Source

1. Install .NET 9 SDK.
2. Clone this repository.
3. Run:

    ```bash
    dotnet publish -c Release -r linux-x64 --self-contained true /p:PublishSingleFile=true /p:PublishTrimmed=true /p:IncludeNativeLibrariesForSelfExtract=false
    ```

4. The binary will be in:

    ```
    bin/Release/net9.0/linux-x64/publish/drvx
    ```

---

## 📦 Download Binary

Download the latest precompiled binary from the [Releases](https://github.com/Shapis/drvx/releases) page.

---

## 💿 Flashable ISO (Debian/Ubuntu)

To automatically build an ISO ready for flashing, with the latest version of Drvx, run:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Shapis/drvx/main/installation_script.sh)
```
