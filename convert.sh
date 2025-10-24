#!/bin/bash -e

# =========================
# Batch H.265 Transcode (Recursive)
# - Outputs -> completed_transcribing/ (mirrors original structure)
# - Filenames use *_out.mp4
# - Metadata & timestamps preserved
# - All audio tracks preserved (per-channel AAC bitrate)
# - Skips completed outputs and excludes completed_transcribing/
# =========================

# ---- USER CONFIGURATION ----
# Video encoding parameters
VIDEO_CODEC="libx265"              # Codec for video
VIDEO_CRF=28                        # Constant Rate Factor for quality (lower = better quality, larger file)
VIDEO_PRESET="slow"                # Preset for ffmpeg (slow, medium, fast)
AUDIO_CODEC="aac"                  # Audio codec
SUBTITLE_COPY=true                  # Whether to copy subtitle streams

# Output handling
OUTPUT_SUFFIX="_out"               # Suffix appended to filenames before extension
OUTPUT_DIR_NAME="completed_transcribing"  # Root folder for completed videos

# Progress and estimation
SPEED_X_DEFAULT=1.35                 # Default speed factor (1.35x faster than real time)
PROGRESS_BAR_WIDTH=40               # Width of progress bar


# Supported extensions (lowercase)
EXTS=( "*.mp4" "*.mkv" "*.avi" "*.mov" "*.mts" "*.m2ts" "*.webm" )

# ---- Resolve script directory ----
SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; do
  DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE
done
CURRENT_DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )

# ---- Colors ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NOCOLOR='\033[0m'

# ---- Binaries ----
ffmpeg_bin="/opt/homebrew/bin/ffmpeg"
ffprobe_bin="/opt/homebrew/bin/ffprobe"
exiftool_bin="/opt/homebrew/bin/exiftool"

# ---- Settings ----
COMPLETED_ROOT="$CURRENT_DIR/$OUTPUT_DIR_NAME"

# ---- Estimation speed (X real-time). Example: 1.4 means 1.4x faster than real-time
# Can be overridden by env var SPEED_X or --speed=X cli arg parsing (handled below)
SPEED_X=${SPEED_X:-$SPEED_X_DEFAULT}

# ---- Helpers ----
get_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
get_birthtime() { stat -f %B "$1" 2>/dev/null || echo ""; }
probe_duration() {
  local d=$("$ffprobe_bin" -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null || echo "")
  [[ -n "$d" && "$d" != "N/A" ]] && printf "%.0f\n" "$d" || echo "0"
}
probe_audio_channels_list() { "$ffprobe_bin" -v error -select_streams a -show_entries stream=channels -of csv=p=0 "$1" 2>/dev/null || true; }
probe_audio_stream_count() { probe_audio_channels_list "$1" | grep -c .; }

# ---- Time helpers for estimates ----
fmt_hms() {
  local s=$1
  printf "%02d:%02d:%02d" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

# Add seconds to NOW in a portable way (macOS and GNU date)
add_seconds_to_now() {
  local secs=$1
  if date -v +1S +%Y-%m-%dT%H:%M:%S >/dev/null 2>&1; then
    # BSD date (macOS)
    date -v+"${secs}"S +"%Y-%m-%d %H:%M:%S"
  else
    # GNU date (Linux)
    date -d "+${secs} seconds" +"%Y-%m-%d %H:%M:%S"
  fi
}

# ---- Validation: output completeness ----
is_output_complete() {
  local input="$1" output="$2"
  [[ -s "$output" ]] || return 1

  local din=$(probe_duration "$input") dout=$(probe_duration "$output")
  (( din > 0 && dout > 0 )) || return 1
  local tol=$((din/200)); [[ $tol -lt 1 ]] && tol=1
  (( dout < din - tol || dout > din + tol )) && return 1

  local ain=$(probe_audio_stream_count "$input") aout=$(probe_audio_stream_count "$output")
  [[ "$ain" -eq "$aout" ]] || return 1

  mapfile -t in_ch < <(probe_audio_channels_list "$input")
  mapfile -t out_ch < <(probe_audio_channels_list "$output")
  for i in "${!in_ch[@]}"; do
    [[ "${out_ch[$i]}" == "${in_ch[$i]}" ]] || return 1
  done

  local mt_in=$(get_mtime "$input") mt_out=$(get_mtime "$output")
  [[ "$mt_in" == "$mt_out" ]] || return 1

  local bt_in=$(get_birthtime "$input") bt_out=$(get_birthtime "$output")
  if [[ -n "$bt_in" && -n "$bt_out" && "$bt_in" != "$bt_out" ]]; then return 1; fi

  return 0
}

fix_timestamps_and_metadata() {
  local input="$1" output="$2"
  "$exiftool_bin" -api largefilesupport=1 -overwrite_original -TagsFromFile "$input" -All:All "$output" >/dev/null || true
  "$exiftool_bin" -overwrite_original -api largefilesupport=1 -TagsFromFile "$input" "-FileCreateDate<FileCreateDate" "-FileModifyDate<FileModifyDate" "$output" >/dev/null || true
  touch -r "$input" "$output" || true
}

# ---- Info ----
echo -e "\n${YELLOW}Transcoding videos under:${NOCOLOR} $CURRENT_DIR"
echo -e "${YELLOW}Excluding:${NOCOLOR} $COMPLETED_ROOT"
echo -e "${YELLOW}Output:${NOCOLOR} $COMPLETED_ROOT (mirrors structure)"
echo -e "${YELLOW}Codec:${NOCOLOR} $VIDEO_CODEC CRF $VIDEO_CRF | Audio $AUDIO_CODEC per-stream | Subs copied | ${YELLOW}Est. speed:${NOCOLOR} ${SPEED_X}x"
echo -e "${RED}Existing *${OUTPUT_SUFFIX}.mp4 skipped if complete.${NOCOLOR}\n"

mkdir -p "$COMPLETED_ROOT"

# ---- CLI Args ----
for arg in "$@"; do
  case $arg in
    --speed=*) SPEED_X="${arg#*=}" ;;
  esac
