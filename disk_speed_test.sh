#!/bin/bash

# Comprehensive Disk Speed Test using fio
# Tests: Serial/Random, Read/Write, Small/Medium/Large block sizes

set -e

# Parse command-line arguments
BACKGROUND_MODE=false
for arg in "$@"; do
    case $arg in
        --background|-b)
            BACKGROUND_MODE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --background, -b    Run in background with nohup (allows logout)"
            echo "  --help, -h          Show this help message"
            echo ""
            echo "Background mode will:"
            echo "  - Run tests in the background"
            echo "  - Save output to nohup.out"
            echo "  - Allow you to log out while tests run"
            echo "  - Monitor progress with: tail -f nohup.out"
            exit 0
            ;;
        *)
            # Unknown option
            ;;
    esac
done

# If background mode requested and not already running in background
if [ "$BACKGROUND_MODE" = true ] && [ -z "$RUNNING_IN_BACKGROUND" ]; then
    echo "Starting disk speed test in background mode..."
    echo "Output will be saved to: nohup.out"
    echo "Monitor progress with: tail -f nohup.out"
    echo ""

    # Export marker to prevent infinite loop
    export RUNNING_IN_BACKGROUND=1

    # Restart script with nohup
    nohup "$0" "$@" </dev/null >/dev/null 2>&1 &

    echo "Background process started with PID: $!"
    echo "Results will be saved to a timestamped markdown file."
    exit 0
fi

# Lockfile mechanism to prevent multiple instances
LOCKFILE="/tmp/disk_speed_test.lock"

# Function to cleanup lockfile on exit
cleanup_lock() {
    rm -f "$LOCKFILE"
}

# Check if another instance is running
if [ -f "$LOCKFILE" ]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null)

    # Check if the PID in lockfile is still running
    if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "ERROR: Another instance of disk_speed_test is already running (PID: $LOCK_PID)"
        echo "If this is incorrect, remove the lockfile: rm $LOCKFILE"
        exit 1
    else
        # Stale lockfile - remove it
        echo "Removing stale lockfile from previous run..."
        rm -f "$LOCKFILE"
    fi
fi

# Create lockfile with current PID
echo $$ > "$LOCKFILE"

# Set trap to cleanup lockfile on exit (normal or error)
trap cleanup_lock EXIT INT TERM

# Configuration
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_MD="disk_speed_test_${TIMESTAMP}.md"
TEST_SIZE="1G"
RUNTIME=30
TEMP_DIR=$(mktemp -d)

# Color codes for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print and log
log_output() {
    echo -e "$1"
    echo -e "$1" | sed -r 's/\x1b\[[0-9;]*m//g' >> "$OUTPUT_MD"
}

# Function to run fio test
run_fio_test() {
    local test_name="$1"
    local rw_type="$2"
    local bs="$3"
    local test_dir="$4"
    local mount_name="$5"

    echo -e "${BLUE}Running: $test_name${NC}"

    local test_file="${test_dir}/fio_test_${RANDOM}.tmp"

    # Run fio and capture output
    local fio_output
    fio_output=$(fio --name="$test_name" \
        --filename="$test_file" \
        --rw="$rw_type" \
        --bs="$bs" \
        --size="$TEST_SIZE" \
        --runtime="$RUNTIME" \
        --time_based \
        --ioengine=libaio \
        --direct=1 \
        --numjobs=1 \
        --group_reporting \
        --output-format=normal 2>&1) || true

    # Parse results
    local bw iops lat
    bw=$(echo "$fio_output" | grep -E "bw=" | head -1 | sed -E 's/.*bw=([^,]+).*/\1/' | xargs)
    iops=$(echo "$fio_output" | grep -E "IOPS=" | head -1 | sed -E 's/.*IOPS=([^,]+).*/\1/' | xargs)
    lat=$(echo "$fio_output" | grep -E "lat.*avg=" | head -1 | sed -E 's/.*avg=\s*([^,]+).*/\1/' | xargs)

    # Display results
    echo -e "${GREEN}  Bandwidth: $bw | IOPS: $iops | Latency: $lat${NC}"
    echo "| $test_name | $bw | $iops | $lat |" >> "$OUTPUT_MD"

    # Cleanup
    rm -f "$test_file"
}

# Initialize markdown file
cat > "$OUTPUT_MD" << EOF
# Disk Speed Test Results

**Test Date:** $(date)
**Test Configuration:**
- Test Size: 1G per test
- Runtime: 30 seconds per test
- I/O Engine: libaio
- Direct I/O: Enabled

---

EOF

log_output "${YELLOW}═══════════════════════════════════════════════════════${NC}"
log_output "${YELLOW}         COMPREHENSIVE DISK SPEED TEST${NC}"
log_output "${YELLOW}═══════════════════════════════════════════════════════${NC}"
log_output ""

# Check if fio is installed
if ! command -v fio &> /dev/null; then
    log_output "${RED}ERROR: fio is not installed. Please install it first:${NC}"
    log_output "${RED}  Ubuntu/Debian: sudo apt-get install fio${NC}"
    log_output "${RED}  RHEL/CentOS: sudo yum install fio${NC}"
    exit 1
fi

# Detect mount points to test
MOUNT_POINTS=()
SEEN_MOUNTS=()

