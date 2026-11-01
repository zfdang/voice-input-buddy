#!/usr/bin/env python3
"""Generate optimized screenshots for the Voice Input Buddy website."""
import os
from pathlib import Path
import subprocess
import tempfile
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
APP_PATH = ROOT / "dist/Voice Input Buddy.app/Contents/MacOS/VoiceInputBuddy"
OUTPUT_DIR = ROOT / "pages/assets/screenshots"

SETTINGS_SECTIONS = [
    ("connection", "connection-1020x772.png", "connection"),
    ("mapping", "mapping-1020x772.png", "mapping"),
    ("commonPhrases", "commonPhrases-1020x772.png", "phrases"),
    ("integration", "integration-1020x772.png", "integration"),
    ("permissions", "permissions-1020x772.png", "permissions"),
    ("about", "about-1020x772.png", "about"),
]

ONBOARDING_STEPS = [
    ("01-permissions.png", "wizard-permissions"),
    ("02-control-source.png", "wizard-source"),
    ("03-remote.png", "wizard-remote"),
    ("04-controls.png", "wizard-controls"),
    ("05-audio.png", "wizard-driver"),
    ("06-voice-tool.png", "wizard-tool"),
    ("07-voice-test.png", "wizard-test"),
]

def ensure_binary() -> Path:
    print("Building current sources with CONFIGURATION=debug...")
    env = os.environ.copy()
    env["CONFIGURATION"] = "debug"
    subprocess.run(["scripts/build-app.sh"], cwd=ROOT, env=env, check=True)
    return APP_PATH

def render_settings(bin_path: Path, language: str, output_tmp: Path):
    env = os.environ.copy()
    env["VOICE_INPUT_BUDDY_SETTINGS_SCREENSHOT_DIR"] = str(output_tmp)
    env["VOICE_INPUT_BUDDY_SETTINGS_SCREENSHOT_REMOTE_CARDS"] = "1"
    env["VOICE_INPUT_BUDDY_SETTINGS_SCREENSHOT_LANGUAGE"] = language
    env["VOICE_INPUT_BUDDY_SETTINGS_SCREENSHOT_APPEARANCE"] = "light"
    subprocess.run([str(bin_path)], cwd=ROOT, env=env, check=True)

def render_onboarding(bin_path: Path, language: str, output_tmp: Path):
    env = os.environ.copy()
    env["VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_DIR"] = str(output_tmp)
    env["VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_LANGUAGE"] = language
    env["VOICE_INPUT_BUDDY_ONBOARDING_SCREENSHOT_APPEARANCE"] = "light"
    subprocess.run([str(bin_path)], cwd=ROOT, env=env, check=True)

def optimize_png(src: Path, dst: Path):
    with Image.open(src) as img:
        img.save(dst, format="PNG", optimize=True)

def main():
    bin_path = ensure_binary()
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    for lang_code, lang_suffix in [("zh-Hans", "zh"), ("en", "en")]:
        with tempfile.TemporaryDirectory() as tmp_settings_dir, \
             tempfile.TemporaryDirectory() as tmp_onboarding_dir:
            print(f"Rendering {lang_code} settings screenshots...")
            render_settings(bin_path, lang_code, Path(tmp_settings_dir))
            for _, raw_filename, target_id in SETTINGS_SECTIONS:
                source_file = Path(tmp_settings_dir) / raw_filename
                target_file = OUTPUT_DIR / f"{target_id}-{lang_suffix}.png"
                print(f"Optimizing {target_file.name}...")
                optimize_png(source_file, target_file)

            print(f"Rendering {lang_code} onboarding screenshots...")
            render_onboarding(bin_path, lang_code, Path(tmp_onboarding_dir))
            for raw_filename, target_id in ONBOARDING_STEPS:
                source_file = Path(tmp_onboarding_dir) / raw_filename
                target_file = OUTPUT_DIR / f"{target_id}-{lang_suffix}.png"
                print(f"Optimizing {target_file.name}...")
                optimize_png(source_file, target_file)

    print("Screenshots generation complete!")

if __name__ == "__main__":
    main()
