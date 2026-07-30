/// The two media skills an agent gets on a grid: generating an image, and
/// animating one into a video, both through the grid's media API.
///
/// A "skill" is a `SKILL.md` (when to use it + how) plus a script it runs. Both
/// are **credential-free**: the scripts read the grid endpoint and key from
/// `~/.hermes/.env` (which the app already writes) at run time, so they always
/// target whatever grid the app pointed the agent at and never bake a token into
/// a file. Both also read the *same* pair — `OPENAI_BASE_URL` / `OPENAI_API_KEY`
/// — differing only by endpoint (image vs video), so switching grids repoints
/// both at once. A hand-made video prototype hardcoded a stale grid and read
/// `GRID_API_KEY` instead, so it kept hitting the wrong grid — the installer
/// overwrites it.
library;

import 'dart:io';

import '../../../shared/skills/agent_skill_home.dart';

/// What `grid agent install` and the skill card call the image skill.
const String kGridImageSkillName = 'grid-image-gen';

/// What the video skill is named on disk.
const String kGridVideoSkillName = 'grid-video-gen';

/// The image-generation skill as it lands in [skillDir]: its card plus the
/// single script it runs.
///
/// The card spells the script out by absolute path — the agent runs what the
/// card says, so the path has to be a function of where the skill was written
/// rather than a constant that goes stale the day the folder moves.
GridSkillFiles gridImageSkillFiles(Directory skillDir) => GridSkillFiles(
  card: _gridImageSkillMd('${skillDir.path}/scripts/generate.py'),
  files: const {'scripts/generate.py': _gridImageSkillScript},
);

/// The image-to-video skill as it lands in [skillDir]: its card plus the single
/// script it runs.
GridSkillFiles gridVideoSkillFiles(Directory skillDir) => GridSkillFiles(
  card: _gridVideoSkillMd('${skillDir.path}/scripts/generate.py'),
  files: const {'scripts/generate.py': _gridVideoSkillScript},
);

String _gridImageSkillMd(String scriptPath) => '''
---
name: grid-image-gen
description: Generate an image through the user's Grid (its media API). Use whenever the user asks to draw, create, or generate a picture.
tags: [image-generation, grid]
triggers:
  - user asks to generate / create / draw / make an image or picture
  - "vẽ", "tạo ảnh", "generate an image", "draw me", "make a picture"
---

# Generate an image through Grid

The user's Grid can generate images. Run the bundled script — it reads the grid
endpoint and key from `~/.hermes/.env`, so you never handle credentials.

## Run it
```
python3 $scriptPath "<prompt>" [-o <dir>]
```
Default output dir is `~/Downloads`. The script prints `Saved: <path>` for each
image and exits non-zero on failure.

## Show the result
The script prints `Saved: <path>` for each image. Show every saved image to the
user by putting it on its own line as a markdown image, exactly:

    ![image](<path>)

using the absolute saved path — e.g. `![image](/Users/you/Downloads/output_image_001.png)`.
The Grid app turns that line into the picture itself. Do **not** say you "opened
it in the app" or that they should "look at the screen": the image appears only
if your reply contains that `![image](<path>)` line. One line per saved image.

## If it fails
- Exit code 2 = the grid isn't configured. Tell the user to open Grid, pick a
  grid, and make sure a model that can make images is running on it.
- Any other failure = the grid couldn't generate right now; suggest trying again.
- The stream can take 30–120s. Be patient; do not retry mid-run.
''';