# Add current directory
CURRENT_DIR=$(pwd)
MOUNT_POINTS+=("${CURRENT_DIR}:Current Directory")
SEEN_MOUNTS+=("${CURRENT_DIR}")

# Find SMB/CIFS mounts in /mnt
if [ -d "/mnt" ]; then
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            mount_point=$(echo "$line" | awk '{print $3}')
            fs_type=$(echo "$line" | awk '{print $5}')

            # Skip if already seen
            if [[ ! " ${SEEN_MOUNTS[@]} " =~ " ${mount_point} " ]]; then
                MOUNT_POINTS+=("${mount_point}:SMB Mount (${fs_type})")
                SEEN_MOUNTS+=("${mount_point}")
            fi
        fi
    done < <(mount | grep -E "^//" || true)
fi

# Find local disk mount points (excluding special filesystems)
while IFS= read -r line; do
    if [ -n "$line" ]; then
        mount_point=$(echo "$line" | awk '{print $3}')
        device=$(echo "$line" | awk '{print $1}')
        fs_type=$(echo "$line" | awk '{print $5}')

        # Skip if already seen
        if [[ ! " ${SEEN_MOUNTS[@]} " =~ " ${mount_point} " ]]; then
            MOUNT_POINTS+=("${mount_point}:Local Disk ${device} (${fs_type})")
            SEEN_MOUNTS+=("${mount_point}")
        fi
    fi
done < <(mount | grep -E "^/dev/(sd|nvme|vd|md)" | grep -v -E "(boot|efi)" || true)

if [ ${#MOUNT_POINTS[@]} -eq 0 ]; then
    log_output "${RED}No mount points found to test!${NC}"
    exit 1
fi

log_output "Found ${#MOUNT_POINTS[@]} location(s) to test:"
for mp in "${MOUNT_POINTS[@]}"; do
    IFS=':' read -r path desc <<< "$mp"
    log_output "  - $path ($desc)"
done
log_output ""

# Test configurations
# Format: "Test Name:rw_type:block_size"
TESTS=(
    "Sequential Read (4K):read:4k"
    "Sequential Write (4K):write:4k"
    "Random Read (4K):randread:4k"
    "Random Write (4K):randwrite:4k"

    "Sequential Read (128K):read:128k"
    "Sequential Write (128K):write:128k"
    "Random Read (128K):randread:128k"
    "Random Write (128K):randwrite:128k"

    "Sequential Read (1M):read:1m"
    "Sequential Write (1M):write:1m"
    "Random Read (1M):randread:1m"
    "Random Write (1M):randwrite:1m"
)

# Run tests for each mount point
for mp in "${MOUNT_POINTS[@]}"; do
    IFS=':' read -r mount_path mount_desc <<< "$mp"

    log_output ""
    log_output "${YELLOW}═══════════════════════════════════════════════════════${NC}"
    log_output "${YELLOW}Testing: $mount_path${NC}"
    log_output "${YELLOW}Description: $mount_desc${NC}"
    log_output "${YELLOW}═══════════════════════════════════════════════════════${NC}"

    # Create test directory
    TEST_DIR="${mount_path}/fio_test_$$"
    mkdir -p "$TEST_DIR" 2>/dev/null || {
        log_output "${RED}Cannot create test directory in $mount_path (permission denied?)${NC}"
        log_output ""
        echo "**$mount_path** - Permission Denied" >> "$OUTPUT_MD"
        echo "" >> "$OUTPUT_MD"
        continue
    }

    echo "" >> "$OUTPUT_MD"
    echo "## $mount_path" >> "$OUTPUT_MD"
    echo "" >> "$OUTPUT_MD"
    echo "**Description:** $mount_desc" >> "$OUTPUT_MD"
    echo "" >> "$OUTPUT_MD"
    echo "| Test | Bandwidth | IOPS | Latency |" >> "$OUTPUT_MD"
    echo "|------|-----------|------|---------|" >> "$OUTPUT_MD"

    # Run each test
    for test in "${TESTS[@]}"; do
        IFS=':' read -r test_name rw_type bs <<< "$test"
        run_fio_test "$test_name" "$rw_type" "$bs" "$TEST_DIR" "$mount_desc"
    done

    # Cleanup test directory
    rm -rf "$TEST_DIR"

    echo "" >> "$OUTPUT_MD"
done

# Cleanup
rm -rf "$TEMP_DIR"

log_output ""
log_output "${YELLOW}═══════════════════════════════════════════════════════${NC}"
log_output "${GREEN}Testing Complete!${NC}"
log_output "${YELLOW}═══════════════════════════════════════════════════════${NC}"
log_output ""
log_output "${GREEN}Results saved to: $OUTPUT_MD${NC}"
log_output ""

# Add summary footer to markdown
cat >> "$OUTPUT_MD" << 'EOF'

---

## Test Notes

- **Block Sizes:**
  - Small: 4K (typical for database operations, random access)
  - Medium: 128K (balanced performance)
  - Large: 1M (large file transfers, sequential operations)

- **Test Types:**
  - Sequential Read/Write: Data accessed in order (streaming)
  - Random Read/Write: Data accessed randomly (database workloads)

- **Metrics:**
  - **Bandwidth (BW):** Amount of data transferred per second
  - **IOPS:** Input/Output Operations Per Second
  - **Latency:** Time taken to complete an I/O operation

EOF

echo "View the detailed results:"
echo "  cat $OUTPUT_MD"
