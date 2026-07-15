import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/grid_paths.dart';

/// Installs the Grid skills Hermes uses in Agent mode — right now, generating an
/// image through the grid's media API.
///
/// A Hermes "skill" is a `SKILL.md` (when to use it + how) plus a script it
/// runs. This one is **credential-free**: the script reads the grid endpoint and
/// key from `~/.hermes/.env` (which the app already writes) at run time, so it
/// always targets whatever grid the app pointed Hermes at and never bakes a
/// token into a file. A hand-made prototype baked a live key straight into its
/// script — [install] replaces that.
class HermesSkillInstaller {
  HermesSkillInstaller({String? home}) : _home = home ?? GridPaths.userHome;

  final String _home;

  Directory get _skillDir =>
      Directory('$_home/.hermes/skills/grid/grid-image-gen');

  /// Write (or refresh) the skill, then clear out the leaked prototype.
  /// Idempotent — safe to call every time the app points Hermes at a grid.
  Future<void> install() async {
    await Directory('${_skillDir.path}/scripts').create(recursive: true);
    await File('${_skillDir.path}/SKILL.md').writeAsString(_gridImageSkillMd);
    await File(
      '${_skillDir.path}/scripts/generate.py',
    ).writeAsString(_gridImageSkillScript);
    await _removeLeakedPrototype();
  }

  /// The hand-made Grid prototypes baked a live API key into their scripts (and
  /// a `config.env`), living under Hermes's own `creative` category. Remove them
  /// so no credential lingers and the agent never sees two same-named skills.
  /// The image skill is replaced by the credential-free one above; a
  /// credential-free video skill is a follow-up.
  Future<void> _removeLeakedPrototype() async {
    for (final legacy in const [
      '.hermes/skills/creative/grid-image-gen',
      '.hermes/skills/creative/grid-video-gen',
      '.hermes/skills/grid-image-gen',
    ]) {
      final dir = Directory('$_home/$legacy');
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }
}

/// Wire through the container so the sender gets it via `ref.read`, and tests can
/// point it at a temp home.
final hermesSkillInstallerProvider = Provider<HermesSkillInstaller>(
  (ref) => HermesSkillInstaller(),
);

const _gridImageSkillMd = '''
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
python3 ~/.hermes/skills/grid/grid-image-gen/scripts/generate.py "<prompt>" [-o <dir>]
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
