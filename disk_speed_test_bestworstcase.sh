#!/bin/bash

# Comprehensive Disk Speed Test using fio
#
# Modes:
#   worstcase - conservative / pessimistic:
#               direct I/O, queue depth 1
#   bestcase  - throughput-oriented / practical:
#               buffered I/O, modest queue depth, end-of-test flush for writes
#
# Notes:
# - worstcase is useful for conservative comparisons and stress-like testing.
# - bestcase is intended to better approximate practical SMB/NAS throughput.
# - bestcase write tests use end_fsync=1 so reported write bandwidth reflects
#   data being flushed before completion, avoiding unrealistic cache-only results.

set -euo pipefail

# Defaults
BACKGROUND_MODE=false
MODE="worstcase"

# fio defaults shared by all modes
TEST_SIZE="1G"
RUNTIME=30
NUMJOBS=1
IOENGINE="libaio"

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --background|-b)
            BACKGROUND_MODE=true
            shift
            ;;
        --mode)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --mode requires a value"
                exit 1
            fi
            MODE="$2"
            shift 2
            ;;
        --mode=*)
            MODE="${1#*=}"
            shift
            ;;
        --help|-h)
            cat << EOF
Usage: $0 [OPTIONS]

Options:
  --background, -b         Run in background with nohup
  --mode MODE              Benchmark mode: worstcase | bestcase
  --mode=MODE              Same as above
  --help, -h               Show this help message

Modes:
  worstcase  direct=1, iodepth=1
             Conservative / pessimistic.
             Useful for strict comparisons and serialized uncached I/O.

  bestcase   direct=0, iodepth=4, end_fsync=1 for writes
             Practical / throughput-oriented.
             Better proxy for normal file transfer behavior while still making
             write completion more honest by flushing at the end.

Examples:
  $0 --mode worstcase
  $0 --mode bestcase
  $0 --background --mode=bestcase
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage."
            exit 1
            ;;
    esac
done

# Validate mode
case "$MODE" in
    worstcase)
        FIO_DIRECT=1
        FIO_IODEPTH=1
        FIO_END_FSYNC_READ=0
        FIO_END_FSYNC_WRITE=0
        FIO_MODE_DESC="Worst-case / conservative: direct I/O, queue depth 1"
        ;;
    bestcase)
        FIO_DIRECT=0
        FIO_IODEPTH=4
        FIO_END_FSYNC_READ=0
        FIO_END_FSYNC_WRITE=1
        FIO_MODE_DESC="Best-case / practical: buffered I/O, queue depth 4, end-of-test flush for writes"
        ;;
    *)
        echo "ERROR: Invalid mode '$MODE'. Valid modes are: worstcase, bestcase"
        exit 1
        ;;
esac

# If background mode requested and not already running in background
if [[ "$BACKGROUND_MODE" == true && -z "${RUNNING_IN_BACKGROUND:-}" ]]; then
    echo "Starting disk speed test in background mode..."
    echo "Mode: $MODE"
    echo "Output will be saved to: nohup.out"
    echo "Monitor progress with: tail -f nohup.out"
    echo

    export RUNNING_IN_BACKGROUND=1
    nohup "$0" --mode "$MODE" </dev/null >nohup.out 2>&1 &

    echo "Background process started with PID: $!"
    echo "Results will be saved to a timestamped markdown file."
    exit 0
fi

# Lockfile mechanism to prevent multiple instances
LOCKFILE="/tmp/disk_speed_test.lock"

cleanup_lock() {
    rm -f "$LOCKFILE"
}

if [[ -f "$LOCKFILE" ]]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || true)
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "ERROR: Another instance of disk_speed_test is already running (PID: $LOCK_PID)"
        echo "If this is incorrect, remove the lockfile: rm $LOCKFILE"
        exit 1
    else
        echo "Removing stale lockfile from previous run..."
        rm -f "$LOCKFILE"
    fi
fi

echo $$ > "$LOCKFILE"
trap cleanup_lock EXIT INT TERM

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_MD="disk_speed_test_${MODE}_${TIMESTAMP}.md"

