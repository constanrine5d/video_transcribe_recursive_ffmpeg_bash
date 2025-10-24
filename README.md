# Batch H.265 Transcoding Script

This Bash script recursively transcodes video files to **H.265 (HEVC)** using `ffmpeg`, while preserving metadata and timestamps with `exiftool`.  
It mirrors the original folder structure inside a dedicated output directory and provides estimated completion times for each file and the entire batch.

---

## Features

- **Recursive scanning**: Automatically finds all supported video files in the current directory and its subdirectories.  
- **High-efficiency encoding**: Converts video to H.265 using `libx265` with a configurable CRF value and preset.  
- **Smart audio re-encoding**: Converts each audio stream to AAC, adjusting bitrate automatically based on the channel count.  
- **Subtitles preserved**: Copies subtitle streams where possible.  
- **Metadata and timestamp preservation**: Copies EXIF and filesystem metadata from the source file to the output file.  
- **ETA prediction**: Calculates estimated transcoding duration for each file and the full batch based on a configurable encoding speed.  
- **Output structure mirroring**: Maintains the same directory structure under an output folder (`completed_transcribing/`).  
- **File integrity validation**: Automatically skips previously completed or valid outputs.

---

## Requirements

- **ffmpeg**
- **ffprobe**
- **exiftool**
- **bash** (macOS or Linux)

On macOS with Homebrew:
```bash
brew install ffmpeg exiftool
```