const _gridImageSkillScript = r'''#!/usr/bin/env python3
"""Generate an image through the user's Grid media API.

Credential-free: reads OPENAI_BASE_URL and OPENAI_API_KEY from the environment,
falling back to ~/.hermes/.env (which the Grid app writes). No endpoint or key is
baked in, so this targets whatever grid the app pointed Hermes at.

Uses curl via subprocess: Python's urllib fails TLS on stock macOS
(CERTIFICATE_VERIFY_FAILED) — do NOT switch it back to urllib.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime


def _load_creds():
    base = os.environ.get("OPENAI_BASE_URL")
    key = os.environ.get("OPENAI_API_KEY")
    env_path = os.path.expanduser("~/.hermes/.env")
    if (not base or not key) and os.path.exists(env_path):
        with open(env_path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, _, value = line.partition("=")
                value = value.strip().strip('"').strip("'")
                if name.strip() == "OPENAI_BASE_URL" and not base:
                    base = value
                elif name.strip() == "OPENAI_API_KEY" and not key:
                    key = value
    if not base or not key:
        print(
            "Grid isn't configured. Open Grid, pick a grid, and make sure a "
            "model that can make images is running on it.",
            file=sys.stderr,
        )
        sys.exit(2)
    return base.rstrip("/"), key


def generate(prompt, width, height, steps, output_dir):
    base, key = _load_creds()
    url = base + "/media/image/generate"
    output_dir = os.path.expanduser(output_dir or "~/Downloads")
    os.makedirs(output_dir, exist_ok=True)

    payload = json.dumps(
        {
            "capability": "comfyui:image_generation",
            "prompt": prompt,
            "width": width,
            "height": height,
            "steps": steps,
        }
    )
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False
    ) as handle:
        handle.write(payload)
        payload_file = handle.name

    try:
        result = subprocess.run(
            [
                "curl", "-s", "-N", "-X", "POST", url,
                "-H", "Authorization: Bearer " + key,
                "-H", "Content-Type: application/json",
                "-H", "Accept: text/event-stream",
                "-d", "@" + payload_file,
            ],
            capture_output=True,
            text=True,
            timeout=300,
        )
    finally:
        os.unlink(payload_file)

    if result.returncode != 0:
        print("Network error talking to the grid: " + result.stderr, file=sys.stderr)
        sys.exit(1)

    saved = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line.startswith("data: "):
            continue
        data = line[6:]
        if data == "[DONE]":
            break
        try:
            event = json.loads(data)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "error":
            print("Grid error: " + str(event.get("error", "unknown")), file=sys.stderr)
            sys.exit(1)
        if event.get("type") == "result":
            for item in event.get("output_files", []):
                blob = item.get("content_base64", "")
                if not blob:
                    continue
                name, ext = os.path.splitext(item.get("filename", "image.png"))
                stamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
                path = os.path.join(output_dir, name + "_" + stamp + ext)
                with open(path, "wb") as out:
                    out.write(base64.b64decode(blob))
                saved.append(path)
                print("Saved: " + path)
    return saved


def main():
    parser = argparse.ArgumentParser(description="Generate an image via Grid")
    parser.add_argument("prompt", help="What to draw")
    parser.add_argument("--width", type=int, default=1024)
    parser.add_argument("--height", type=int, default=1024)
    parser.add_argument("--steps", type=int, default=4)
    parser.add_argument("-o", "--output-dir", default=None)
    args = parser.parse_args()

    saved = generate(
        args.prompt, args.width, args.height, args.steps, args.output_dir
    )
    if not saved:
        print("The grid finished but returned no image.", file=sys.stderr)
        sys.exit(1)
    print("Done. " + str(len(saved)) + " image(s) saved.")


if __name__ == "__main__":
    main()
''';

String _gridVideoSkillMd(String scriptPath) => '''
---
name: grid-video-gen
description: Animate an image into a video through the user's Grid (its media API, ComfyUI i2v). Use whenever the user asks to animate a picture, make a video from a photo, or turn a still into motion.
tags: [video-generation, grid, animation]
triggers:
  - user asks to animate an image / make a video from a picture
  - "tạo video", "làm animation", "chuyển thành video", "animate this", "image to video"
---

# Animate an image into a video through Grid

The user's Grid animates a still image (ComfyUI image-to-video). Run the bundled
script — it reads the grid endpoint and key from `~/.hermes/.env`, so you never
handle credentials. It targets whatever grid the app is on right now.

## Run it
```
python3 $scriptPath "<how it should move>" "<image_path>" [-o <dir>]
```
`<image_path>` is the still to animate — any local image file. You do **not** need
to open, view or understand it: the script reads its raw bytes. Take the motion
description from the user's words; if they give none, use gentle natural motion.
Default output dir is `~/Downloads`. The script prints `Saved: <path>` for the
video and exits non-zero on failure.

## Show the result
The script prints `Saved: <path>`. Show the video by putting it on its own line
as a markdown link, exactly:

    ![video](<path>)

using the absolute saved path — e.g. `![video](/Users/you/Downloads/grid_video_001.mp4)`.
The Grid app turns that line into the player itself. Do **not** say you "opened it
in the app" or that they should "look at the screen": the video appears only if
your reply contains that `![video](<path>)` line.

## If it fails
- Exit code 2 = the grid isn't configured. Tell the user to open Grid, pick a
  grid, and make sure a model that can make videos is running on it.
- Exit code 3 = the source image couldn't be read; check the path.
- Any other failure = the grid couldn't generate right now; suggest trying again.
- The stream can take 1–3 min. Be patient; do not retry mid-run.
''';