# Color codes for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_output() {
    echo -e "$1"
    echo -e "$1" | sed -r 's/\x1b\[[0-9;]*m//g' >> "$OUTPUT_MD"
}

# Extract latency in a more useful way by preserving the unit block
# fio commonly emits one of:
#   lat (nsec): ...
#   lat (usec): ...
#   lat (msec): ...
#   clat (usec): ...
# We capture the first avg= value and prepend the detected unit.
parse_latency() {
    local fio_output="$1"
    local unit avg

    unit=$(echo "$fio_output" | grep -E '(^|[[:space:]])(clat|lat) \((nsec|usec|msec|sec)\):' | head -1 | sed -E 's/.*\((nsec|usec|msec|sec)\).*/\1/' || true)
    avg=$(echo "$fio_output" | grep -E '(^|[[:space:]])(clat|lat).*avg=' | head -1 | sed -E 's/.*avg= *([^, ]+).*/\1/' || true)

    if [[ -n "$avg" && -n "$unit" ]]; then
        echo "${avg} ${unit}"
    elif [[ -n "$avg" ]]; then
        echo "$avg"
    else
        echo "N/A"
    fi
}

run_fio_test() {
    local test_name="$1"
    local rw_type="$2"
    local bs="$3"
    local test_dir="$4"

    echo -e "${BLUE}Running: $test_name${NC}"

    local test_file="${test_dir}/fio_test_${RANDOM}.tmp"
    local fio_output
    local end_fsync

    case "$rw_type" in
        write|randwrite)
            end_fsync="$FIO_END_FSYNC_WRITE"
            ;;
        *)
            end_fsync="$FIO_END_FSYNC_READ"
            ;;
    esac

    fio_output=$(fio \
        --name="$test_name" \
        --filename="$test_file" \
        --rw="$rw_type" \
        --bs="$bs" \
        --size="$TEST_SIZE" \
        --runtime="$RUNTIME" \
        --time_based \
        --ioengine="$IOENGINE" \
        --direct="$FIO_DIRECT" \
        --iodepth="$FIO_IODEPTH" \
        --end_fsync="$end_fsync" \
        --numjobs="$NUMJOBS" \
        --group_reporting \
        --output-format=normal 2>&1) || true

    local bw iops lat
    bw=$(echo "$fio_output" | grep -E "bw=" | head -1 | sed -E 's/.*bw=([^,]+).*/\1/' | xargs || true)
    iops=$(echo "$fio_output" | grep -E "IOPS=" | head -1 | sed -E 's/.*IOPS=([^,]+).*/\1/' | xargs || true)
    lat=$(parse_latency "$fio_output")

    [[ -z "$bw" ]] && bw="N/A"
    [[ -z "$iops" ]] && iops="N/A"

    echo -e "${GREEN}  Bandwidth: $bw | IOPS: $iops | Latency: $lat${NC}"
    echo "| $test_name | $bw | $iops | $lat |" >> "$OUTPUT_MD"

    rm -f "$test_file"
}

# Initialize markdown file
cat > "$OUTPUT_MD" << EOF
# Disk Speed Test Results

**Test Date:** $(date)
**Mode:** $MODE
**Mode Description:** $FIO_MODE_DESC

**Test Configuration:**
- Test Size: $TEST_SIZE per test
- Runtime: $RUNTIME seconds per test
- I/O Engine: $IOENGINE
- Direct I/O: $FIO_DIRECT
- I/O Depth: $FIO_IODEPTH
- End-of-test fsync for writes: $FIO_END_FSYNC_WRITE
- Num Jobs: $NUMJOBS

---

EOF

log_output "${YELLOW}═══════════════════════════════════════════════════════${NC}"
log_output "${YELLOW}         COMPREHENSIVE DISK SPEED TEST${NC}"
log_output "${YELLOW}═══════════════════════════════════════════════════════${NC}"
log_output "Mode: ${GREEN}$MODE${NC}"
log_output "Description: $FIO_MODE_DESC"
log_output ""

