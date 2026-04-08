#!/bin/bash
# Prepare a video for seamless looping wallpaper playback
# 1. Crossfade end into beginning for visual seamlessness
# 2. Optimize encoding for fast seek-to-zero (closed GOP, faststart)
# 3. Strip audio track
#
# Usage: prepare_wallpaper_video.sh <input.mp4> <output.mp4> [fade_seconds]

set -e

input="$1"
output="$2"
fade="${3:-1}"

if [ -z "$input" ] || [ -z "$output" ]; then
    echo "Usage: $0 <input.mp4> <output.mp4> [fade_seconds]"
    exit 1
fi

# Get video duration and fps
duration=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=duration \
    -of default=noprint_wrappers=1:nokey=1 "$input")
fps_raw=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=r_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 "$input")

echo "Input: $input"
echo "Duration: ${duration}s, FPS: ${fps_raw}, Fade: ${fade}s"

# Calculate GOP size (= fps rounded, i.e. one keyframe per second)
gop=$(python3 -c "print(round($fps_raw))")
duration_int=$(python3 -c "import math; print(math.floor($duration))")
overlay_offset=$(( duration_int - fade - fade ))

echo "GOP: ${gop}, Overlay offset: ${overlay_offset}s"

# One pass: crossfade + keyframe optimization + faststart + strip audio
ffmpeg -y -i "$input" -filter_complex \
    "split[body][pre]; \
     [pre]trim=duration=${fade},format=yuva420p,fade=d=${fade}:alpha=1,setpts=PTS+(${overlay_offset}/TB)[jt]; \
     [body]trim=${fade},setpts=PTS-STARTPTS[main]; \
     [main][jt]overlay" \
    -c:v libx264 \
    -crf 18 \
    -preset slow \
    -g "${gop}" \
    -keyint_min "${gop}" \
    -sc_threshold 0 \
    -x264-params "open-gop=0" \
    -movflags +faststart \
    -an \
    "$output"

echo ""
echo "Done: $output"
echo "Verify keyframes: ffprobe -v quiet -select_streams v:0 -show_frames -show_entries frame=pict_type,key_frame,pts_time -of csv $output | head -5"
