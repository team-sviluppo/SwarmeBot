#!/usr/bin/env python3
"""Prepare curated GitHub/Sparkle notes without building or publishing a release."""
import argparse
import html
from pathlib import Path
import re
import subprocess


def version_tuple(value):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", value):
        raise ValueError("version must look like 1.2.3")
    return tuple(map(int, value.split(".")))


def section(text, version):
    sections = list(re.finditer(r"^## \[([^\]]+)\][^\n]*$", text, re.MULTILINE))
    matches = [i for i, match in enumerate(sections) if match[1] == version]
    if len(matches) != 1:
        raise ValueError(f"CHANGELOG.md needs exactly one ## [{version}] section")
    index = matches[0]
    end = sections[index + 1].start() if index + 1 < len(sections) else len(text)
    body = text[sections[index].end():end].strip()
    if not any(line.startswith("- ") and line[2:].strip() for line in body.splitlines()):
        raise ValueError(f"the {version} changelog needs user-facing bullet points")
    return body


def previous_version(root, version):
    tags = subprocess.run(
        ["git", "-C", str(root), "tag", "--merged", "HEAD"],
        check=True, capture_output=True, text=True,
    ).stdout.splitlines()
    candidates = [tag[1:] for tag in tags if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag)
                  and version_tuple(tag[1:]) < version_tuple(version)]
    return max(candidates, key=version_tuple) if candidates else None


def render_html(body):
    """The changelog uses headings, paragraphs and flat bullets; always escape authored text."""
    blocks = []
    in_list = False
    paragraph = []

    def flush_paragraph():
        if paragraph:
            blocks.append("<p>" + html.escape(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    for line in body.splitlines() + [""]:
        if line.startswith("- "):
            flush_paragraph()
            if not in_list:
                blocks.append("<ul>")
                in_list = True
            blocks.append("<li>" + html.escape(line[2:].strip()) + "</li>")
        else:
            if in_list:
                blocks.append("</ul>")
                in_list = False
            if line.startswith("### "):
                flush_paragraph()
                blocks.append("<h3>" + html.escape(line[4:].strip()) + "</h3>")
            elif not line.strip():
                flush_paragraph()
            else:
                paragraph.append(line.strip())
    return "\n".join(blocks)


def prepare(root, version, repo, output):
    version_tuple(version)
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("repository must be owner/name, without credentials")
    body = section((root / "CHANGELOG.md").read_text(encoding="utf-8"), version)
    previous = previous_version(root, version)
    introduction = f"Changes since version {previous}." if previous else "First release."
    title = f"SwarmeBot {version}"
    markdown = f"# {title}\n\n{introduction}\n\n{body}\n"
    rendered = f"<h2>{title}</h2>\n<p>{introduction}</p>\n" + render_html(body)
    if previous:
        comparison = f"https://github.com/{repo}/compare/v{previous}...v{version}"
        markdown += f"\n[Full changelog]({comparison})\n"
        rendered += f'\n<p><a href="{comparison}">Full changelog</a></p>'
    output.mkdir(parents=True, exist_ok=True)
    (output / "release-notes.md").write_text(markdown, encoding="utf-8")
    (output / "release-notes.html").write_text(rendered + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--repo", default="team-sviluppo/SwarmeBot")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(args.root, args.version, args.repo, args.output_dir)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