# Check if fio is installed
if ! command -v fio >/dev/null 2>&1; then
    log_output "${RED}ERROR: fio is not installed. Please install it first:${NC}"
    log_output "${RED}  Ubuntu/Debian: sudo apt-get install fio${NC}"
    log_output "${RED}  RHEL/CentOS: sudo yum install fio${NC}"
    exit 1
fi

# Detect mount points to test
MOUNT_POINTS=()
SEEN_MOUNTS=()

CURRENT_DIR=$(pwd)
MOUNT_POINTS+=("${CURRENT_DIR}:Current Directory")
SEEN_MOUNTS+=("${CURRENT_DIR}")

# Find SMB/CIFS mounts in /mnt
if [[ -d "/mnt" ]]; then
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            mount_point=$(echo "$line" | awk '{print $3}')
            fs_type=$(echo "$line" | awk '{print $5}')

            if [[ ! " ${SEEN_MOUNTS[*]} " =~ [[:space:]]${mount_point}[[:space:]] ]]; then
                MOUNT_POINTS+=("${mount_point}:SMB Mount (${fs_type})")
                SEEN_MOUNTS+=("${mount_point}")
            fi
        fi
    done < <(mount | grep -E '^//' || true)
fi

# Find local disk mount points (excluding special filesystems)
while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        mount_point=$(echo "$line" | awk '{print $3}')
        device=$(echo "$line" | awk '{print $1}')
        fs_type=$(echo "$line" | awk '{print $5}')

        if [[ ! " ${SEEN_MOUNTS[*]} " =~ [[:space:]]${mount_point}[[:space:]] ]]; then
            MOUNT_POINTS+=("${mount_point}:Local Disk ${device} (${fs_type})")
            SEEN_MOUNTS+=("${mount_point}")
        fi
    fi
done < <(mount | grep -E '^/dev/(sd|nvme|vd|md)' | grep -v -E '(boot|efi)' || true)

if [[ ${#MOUNT_POINTS[@]} -eq 0 ]]; then
    log_output "${RED}No mount points found to test!${NC}"
    exit 1
fi

log_output "Found ${#MOUNT_POINTS[@]} location(s) to test:"
for mp in "${MOUNT_POINTS[@]}"; do
    IFS=':' read -r path desc <<< "$mp"
    log_output "  - $path ($desc)"
done
log_output ""

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

    for test in "${TESTS[@]}"; do
        IFS=':' read -r test_name rw_type bs <<< "$test"
        run_fio_test "$test_name" "$rw_type" "$bs" "$TEST_DIR"
    done

    rm -rf "$TEST_DIR"
    echo "" >> "$OUTPUT_MD"
done

log_output ""
log_output "${YELLOW}═══════════════════════════════════════════════════════${NC}"
log_output "${GREEN}Testing Complete!${NC}"
log_output "${YELLOW}═══════════════════════════════════════════════════════${NC}"
log_output ""
log_output "${GREEN}Results saved to: $OUTPUT_MD${NC}"
log_output ""

cat >> "$OUTPUT_MD" << EOF

---

## Test Notes

- **Mode:** $MODE
- **Mode Description:** $FIO_MODE_DESC

- **Block Sizes:**
  - Small: 4K
  - Medium: 128K
  - Large: 1M

- **Test Types:**
  - Sequential Read/Write: Data accessed in order
  - Random Read/Write: Data accessed randomly

- **Metrics:**
  - **Bandwidth (BW):** Amount of data transferred per second
  - **IOPS:** Input/Output Operations Per Second
  - **Latency:** Reported as parsed from fio and includes unit when detected

## Interpretation Guidance

- **worstcase**
  - Direct I/O with queue depth 1
  - Conservative / pessimistic
  - Good for strict comparisons and regression checks

- **bestcase**
  - Buffered I/O with modest queue depth
  - Better proxy for practical NAS/file-copy behavior
  - Write tests use end-of-test flush to reduce misleading cache-only numbers

EOF

echo "View the detailed results:"
echo "  cat $OUTPUT_MD"