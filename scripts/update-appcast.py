#!/usr/bin/env python3
"""Add this release to appcast.xml — the feed Sparkle reads to offer updates.

Driven by scripts/release.sh, which supplies VERSION, BUILD, ED_SIG, LENGTH and
REPO in the environment. Kept separate from the shell so the XML is built by a
parser rather than by string-concatenation, where an unescaped character in a
release note would silently produce a feed no client can read.
"""
import datetime
import os
import pathlib
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

version = os.environ["VERSION"]
build = os.environ["BUILD"]
ed_sig = os.environ["ED_SIG"]
length = os.environ["LENGTH"]
repo = os.environ["REPO"]

path = pathlib.Path("appcast.xml")

if path.exists():
    tree = ET.parse(path)
    root = tree.getroot()
    channel = root.find("channel")
else:
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Claude Fleet Bar"
    ET.SubElement(channel, "link").text = f"https://github.com/{repo}"
    ET.SubElement(channel, "description").text = "Updates for Claude Fleet Bar"
    ET.SubElement(channel, "language").text = "en"
    tree = ET.ElementTree(root)

# Republishing a version must replace its entry, never add a second one with
# the same version — Sparkle would see two candidates and the older signature
# could win.
for existing in channel.findall("item"):
    node = existing.find(f"{{{SPARKLE_NS}}}shortVersionString")
    if node is not None and node.text == version:
        channel.remove(existing)

item = ET.Element("item")
ET.SubElement(item, "title").text = version
ET.SubElement(item, "pubDate").text = datetime.datetime.now(
    datetime.timezone.utc
).strftime("%a, %d %b %Y %H:%M:%S +0000")
# Sparkle compares CFBundleVersion, not the display string, to decide newness.
ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = build
ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = version
ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = "14.0"
ET.SubElement(item, "link").text = f"https://github.com/{repo}/releases/tag/v{version}"
ET.SubElement(item, "sparkle:releaseNotesLink" if False else "description").text = (
    f"See https://github.com/{repo}/releases/tag/v{version}"
)
ET.SubElement(item, "enclosure", {
    "url": f"https://github.com/{repo}/releases/download/v{version}/ClaudeFleetBar.zip",
    "length": length,
    "type": "application/octet-stream",
    f"{{{SPARKLE_NS}}}edSignature": ed_sig,
})

# Newest first: Sparkle takes the best candidate, but a human reading the feed
# should see the current release at the top.
channel.insert(len(list(channel)) - len(channel.findall("item")), item)

ET.indent(tree, space="  ")
tree.write(path, encoding="utf-8", xml_declaration=True)
print(f"  ✓ appcast.xml now advertises {version} (build {build})")
