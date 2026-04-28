#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import cv2
import numpy as np


def natural_key(path: Path):
    parts = re.split(r"(\d+)", path.name)
    return [int(p) if p.isdigit() else p.lower() for p in parts]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Create an interpolated MP4 from PNG keyframes in a folder."
    )
    parser.add_argument("folder", type=Path, help="Folder containing PNG keyframes")
    parser.add_argument(
        "--duration",
        type=float,
        default=30.0,
        help="Output duration in seconds (default: 30)",
    )
    parser.add_argument(
        "--fps",
        type=int,
        default=30,
        help="Output frames per second (default: 30)",
    )
    parser.add_argument(
        "--mode",
        choices=["spline", "linear"],
        default="spline",
        help="Interpolation mode between keyframes (default: spline)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Optional output mp4 path. Default: <folder>/<foldername>_<duration>s_<fps>fps.mp4",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    folder = args.folder.expanduser().resolve()

    if not folder.is_dir():
        print(f"Error: not a directory: {folder}", file=sys.stderr)
        return 1

    keyframes = sorted(folder.glob("*.png"), key=natural_key)
    if not keyframes:
        print(f"Error: no PNG files found in {folder}", file=sys.stderr)
        return 1

    frames = []
    for file_path in keyframes:
        img = cv2.imread(str(file_path), cv2.IMREAD_COLOR)
        if img is None:
            print(f"Error: failed to read {file_path}", file=sys.stderr)
            return 1
        frames.append(img)

    h, w = frames[0].shape[:2]
    for i in range(len(frames)):
        if frames[i].shape[:2] != (h, w):
            frames[i] = cv2.resize(frames[i], (w, h), interpolation=cv2.INTER_AREA)

    total_frames = int(round(args.duration * args.fps))
    if total_frames <= 0:
        print("Error: duration * fps must be > 0", file=sys.stderr)
        return 1

    if args.output is None:
        duration_label = int(args.duration) if args.duration.is_integer() else args.duration
        output_path = folder / f"{folder.name}_{duration_label}s_{args.fps}fps.mp4"
    else:
        output_path = args.output.expanduser().resolve()

    n = len(frames)
    # Loop over all keyframe pairs including last -> first for seamless looping.
    seg_base = total_frames // n
    remainder = total_frames % n
    seg_counts = [seg_base + (1 if i < remainder else 0) for i in range(n)]

    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    writer = cv2.VideoWriter(str(output_path), fourcc, args.fps, (w, h))
    if not writer.isOpened():
        print(f"Error: failed to open output writer for {output_path}", file=sys.stderr)
        return 1

    for i in range(n):
        a = frames[i].astype(np.float32)
        b = frames[(i + 1) % n].astype(np.float32)
        count = max(1, seg_counts[i])

        for j in range(count):
            t = j / max(1, count - 1)
            if args.mode == "spline":
                # Smooth cubic easing (C1 continuous) between keyframes.
                u = t * t * (3.0 - 2.0 * t)
            else:
                u = t

            blended = cv2.addWeighted(a, 1.0 - u, b, u, 0.0)
            writer.write(np.clip(blended, 0, 255).astype(np.uint8))

    writer.release()

    print(f"Wrote: {output_path}")
    print(f"Keyframes: {n}, Total frames: {total_frames}, FPS: {args.fps}, Size: {w}x{h}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())