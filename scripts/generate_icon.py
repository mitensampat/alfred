#!/usr/bin/env python3
"""
Generate Alfred app icon (bowler hat with gold band)
Creates all required sizes for macOS .icns file
"""

import os
import subprocess

# Try to use PIL if available, otherwise create a simple SVG-based approach
try:
    from PIL import Image, ImageDraw
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

def create_hat_svg(size):
    """Create an SVG of the bowler hat"""
    # Scale factors based on size
    s = size / 512  # Base size is 512

    svg = f'''<?xml version="1.0" encoding="UTF-8"?>
<svg width="{size}" height="{size}" viewBox="0 0 512 512" xmlns="http://www.w3.org/2000/svg">
  <!-- Background circle (optional, comment out for transparent) -->
  <!-- <circle cx="256" cy="256" r="250" fill="#1a1a2e"/> -->

  <!-- Hat brim (wide ellipse at bottom) -->
  <ellipse cx="256" cy="380" rx="200" ry="40" fill="#1a1a1a"/>

  <!-- Hat crown (rounded rectangle) -->
  <rect x="120" y="140" width="272" height="240" rx="40" ry="40" fill="#1a1a1a"/>

  <!-- Crown top curve -->
  <ellipse cx="256" cy="150" rx="130" ry="30" fill="#1a1a1a"/>

  <!-- Gold band -->
  <rect x="120" y="300" width="272" height="35" fill="#D4AF37"/>

  <!-- Band shine highlight -->
  <rect x="120" y="300" width="272" height="8" fill="#F4CF57" opacity="0.6"/>

  <!-- Subtle hat shine -->
  <ellipse cx="200" cy="220" rx="60" ry="40" fill="#2a2a2a" opacity="0.5"/>
</svg>'''
    return svg


def create_icon_with_pil(size, output_path):
    """Create icon using PIL"""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Scale factor
    s = size / 512

    # Colors
    hat_color = (26, 26, 26, 255)  # Dark gray/black
    gold_color = (212, 175, 55, 255)  # Gold
    gold_highlight = (244, 207, 87, 200)  # Lighter gold

    # Hat brim (ellipse at bottom)
    brim_bbox = [int(56*s), int(340*s), int(456*s), int(420*s)]
    draw.ellipse(brim_bbox, fill=hat_color)

    # Hat crown (rounded rectangle approximation)
    crown_bbox = [int(120*s), int(140*s), int(392*s), int(380*s)]
    draw.rounded_rectangle(crown_bbox, radius=int(40*s), fill=hat_color)

    # Crown top ellipse
    top_bbox = [int(126*s), int(120*s), int(386*s), int(180*s)]
    draw.ellipse(top_bbox, fill=hat_color)

    # Gold band
    band_bbox = [int(120*s), int(300*s), int(392*s), int(335*s)]
    draw.rectangle(band_bbox, fill=gold_color)

    # Band highlight
    highlight_bbox = [int(120*s), int(300*s), int(392*s), int(308*s)]
    draw.rectangle(highlight_bbox, fill=gold_highlight)

    img.save(output_path, 'PNG')


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.dirname(script_dir)
    iconset_dir = os.path.join(project_dir, "Alfred.app/Contents/Resources/AppIcon.iconset")
    resources_dir = os.path.join(project_dir, "Alfred.app/Contents/Resources")

    os.makedirs(iconset_dir, exist_ok=True)

    # Required sizes for macOS iconset
    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]

    if HAS_PIL:
        print("Using PIL to generate icons...")
        for size, filename in sizes:
            output_path = os.path.join(iconset_dir, filename)
            create_icon_with_pil(size, output_path)
            print(f"  Created {filename}")
    else:
        print("PIL not available. Creating SVG files for manual conversion...")
        # Create SVG files that can be converted
        for size, filename in sizes:
            svg_path = os.path.join(iconset_dir, filename.replace('.png', '.svg'))
            with open(svg_path, 'w') as f:
                f.write(create_hat_svg(size))
            print(f"  Created {filename.replace('.png', '.svg')}")

        print("\nTo convert SVGs to PNGs, you can use:")
        print("  brew install librsvg")
        print("  for f in *.svg; do rsvg-convert -o \"${f%.svg}.png\" \"$f\"; done")
        return

    # Convert iconset to icns
    icns_path = os.path.join(resources_dir, "AppIcon.icns")
    try:
        subprocess.run([
            "iconutil", "-c", "icns", "-o", icns_path, iconset_dir
        ], check=True)
        print(f"\nCreated {icns_path}")

        # Clean up iconset directory
        import shutil
        shutil.rmtree(iconset_dir)
        print("Cleaned up iconset directory")
    except subprocess.CalledProcessError as e:
        print(f"Error creating icns: {e}")
    except FileNotFoundError:
        print("iconutil not found. The iconset is ready for manual conversion.")


if __name__ == "__main__":
    main()
