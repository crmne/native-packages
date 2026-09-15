"""Check links and fragment IDs in a built Jekyll site, without network access."""

import argparse
import json
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit


class Page(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.ids = set()
        self.links = []
        self.feed(source)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        if tag == "a" and "name" in attrs:
            self.ids.add(attrs["name"])
        for key in ("href", "src", "data-url"):
            if attrs.get(key):
                self.links.append(attrs[key])


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
parser.add_argument("--baseurl", default="")
args = parser.parse_args()
root = args.directory.resolve()
baseurl = "/" + args.baseurl.strip("/") if args.baseurl.strip("/") else ""
pages = {path: Page(path.read_text()) for path in root.rglob("*.html")}
errors = []
checked = 0

if not pages:
    raise SystemExit(f"No HTML pages found in {root}")

search = json.loads((root / "search.json").read_text())
if not isinstance(search, list) or not search:
    raise SystemExit("Search index must contain documentation entries")
for entry in search:
    if not all(isinstance(entry.get(key), str) and entry[key] for key in ("title", "url")) or not isinstance(entry.get("content"), str):
        raise SystemExit(f"Invalid search entry: {entry}")
    pages[root / "index.html"].links.append(entry["url"])

for path, page in pages.items():
    page_url = baseurl + "/" + path.relative_to(root).as_posix()
    for link in page.links:
        parsed = urlsplit(link)
        if parsed.scheme or parsed.netloc:
            continue
        resolved = urlsplit(urljoin(page_url, link))
        route = unquote(resolved.path)
        if baseurl and not (route == baseurl or route.startswith(baseurl + "/")):
            errors.append(f"{path.relative_to(root)}: outside baseurl: {link}")
            continue
        target = (root / route[len(baseurl):].lstrip("/")).resolve()
        if not target.is_relative_to(root):
            errors.append(f"{path.relative_to(root)}: outside site: {link}")
            continue
        if target.is_dir():
            target /= "index.html"
        checked += 1
        if not target.is_file():
            errors.append(f"{path.relative_to(root)}: missing file: {link}")
        elif resolved.fragment and target in pages:
            fragment = unquote(resolved.fragment)
            # HTML defines #top as a link to the document top.
            if fragment.lower() != "top" and fragment not in pages[target].ids:
                errors.append(f"{path.relative_to(root)}: missing anchor: {link}")

if errors:
    raise SystemExit("\n".join(sorted(set(errors))))
print(f"Checked {checked} local links and assets across {len(pages)} HTML pages and {len(search)} search entries.")
