# SMB Speed Test

A comprehensive disk and network storage performance testing tool using `fio` (Flexible I/O Tester). This script automatically detects and benchmarks multiple storage locations including local disks, SMB/CIFS network shares, and the current working directory.

## Features

- **Automated Discovery**: Automatically detects SMB/CIFS mounts and local disk mount points
- **Comprehensive Testing**: Tests multiple block sizes (4K, 128K, 1M) and access patterns (sequential/random, read/write)
- **Background Mode**: Run tests in the background with `nohup` to survive logout sessions
- **Lock Mechanism**: Prevents multiple concurrent test instances
- **Formatted Output**: Generates timestamped markdown reports with color-coded terminal output
- **Real-world Metrics**: Reports bandwidth, IOPS, and latency for each test

## Test Matrix

The script runs a comprehensive test suite covering:

| Block Size | Access Pattern | Operation |
|------------|----------------|-----------|
| 4K         | Sequential     | Read/Write |
| 4K         | Random         | Read/Write |
| 128K       | Sequential     | Read/Write |
| 128K       | Random         | Read/Write |
| 1M         | Sequential     | Read/Write |
| 1M         | Random         | Read/Write |

**Total**: 12 tests per storage location

## Prerequisites

### Required Software

- `fio` - Flexible I/O Tester
- `bash` - Bash shell (version 4.0+)
- Standard Unix utilities: `grep`, `awk`, `sed`, `mktemp`

### Installation

#### Ubuntu/Debian
```bash
sudo apt-get update
sudo apt-get install fio
```

#### RHEL/CentOS/Fedora
```bash
sudo yum install fio
# or
sudo dnf install fio
```

#### Arch Linux
```bash
sudo pacman -S fio
```

#### macOS
```bash
brew install fio
```

## Usage

### Basic Usage

Run tests interactively (output to terminal and markdown file):

```bash
./disk_speed_test.sh
```

### Background Mode

Run tests in the background (useful for long-running tests or remote sessions):

```bash
./disk_speed_test.sh --background
```

Or use the short form:

```bash
./disk_speed_test.sh -b
```

In background mode:
- Tests run even if you log out
- Output is saved to `nohup.out`
- Monitor progress: `tail -f nohup.out`
- Results are saved to a timestamped markdown file

### Help

Display usage information:

```bash
./disk_speed_test.sh --help
```

## Output

### Terminal Output

The script provides color-coded real-time feedback:
- **Yellow**: Section headers and test location information
- **Blue**: Currently running test name
- **Green**: Test results and completion messages
- **Red**: Errors and warnings

### Markdown Report

Results are automatically saved to a timestamped markdown file:
```
disk_speed_test_YYYYMMDD_HHMMSS.md
```

The report includes:
- Test configuration and timestamp
- Organized results by storage location
- Detailed metrics table for each location:
  - Bandwidth (MB/s, GB/s, etc.)
  - IOPS (Input/Output Operations Per Second)
  - Latency (microseconds/milliseconds)
- Test notes explaining metrics and block sizes

Example report structure:
```markdown
# Disk Speed Test Results

**Test Date:** Mon Nov 10 21:53:00 UTC 2025
**Test Configuration:**
- Test Size: 1G per test
- Runtime: 30 seconds per test
- I/O Engine: libaio
- Direct I/O: Enabled

## /home/user/test

**Description:** Current Directory

| Test | Bandwidth | IOPS | Latency |
|------|-----------|------|---------|
| Sequential Read (4K) | 150MiB/s | 38400 | 25.6us |
...
```

## Understanding the Results

### Metrics Explained

- **Bandwidth (BW)**: Amount of data transferred per second
  - Higher is better
  - Important for large file transfers and streaming operations

- **IOPS**: Input/Output Operations Per Second
  - Higher is better
  - Critical for database workloads and random access patterns

- **Latency**: Time taken to complete a single I/O operation
  - Lower is better
  - Affects application responsiveness

### Block Sizes

- **4K**: Typical for database operations, random access, small file operations
- **128K**: Balanced performance, medium file operations
- **1M**: Large file transfers, sequential streaming, video/backup operations

### Access Patterns

- **Sequential**: Data accessed in order (streaming, large file copies)
- **Random**: Data accessed randomly (databases, virtual machines, general application use)

