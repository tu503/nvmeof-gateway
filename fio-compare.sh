#!/bin/bash
# fio-compare.sh — Apples-to-apples fio across NVMe-oF and krbd-direct
# on the same Ceph cluster, same EC backend, same host.
#
# Both legs use 10 GiB raw devices backed by nvmeof-data (EC 6+3):
#   NVMe-oF leg : /dev/nvme4n1   (nvmeof/loadtest        via gw-a/gw-b)
#   krbd leg    : /dev/rbd2      (nvmeof/loadtest-direct via krbd)

set -euo pipefail

NVMEOF=/dev/nvme4n1
KRBD=/dev/rbd2
OUT=/tmp/fio-compare
RUNTIME=30
mkdir -p "$OUT"

run_workload() {
  local name=$1 rw=$2 bs=$3 iodepth=$4 numjobs=$5 rwmix=${6:-100}
  for leg_label in nvmeof krbd; do
    local dev
    [ "$leg_label" = "nvmeof" ] && dev="$NVMEOF" || dev="$KRBD"
    local fname="$OUT/${name}-${leg_label}.json"
    echo "  [${leg_label}] ${dev}  rw=${rw} bs=${bs} iodepth=${iodepth} numjobs=${numjobs}"
    sudo fio \
      --name="${name}-${leg_label}" \
      --filename="${dev}" \
      --rw="${rw}" --bs="${bs}" --rwmixread="${rwmix}" \
      --iodepth="${iodepth}" --numjobs="${numjobs}" \
      --ioengine=io_uring --direct=1 \
      --time_based --runtime="${RUNTIME}" --ramp_time=5 \
      --group_reporting --thread \
      --output-format=json --output="${fname}" \
      >/dev/null 2>&1
  done
}

extract() {
  local name=$1 leg=$2
  jq -r '
    .jobs[0] as $j |
    [
      ($j.read.iops // 0),
      ($j.write.iops // 0),
      (($j.read.bw // 0)/1024),
      (($j.write.bw // 0)/1024),
      (($j.read.clat_ns.mean // 0)/1000),
      (($j.write.clat_ns.mean // 0)/1000),
      (($j.read.clat_ns.percentile."99.000000" // 0)/1000),
      (($j.write.clat_ns.percentile."99.000000" // 0)/1000)
    ] | @tsv
  ' "$OUT/${name}-${leg}.json"
}

echo "=== Pre-write both devices (fill so EC parity is real, not lazy) ==="
for dev in $NVMEOF $KRBD; do
  echo "  filling $dev..."
  sudo fio --name=fill --filename=$dev --rw=write --bs=1M --iodepth=8 \
      --ioengine=io_uring --direct=1 --size=100% --thread \
      >/dev/null 2>&1
done

echo
echo "=== 4k random read   (iodepth=32, numjobs=4) ==="
run_workload randread-4k randread 4k 32 4

echo "=== 4k random write  (iodepth=32, numjobs=4) ==="
run_workload randwrite-4k randwrite 4k 32 4

echo "=== 4k randrw 70/30  (iodepth=32, numjobs=4) ==="
run_workload randrw-4k randrw 4k 32 4 70

echo "=== 64k seq read     (iodepth=16, numjobs=1) ==="
run_workload seqread-64k read 64k 16 1

echo "=== 64k seq write    (iodepth=16, numjobs=1) ==="
run_workload seqwrite-64k write 64k 16 1

echo
echo "=== Results table ==="
printf "%-18s %-7s %10s %10s %10s %10s %10s %10s %10s %10s\n" \
       "workload" "leg" "rIOPS" "wIOPS" "rMiB/s" "wMiB/s" "rLatµs" "wLatµs" "r99µs" "w99µs"
for w in randread-4k randwrite-4k randrw-4k seqread-64k seqwrite-64k; do
  for leg in nvmeof krbd; do
    read -r riops wiops rbw wbw rclat wclat r99 w99 < <(extract $w $leg)
    printf "%-18s %-7s %10.0f %10.0f %10.1f %10.1f %10.0f %10.0f %10.0f %10.0f\n" \
           "$w" "$leg" "$riops" "$wiops" "$rbw" "$wbw" "$rclat" "$wclat" "$r99" "$w99"
  done
done
