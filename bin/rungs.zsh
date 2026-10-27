#!/bin/zsh
# The intermediate's rate against the 1-point rule (docs/encoding.md):
# encodes a ProRes export into HEVC intermediates with VideoToolbox, the server's kept 4K rung
# (x265 `slower`, CRF 29, VBV at most 5 Mbit/s) from each intermediate and from the ProRes itself,
# and scores every file with VMAF against the ProRes in two models: vmaf_4k_v0.6.1, which the
# rule uses, and vmaf_v0.6.1, which is stricter. A rate passes when its rung scores at most
# 1 point below the rung from the ProRes in vmaf_4k_v0.6.1; the lowest rate that passes is the
# one the app should use. Run it again on every change of rate, of ffmpeg or of macOS.
#   bin/rungs.zsh <prores.mov> [work-dir] [rate in Mbit/s...]
# Defaults: work-dir next to the source, rates 50 60 80. Needs ffmpeg with libx265, libvmaf and
# VideoToolbox (Homebrew's). Files already made are kept and only scored again.
set -euo pipefail
zmodload zsh/datetime
src=${1:?usage: bin/rungs.zsh <prores.mov> [work-dir] [rate...]}
src=${src:A}
work=${2:-${src:h}/rungs-${src:t:r}}
shift $(( $# < 2 ? $# : 2 ))
rates=(${@:-50 60 80})
threads=$(sysctl -n hw.ncpu)
mkdir -p "$work"
cd "$work"
out=results-rungs.tsv
print -r -- $'file\tseconds\tMbit/s\tVMAF-4k\tVMAF-default' > $out

rate() { print $(( $(stat -f %z $1) * 8.0 / $(ffprobe -v error -show_entries format=duration -of csv=p=0 $1) / 1e6 )) }
vmaf() {  # distorted file, model
  ffmpeg -hide_banner -nostats -i $1 -i $src -lavfi \
    "[0:v]format=yuv420p10le[d];[1:v]format=yuv420p10le[r];[d][r]libvmaf=model=version=$2:n_threads=$threads" \
    -f null - 2>&1 | sed -n 's/.*VMAF score: \([0-9.]*\).*/\1/p'
}
typeset -A score
row() {  # file, seconds (0 when the file was there already)
  local v4k=$(vmaf $1 vmaf_4k_v0.6.1)
  score[$1]=$v4k
  printf '%s\t%.1f\t%.2f\t%s\t%s\n' $1 $2 $(rate $1) $v4k $(vmaf $1 vmaf_v0.6.1) | tee -a $out
}
encode() {  # output, ffmpeg arguments...; prints the seconds it took, 0 when the file was there
  local dst=$1 t0=$EPOCHREALTIME; shift
  [[ -f $dst ]] && { print 0; return }
  ffmpeg -hide_banner -loglevel error -y "$@" $dst
  print $(( EPOCHREALTIME - t0 ))
}
rung() {  # source, output
  encode $2 -i $1 -an -c:v libx265 -pix_fmt yuv420p10le -preset slower -crf 29 \
    -x265-params log-level=error:vbv-maxrate=5000:vbv-bufsize=10000 -tag:v hvc1
}

for r in $rates; do
  m=vt-${r}M.mp4
  row $m $(encode $m -i $src -an -c:v hevc_videotoolbox -profile:v main10 -pix_fmt p010le \
    -b:v ${r}M -tag:v hvc1)
done
row rung-from-prores.mp4 $(rung $src rung-from-prores.mp4)
for r in $rates; do row rung-from-vt-${r}M.mp4 $(rung vt-${r}M.mp4 rung-from-vt-${r}M.mp4); done

ref=${score[rung-from-prores.mp4]}
for r in $rates; do
  loss=$(( ref - ${score[rung-from-vt-${r}M.mp4]} ))
  if (( loss <= 1.0 )); then
    printf 'PASS: %s Mbit/s loses %.2f VMAF-4k points (rung from the ProRes: %.2f)\n' $r $loss $ref
    exit 0
  fi
  printf 'fail: %s Mbit/s loses %.2f VMAF-4k points\n' $r $loss
done
print 'No rate passes the 1-point rule.'
exit 1
