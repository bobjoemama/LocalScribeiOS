#!/usr/bin/env python3
"""Check LocalScribe's actual color assets and optional Mac CSS, without packages.

Only required reading and visible graphical boundaries are checked. Disabled
text, decorative separators, and unused tokens are not claimed as accessible.
This checks colors, not font sizing, rendering, or the complete interaction UI.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

Color = tuple[float, float, float, float]
APPEARANCES = ("light", "dark")
SURFACES = ("Canvas", "Surface", "SurfaceInset", "SurfaceRaised")
MAC_ROLES = {
    "Canvas": "canvas", "Surface": "surface", "SurfaceInset": "surface-inset",
    "SurfaceRaised": "surface-raised", "Ink": "ink", "InkSecondary": "ink-secondary",
    "InkTertiary": "ink-tertiary", "Separator": "separator",
    "SeparatorStrong": "separator-strong", "ControlBorder": "control-border",
    "AccentColor": "accent", "OnAccent": "on-accent", "Recording": "recording",
    "OnRecording": "on-recording", "RecordingSoft": "recording-soft",
    "Success": "success", "SuccessSoft": "success-soft", "Warning": "warning",
    "WarningSoft": "warning-soft", "Error": "error", "ErrorSoft": "error-soft",
    "ChartCPU": "chart-cpu", "ChartMemory": "chart-memory", "ChartGPU": "chart-gpu",
}


def component(value: str) -> float:
    return int(value[2:], 16) / 255 if value.lower().startswith("0x") else float(value)


def asset_colors(root: Path) -> dict[str, dict[str, Color]]:
    result = {}
    for directory in sorted(root.glob("*.colorset")):
        entries = json.loads((directory / "Contents.json").read_text())["colors"]
        universal = [entry for entry in entries if entry.get("idiom") == "universal"]
        for appearance in APPEARANCES:
            matching = [entry for entry in universal if any(
                item.get("appearance") == "luminosity" and item.get("value") == appearance
                for item in entry.get("appearances", []))]
            defaults = [entry for entry in universal if not entry.get("appearances")]
            candidates = matching or defaults
            if len(candidates) != 1:
                raise ValueError(f"{directory.name}: no unambiguous {appearance} color")
            color = candidates[0]["color"]
            if color["color-space"] != "srgb":
                raise ValueError(f"{directory.name}: expected sRGB, got {color['color-space']}")
            values = color["components"]
            rgba = tuple(component(values[key]) for key in ("red", "green", "blue", "alpha"))
            if not all(0 <= value <= 1 for value in rgba):
                raise ValueError(f"{directory.name}: component outside [0, 1]")
            result.setdefault(appearance, {})[directory.stem] = rgba
    return result


def split_arguments(value: str) -> list[str]:
    depth = 0
    start = 0
    parts = []
    for index, char in enumerate(value):
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(value[start:index].strip())
            start = index + 1
    parts.append(value[start:].strip())
    return parts


def css_colors(path: Path) -> dict[str, dict[str, Color]]:
    source = re.sub(r"/\*.*?\*/", "", path.read_text(), flags=re.S)
    root = re.search(r":root\s*\{([^}]+)\}", source)
    if not root:
        raise ValueError(f"{path}: missing :root token declarations")
    declarations = dict(re.findall(r"--([\w-]+)\s*:\s*([^;]+);", root.group(1)))

    def resolve(value: str, appearance: str, visiting: tuple[str, ...] = ()) -> Color:
        value = value.strip()
        if value.startswith("var(") and value.endswith(")"):
            parts = split_arguments(value[4:-1])
            name = parts[0].removeprefix("--")
            if name in visiting:
                raise ValueError(f"CSS alias cycle: {' -> '.join((*visiting, name))}")
            if name not in declarations:
                if len(parts) == 2:
                    return resolve(parts[1], appearance, visiting)
                raise ValueError(f"CSS color --{name} is missing")
            return resolve(declarations[name], appearance, (*visiting, name))
        if value.startswith("light-dark(") and value.endswith(")"):
            parts = split_arguments(value[len("light-dark("):-1])
            if len(parts) != 2:
                raise ValueError(f"Invalid light-dark color: {value}")
            return resolve(parts[APPEARANCES.index(appearance)], appearance, visiting)
        if re.fullmatch(r"#[0-9a-fA-F]{3,8}", value):
            digits = value[1:]
            if len(digits) in (3, 4):
                digits = "".join(char * 2 for char in digits)
            if len(digits) == 6:
                digits += "ff"
            if len(digits) != 8:
                raise ValueError(f"Invalid hex color: {value}")
            return tuple(int(digits[index:index + 2], 16) / 255 for index in range(0, 8, 2))
        raise ValueError(f"Unsupported CSS color expression: {value}")

    roles = {**MAC_ROLES, "Focus": "focus"}
    return {appearance: {role: resolve(f"var(--{token})", appearance)
                        for role, token in roles.items()} for appearance in APPEARANCES}


def source_uses(root: Path, expression: str, extensions: tuple[str, ...]) -> bool:
    for path in root.rglob("*"):
        if path.is_file() and path.suffix in extensions and path.name != "AppTheme.swift":
            source = path.read_text()
            source = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
            # A CSS alias is a declaration, not evidence of a rendered color.
            source = re.sub(r"--[\w-]+\s*:[^;]+;", "", source)
            if re.search(expression, source):
                return True
    return False


def composite(foreground: Color, background: Color) -> Color:
    if background[3] != 1:
        raise ValueError("Contrast background must be opaque")
    alpha = foreground[3]
    return tuple(foreground[index] * alpha + background[index] * (1 - alpha)
                 for index in range(3)) + (1.0,)


def luminance(color: Color) -> float:
    linear = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4
              for value in color[:3]]
    return sum(value * weight for value, weight in zip(linear, (0.2126, 0.7152, 0.0722)))


def contrast(foreground: Color, background: Color) -> float:
    values = sorted((luminance(composite(foreground, background)), luminance(background)))
    return (values[1] + 0.05) / (values[0] + 0.05)


def required_pairs(source_root: Path, platform: str) -> list[tuple[str, str, float, str]]:
    pairs = [(ink, surface, 4.5, "reading") for ink in ("Ink", "InkSecondary") for surface in SURFACES]
    pairs += [("OnAccent", "AccentColor", 4.5, "reading"),
              ("OnRecording", "Recording", 4.5, "reading")]
    pairs += [(state, state + "Soft", 4.5, "reading") for state in ("Success", "Warning", "Error")]
    for role in ("ControlBorder", "Focus", "ChartCPU", "ChartMemory", "ChartGPU"):
        if platform == "iPhone":
            used = source_uses(source_root, rf"\bAppTheme\.{role[0].lower() + role[1:]}\b", (".swift",))
        else:
            token = "focus" if role == "Focus" else MAC_ROLES[role]
            used = source_uses(source_root, rf"var\(\s*--{token}\b", (".css", ".tsx", ".ts"))
        if used:
            backgrounds = SURFACES if role in ("ControlBorder", "Focus") else ("SurfaceInset",)
            pairs += [(role, surface, 3.0, "graphics") for surface in backgrounds]
    return pairs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    repo = Path(__file__).resolve().parents[1]
    parser.add_argument("--assets", type=Path, default=repo / "LocalScribeApp/Assets.xcassets")
    parser.add_argument("--mac-theme", type=Path, help="Mac workspace-theme.css; also checks shared palette equality")
    parser.add_argument("--json", type=Path, help="Optional machine-readable report output")
    args = parser.parse_args()
    try:
        phone = asset_colors(args.assets)
        platforms = [("iPhone", phone, args.assets.parent)]
        if args.mac_theme:
            platforms.append(("Mac", css_colors(args.mac_theme), args.mac_theme.parent))
        results = []
        for platform, colors, sources in platforms:
            pairs = required_pairs(sources, platform)
            for appearance in APPEARANCES:
                for foreground, background, minimum, kind in pairs:
                    ratio = contrast(colors[appearance][foreground], colors[appearance][background])
                    passed = ratio >= minimum
                    result = dict(platform=platform, appearance=appearance, foreground=foreground,
                                  background=background, kind=kind, ratio=ratio, minimum=minimum, passed=passed)
                    results.append(result)
                    print(f"{'PASS' if passed else 'FAIL'} {platform:6} {appearance:5} {foreground:14} on {background:13} {ratio:5.2f}:1 >= {minimum:.1f}:1")
        palette = []
        if args.mac_theme:
            mac = platforms[1][1]
            for appearance in APPEARANCES:
                for role in MAC_ROLES:
                    passed = all(abs(one - two) <= 1e-6 for one, two in zip(phone[appearance][role], mac[appearance][role]))
                    palette.append(dict(appearance=appearance, role=role, passed=passed))
                    if not passed:
                        print(f"FAIL shared palette {appearance} {role}: iPhone {phone[appearance][role]}, Mac {mac[appearance][role]}")
            print(f"Shared palette: {sum(item['passed'] for item in palette)}/{len(palette)} identical role/appearance colors (CSS aliases resolved).")
        failed = [item for item in (*results, *palette) if not item["passed"]]
        print(f"Contrast: {sum(item['passed'] for item in results)}/{len(results)} pairs passed; {len(failed)} total failures.")
        print("Limits: color checks only; unused Focus/GPU tokens, disabled text and decorative separators are excluded. No recording-on-recordingSoft reading pair is asserted.")
        report = dict(contrast=results, shared_palette=palette, passed=not failed)
        if args.json:
            args.json.write_text(json.dumps(report, indent=2) + "\n")
        return bool(failed)
    except (OSError, KeyError, ValueError, TypeError, json.JSONDecodeError) as error:
        print(f"Theme check failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