## Test Configuration

The script uses the following `fio` configuration:

- **Test Size**: 1GB per test
- **Runtime**: 30 seconds per test
- **I/O Engine**: `libaio` (Linux asynchronous I/O)
- **Direct I/O**: Enabled (bypasses OS cache for accurate results)
- **Number of Jobs**: 1 (single-threaded)

You can modify these values by editing the `Configuration` section in the script:

```bash
TEST_SIZE="1G"      # Size of test file
RUNTIME=30          # Duration of each test in seconds
```

## Safety Features

### Lock File Protection

The script uses a lock file (`/tmp/disk_speed_test.lock`) to prevent multiple simultaneous instances, which could:
- Skew test results
- Consume excessive system resources
- Create filesystem conflicts

If the script detects a running instance, it will exit with an error. To override a stale lock:

```bash
rm /tmp/disk_speed_test.lock
```

### Cleanup on Exit

The script automatically cleans up:
- Temporary test files
- Test directories
- Lock files

Cleanup occurs even if the script is interrupted (Ctrl+C) or encounters an error.

## Troubleshooting

### Permission Denied Errors

If you see permission errors for a specific mount point:

```bash
Cannot create test directory in /mnt/share (permission denied?)
```

**Solution**: Ensure you have write permissions to the target directory:

```bash
# Check permissions
ls -ld /mnt/share

# If needed, create a test subdirectory with proper permissions
mkdir -p /mnt/share/speedtest
cd /mnt/share/speedtest
/path/to/disk_speed_test.sh
```

### No Mount Points Found

If the script reports "No mount points found to test":

**Possible causes**:
- No SMB shares are mounted
- No accessible local disk mounts
- Running from a special filesystem

**Solution**: Mount your SMB share or navigate to a directory on a testable filesystem.

### fio Not Found

If you see "ERROR: fio is not installed":

**Solution**: Install `fio` using your package manager (see Prerequisites section).

## Use Cases

### SMB/CIFS Network Share Testing

Perfect for benchmarking:
- Samba shares
- Windows file shares
- NAS devices
- Cloud storage mounts (SMB protocol)

### Local Storage Comparison

Compare performance across:
- SSD vs HDD
- NVMe vs SATA
- RAID arrays
- Different filesystems (ext4, xfs, btrfs)

### Remote Session Testing

Use background mode for:
- Long-running benchmarks
- SSH sessions that might disconnect
- Automated testing in CI/CD pipelines

## Examples

### Test a specific SMB mount

```bash
# Mount your share
sudo mount -t cifs //server/share /mnt/share -o username=user

# Run test
cd /mnt/share
/path/to/disk_speed_test.sh
```

### Compare multiple storage locations

```bash
# The script automatically tests all detected mount points
./disk_speed_test.sh

# Results will include:
# - Current directory
# - All SMB/CIFS mounts under /mnt
# - All local disk mounts
```

### Run overnight benchmark

```bash
# Start in background
./disk_speed_test.sh --background

# Check progress periodically
tail -f nohup.out

# View results next morning
cat disk_speed_test_*.md
```

## Performance Tips

### For accurate results:

1. **Close other applications** that might be using disk I/O
2. **Run tests multiple times** and average the results
3. **Test during off-peak hours** for network shares
4. **Ensure sufficient free space** (at least 2GB per mount point)
5. **Disable power saving** on storage devices if possible

### For SMB/CIFS testing specifically:

- Use appropriate mount options for your network:
  ```bash
  mount -t cifs //server/share /mnt/share -o username=user,vers=3.0,cache=none
  ```
- Consider network factors (latency, bandwidth, congestion)
- Test at different times of day to identify network patterns

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

### Areas for contribution:

- Support for additional storage types (NFS, iSCSI, etc.)
- Configurable test parameters via command-line flags
- JSON output format option
- Performance comparison graphs
- Historical result tracking

## License

This script is provided as-is for educational and testing purposes.

## Author

Generated for disk and network storage performance testing.

## Changelog

### Version 1.0
- Initial release
- Automatic mount point detection
- Support for SMB/CIFS and local disks
- Background mode support
- Markdown report generation
- Lock file protection
- Comprehensive test matrix (4K, 128K, 1M blocks)