done

# Coerce SPEED_X to a sane numeric default if empty
if [[ -z "$SPEED_X" ]]; then SPEED_X=$SPEED_X_DEFAULT; fi

# ---- Scan files (exclude completed_transcribing) ----
TOTAL_VIDEO_SIZE_ORIGINAL=0
VIDEO_FILES=(); VIDEO_SIZES=(); VIDEO_DURATIONS=()

echo -e "${BLUE}Scanning video files...${NOCOLOR}\n"
find_cmd=( find "$CURRENT_DIR" -type d -name "$OUTPUT_DIR_NAME" -prune -o -type f \( -false )
for pat in "${EXTS[@]}"; do find_cmd+=( -o -iname "$pat" ); done
find_cmd+=( \) -print0 )
while IFS= read -r -d '' FILE; do
  FILE_SIZE=$(wc -c < "$FILE")
  DUR=$(probe_duration "$FILE")
  VIDEO_FILES+=("$FILE"); VIDEO_SIZES+=("$FILE_SIZE"); VIDEO_DURATIONS+=("$DUR")
  TOTAL_VIDEO_SIZE_ORIGINAL=$((TOTAL_VIDEO_SIZE_ORIGINAL + FILE_SIZE))
done < <("${find_cmd[@]}")

[[ ${#VIDEO_FILES[@]} -gt 0 ]] || { echo -e "${RED}No video files found.${NOCOLOR}"; exit 1; }

# ---- Sort by size ----
INDICES=(); for i in "${!VIDEO_FILES[@]}"; do INDICES+=("$i"); done
for ((i=0;i<${#INDICES[@]};i++)); do
  for ((j=i+1;j<${#INDICES[@]};j++)); do
    idx1=${INDICES[i]}; idx2=${INDICES[j]}
    if [[ ${VIDEO_SIZES[idx1]} -gt ${VIDEO_SIZES[idx2]} ]]; then tmp=${INDICES[i]}; INDICES[i]=${INDICES[j]}; INDICES[j]=$tmp; fi
  done
done
SORTED_VIDEO_FILES=(); SORTED_VIDEO_SIZES=(); SORTED_VIDEO_DURATIONS=()
for idx in "${INDICES[@]}"; do
  SORTED_VIDEO_FILES+=("${VIDEO_FILES[idx]}"); SORTED_VIDEO_SIZES+=("${VIDEO_SIZES[idx]}"); SORTED_VIDEO_DURATIONS+=("${VIDEO_DURATIONS[idx]}")
done
VIDEO_FILES=("${SORTED_VIDEO_FILES[@]}"); VIDEO_DURATIONS=("${SORTED_VIDEO_DURATIONS[@]}")

# ---- Overall ETA at SPEED_X ----
TOTAL_ESTIMATED_SECONDS=0
for dur in "${VIDEO_DURATIONS[@]}"; do
  if awk "BEGIN{exit !($SPEED_X>0)}"; then
    est=$(echo "$dur / $SPEED_X" | bc -l)
  else
    est=$dur
  fi
  TOTAL_ESTIMATED_SECONDS=$(echo "$TOTAL_ESTIMATED_SECONDS + $est" | bc -l)
done
TOTAL_ESTIMATED_SECONDS=$(printf "%.0f" "$TOTAL_ESTIMATED_SECONDS")
EST_HH=$((TOTAL_ESTIMATED_SECONDS/3600))
EST_MM=$(((TOTAL_ESTIMATED_SECONDS%3600)/60))
EST_SS=$((TOTAL_ESTIMATED_SECONDS%60))

# ---- Print queue with estimates ----
echo -e "${BLUE}Files found (with per-file ETA at ${SPEED_X}x):${NOCOLOR}\n"
PER_FILE_EST_SECONDS=()
TOTAL_EST_SECONDS=0
CUMULATIVE_SECONDS=0
NOW_EPOCH=$(date +%s)
for i in "${!VIDEO_FILES[@]}"; do
  FILE="${VIDEO_FILES[i]}"; SZ="${SORTED_VIDEO_SIZES[i]}"; DUR="${VIDEO_DURATIONS[i]}"
  # estimated seconds for this file at SPEED_X
  # guard against SPEED_X <= 0
  if awk "BEGIN{exit !($SPEED_X>0)}"; then
    EST=$([[ "$DUR" -gt 0 ]] && echo "$DUR / $SPEED_X" | bc -l || echo 0)
  else
    EST=$DUR
  fi
  EST_INT=$(printf "%.0f" "$EST")
  PER_FILE_EST_SECONDS+=("$EST_INT")
  TOTAL_EST_SECONDS=$((TOTAL_EST_SECONDS + EST_INT))

  # Predicted finish time for this file considering cumulative time before it
  CUMULATIVE_SECONDS=$((CUMULATIVE_SECONDS + EST_INT))
  FINISH_TS=$(add_seconds_to_now "$CUMULATIVE_SECONDS")

  printf "• %s\n    Size: %.2f GB | Duration: %s | Est: %s | Done by: %s\n" \
    "$FILE" "$(echo "scale=2; $SZ / (1024^3)" | bc)" \
    "$(fmt_hms "$DUR")" "$(fmt_hms "$EST_INT")" "$FINISH_TS"
done


# Print totals
TOTAL_EST_HMS=$(fmt_hms "$TOTAL_EST_SECONDS")
TOTAL_FINISH_TS=$(add_seconds_to_now "$TOTAL_EST_SECONDS")
echo -e "\n${YELLOW}Total estimated processing time:${NOCOLOR} ${RED}${TOTAL_EST_HMS}${NOCOLOR}"
echo -e "${YELLOW}Estimated batch completion time:${NOCOLOR} ${RED}${TOTAL_FINISH_TS}${NOCOLOR}\n"

# Wait for explicit confirmation AFTER showing the queue and totals
echo -e "Press Enter to start transcoding or Ctrl+C to abort"
read -rp "" _

# ---- Process ----
draw_progress_bar() {
  local progress=$1 total=$2 width=$3
  local percent=$(( 100 * progress / total ))
  local filled=$(( width * progress / total ))
  local empty=$(( width - filled ))
  printf "["; for ((i=0;i<filled;i++)); do printf "#"; done; for ((i=0;i<empty;i++)); do printf "-"; done; printf "] %3d%%" $percent
}

NUM_FILES=${#VIDEO_FILES[@]}
TOTAL_VIDEO_SIZE_PROCESSED=0
for idx in "${!VIDEO_FILES[@]}"; do
  input_file="${VIDEO_FILES[idx]}"
  rel_path="${input_file#$CURRENT_DIR/}"
  rel_dir="$(dirname "$rel_path")"
  input_base="$(basename "$input_file")"
  base_noext="${input_base%.*}"
  dest_dir="$COMPLETED_ROOT/$rel_dir"
  mkdir -p "$dest_dir"
  output_file="$dest_dir/${base_noext}${OUTPUT_SUFFIX}.mp4"

  # Skip completed
  if [[ -e "$output_file" ]]; then
    if is_output_complete "$input_file" "$output_file"; then
      echo -e "${GREEN}Skipping complete:${NOCOLOR} $output_file"
      continue
    fi
    echo -e "${YELLOW}Re-checking incomplete output:${NOCOLOR} $output_file"
    fix_timestamps_and_metadata "$input_file" "$output_file"
    if is_output_complete "$input_file" "$output_file"; then
      echo -e "${GREEN}Fixed metadata/timestamps:${NOCOLOR} $output_file"
      continue
    fi
    echo -e "${RED}Re-encoding incomplete file...${NOCOLOR}"
  fi

  # Progress
  draw_progress_bar $idx $NUM_FILES $PROGRESS_BAR_WIDTH
  echo -e "\n${YELLOW}Processing:${NOCOLOR} $input_file"

  # Build per-audio-stream AAC args preserving channels
  audio_args=(); a_idx=0
  while IFS= read -r ch; do
    [[ -z "$ch" ]] && continue
    if (( ch <= 1 )); then br="96k"
    elif (( ch == 2 )); then br="160k"
    else br="384k"
    fi
    audio_args+=( -c:a:$a_idx "$AUDIO_CODEC" -b:a:$a_idx "$br" )
    ((a_idx++))
  done < <(probe_audio_channels_list "$input_file")

  # Transcode
  "$ffmpeg_bin" -y \
    -i "$input_file" \
    -map 0 -map_metadata 0 \
    -c:v "$VIDEO_CODEC" -preset "$VIDEO_PRESET" -crf "$VIDEO_CRF" \
    "${audio_args[@]}" \
    -c:s copy \
    -movflags +faststart \
    "$output_file"

  # Metadata/timestamps
  fix_timestamps_and_metadata "$input_file" "$output_file"

  # Verify
  if is_output_complete "$input_file" "$output_file"; then
    echo -e "${GREEN}✓ Completed:${NOCOLOR} $output_file\n"
  else
    echo -e "${RED}⚠ WARNING:${NOCOLOR} $output_file failed validation.\n"
  fi
done

echo -e "${GREEN}All outputs written to:${NOCOLOR} $COMPLETED_ROOT"
exit 0