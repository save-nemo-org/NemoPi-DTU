"""
Convert a saved mkdocs-material HTML page into a readable markdown extract.

Usage: python tools/mkdocs_to_markdown.py <input.html> <output.md>

Used to populate the readable extract section of agent/*.md mirrors from the
verbatim agent/*.html files. The mkdocs-material chrome (nav, search, TOC, edit
links) is stripped before conversion.
"""
import sys
from pathlib import Path
from bs4 import BeautifulSoup
from markdownify import markdownify

if len(sys.argv) != 3:
    print("usage: mkdocs_to_markdown.py <input.html> <output.md>", file=sys.stderr)
    sys.exit(2)

src = Path(sys.argv[1]).read_text(encoding="utf-8")
soup = BeautifulSoup(src, "html.parser")

article = soup.select_one("article.md-content__inner") or soup.select_one("article")
if article is None:
    print("could not find <article>", file=sys.stderr)
    sys.exit(1)

for sel in (
    "a.md-content__button",       # "edit this page" link
    "nav.md-tags",
    ".md-source-file",
    ".headerlink",
):
    for el in article.select(sel):
        el.decompose()

md = markdownify(str(article), heading_style="ATX", code_language="lua")
Path(sys.argv[2]).write_text(md, encoding="utf-8")
print(f"wrote {sys.argv[2]} ({len(md)} chars)")
