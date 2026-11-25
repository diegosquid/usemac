#!/usr/bin/env python3
"""Adds (or replaces) one release in the Sparkle appcast, keeping the other releases.

usage: appcast_add_item.py <appcast.xml> --version V --build N --notes notes.html --url URL
                           --signature SIG --length BYTES [--channel beta] [--min-system 15.0]

Items without a channel are stable and offered to everyone; items in the "beta" channel are offered only
to apps that allow it (UseMac: Settings > Software Updates > Beta updates).
"""
import argparse
import email.utils
import pathlib
import re
import time

HEADER = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>UseMac Changelog</title>
    <link>https://usemac.app/appcast.xml</link>
    <description>Official automatic updates for UseMac (macOS 15+ Apple Silicon).</description>
    <language>en</language>
"""
FOOTER = """  </channel>
</rss>
"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("appcast")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--notes", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--channel")
    parser.add_argument("--min-system", default="15.0")
    args = parser.parse_args()

    path = pathlib.Path(args.appcast)
    existing = path.read_text() if path.exists() else ""
    items = re.findall(r"    <item>.*?</item>\n", existing, flags=re.S)
    # Replace a previous item for the same build.
    items = [item for item in items if f"<sparkle:version>{args.build}</sparkle:version>" not in item]

    notes = pathlib.Path(args.notes).read_text().strip("\n")
    notes = "\n".join("        " + line if line else line for line in notes.splitlines())
    channel = f"\n      <sparkle:channel>{args.channel}</sparkle:channel>" if args.channel else ""
    item = f"""    <item>
      <title>Version {args.version}</title>
      <sparkle:version>{args.build}</sparkle:version>
      <sparkle:shortVersionString>{args.version}</sparkle:shortVersionString>{channel}
      <sparkle:minimumSystemVersion>{args.min_system}</sparkle:minimumSystemVersion>
      <pubDate>{email.utils.formatdate(time.time(), usegmt=True)}</pubDate>
      <description><![CDATA[
{notes}
      ]]></description>
      <enclosure
        url="{args.url}"
        sparkle:edSignature="{args.signature}"
        length="{args.length}"
        type="application/octet-stream"
        sparkle:os="macos"
      />
    </item>
"""
    path.write_text(HEADER + item + "".join(items) + FOOTER)
    print(f"{path}: {'replaced' if len(items) < len(re.findall(r'<item>', existing)) else 'added'} {args.version} (build {args.build}){' in channel ' + args.channel if args.channel else ''}")


if __name__ == "__main__":
    main()