const _gridVideoSkillScript = r'''#!/usr/bin/env python3
"""Animate an image into a video through the user's Grid media API (i2v).

Credential-free: reads OPENAI_BASE_URL and OPENAI_API_KEY from the environment,
falling back to ~/.hermes/.env (which the Grid app writes). No endpoint or key is
baked in, so this targets whatever grid the app pointed Hermes at — unlike the
old prototype, which hardcoded a grid and read its own key variable, so it kept
hitting the wrong grid with the wrong key.

Uses curl via subprocess: Python's urllib fails TLS on stock macOS
(CERTIFICATE_VERIFY_FAILED) — do NOT switch it back to urllib.
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime


def _load_creds():
    base = os.environ.get("OPENAI_BASE_URL")
    key = os.environ.get("OPENAI_API_KEY")
    env_path = os.path.expanduser("~/.hermes/.env")
    if (not base or not key) and os.path.exists(env_path):
        with open(env_path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, _, value = line.partition("=")
                value = value.strip().strip('"').strip("'")
                if name.strip() == "OPENAI_BASE_URL" and not base:
                    base = value
                elif name.strip() == "OPENAI_API_KEY" and not key:
                    key = value
    if not base or not key:
        print(
            "Grid isn't configured. Open Grid, pick a grid, and make sure a "
            "model that can make videos is running on it.",
            file=sys.stderr,
        )
        sys.exit(2)
    return base.rstrip("/"), key


def _encode_image(path):
    try:
        with open(os.path.expanduser(path), "rb") as handle:
            return base64.b64encode(handle.read()).decode("utf-8")
    except OSError as exc:
        print("Couldn't read the source image: " + str(exc), file=sys.stderr)
        sys.exit(3)


def generate(prompt, image_path, duration, aspect_ratio, output_dir):
    base, key = _load_creds()
    url = base + "/media/video/i2v"
    output_dir = os.path.expanduser(output_dir or "~/Downloads")
    os.makedirs(output_dir, exist_ok=True)

    payload = json.dumps(
        {
            "capability": "comfyui:i2v",
            "prompt": prompt,
            "duration": duration,
            "aspect_ratio": aspect_ratio,
            "input_image": {
                "filename": os.path.basename(image_path) or "in.png",
                "content_base64": _encode_image(image_path),
            },
        }
    )
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".json", delete=False
    ) as handle:
        handle.write(payload)
        payload_file = handle.name

    try:
        result = subprocess.run(
            [
                "curl", "-s", "-N", "-X", "POST", url,
                "-H", "Authorization: Bearer " + key,
                "-H", "Content-Type: application/json",
                "-H", "Accept: text/event-stream",
                "-d", "@" + payload_file,
            ],
            capture_output=True,
            text=True,
            timeout=600,
        )
    finally:
        os.unlink(payload_file)

    if result.returncode != 0:
        print("Network error talking to the grid: " + result.stderr, file=sys.stderr)
        sys.exit(1)

    saved = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line.startswith("data: "):
            continue
        data = line[6:]
        if data == "[DONE]":
            break
        try:
            event = json.loads(data)
        except json.JSONDecodeError:
            continue
        if event.get("type") == "error" or event.get("error"):
            print("Grid error: " + str(event.get("error", "unknown")), file=sys.stderr)
            sys.exit(1)
        if event.get("type") == "result":
            for item in event.get("output_files", []):
                blob = item.get("content_base64", "")
                if not blob:
                    continue
                stamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
                path = os.path.join(output_dir, "grid_video_" + stamp + ".mp4")
                with open(path, "wb") as out:
                    out.write(base64.b64decode(blob))
                saved.append(path)
                print("Saved: " + path)
    return saved


def main():
    parser = argparse.ArgumentParser(
        description="Animate an image into a video via Grid"
    )
    parser.add_argument("prompt", help="How the image should move")
    parser.add_argument("image", help="Path to the source image to animate")
    parser.add_argument("--duration", default="5s")
    parser.add_argument("--aspect-ratio", default="2:3")
    parser.add_argument("-o", "--output-dir", default=None)
    args = parser.parse_args()

    saved = generate(
        args.prompt, args.image, args.duration, args.aspect_ratio, args.output_dir
    )
    if not saved:
        print("The grid finished but returned no video.", file=sys.stderr)
        sys.exit(1)
    print("Done. " + str(len(saved)) + " video(s) saved.")


if __name__ == "__main__":
    main()
''';
