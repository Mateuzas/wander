"""A place's own website: homepage title, meta description and preview image (ADR 015).

Standard library only. Used by photos.py (the `og:image` / `twitter:image` preview photo) and
hooks.py (the title and description are facts for the hook line). Nothing is fetched unless the
site's robots.txt allows our user agent to fetch the homepage. Results are cached per URL in
cache/<city>/websites.json and re-checked after MAX_AGE_DAYS.

    python3 website.py vilnius            # fetch what is missing or old, for every candidate place
"""
import concurrent.futures
import datetime
import html
import html.parser
import json
import re
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser

from common import USER_AGENT, cache_dir

MAX_AGE_DAYS = 30
TIMEOUT = 15
MAX_HTML_BYTES = 400_000
IMAGE_PROBE_BYTES = 65_536
WORKERS = 12
# Not the place's own site: a profile or listing on someone else's platform. Their titles and
# preview images describe the platform (or are blocked by robots.txt anyway).
NOT_OWN_DOMAINS = {
    "facebook.com", "fb.com", "instagram.com", "linktr.ee", "treatwell.lt", "treatwell.com",
    "tripadvisor.com", "tripadvisor.lt", "google.com", "goo.gl", "wolt.com", "bolt.eu", "foodout.lt",
    "booking.com", "youtube.com", "tiktok.com", "x.com", "twitter.com", "vilnius-tourism.lt",
    "govilnius.lt", "lt.wikipedia.org", "en.wikipedia.org", "wikipedia.org", "pages.dev", "business.site",
    "tablein.com", "greet.menu", "paysera.com", "rekvizitai.vz.lt", "kvr.kpd.lt", "msz.gov.pl",
}
CITY_WORDS = {"vilnius", "vilniaus", "vilniuje", "vilna", "wilno", "lithuania", "lietuva", "lietuvos"}
# Expired domains get bought for spam; a place's site never talks about casinos or loans.
SPAM = re.compile(r"kazino|casino|lažyb|lazyb|betting|slots?\b|poker|paskol|loans?\b|viagra|porn|escort", re.I)
JUNK_TITLE = re.compile(r"^(\W*|404.*|not found|page not found|home|homepage|index|pradinis puslapis|titulinis|"
                        r"pradžia|untitled|coming soon|under construction)$", re.I)


def domain(url):
    host = (urllib.parse.urlsplit(url or "").hostname or "").lower()
    return host[4:] if host.startswith("www.") else host


def is_own_site(url):
    d = domain(url)
    return bool(d) and not any(d == x or d.endswith("." + x) for x in NOT_OWN_DOMAINS)


def _compact(text):
    import unicodedata
    text = "".join(c for c in unicodedata.normalize("NFKD", (text or "").casefold()) if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]", "", text)


def about_place(entry, url, names):
    """True when a fetched homepage is plausibly the place's own: no spam words, and one of the
    place's distinctive name words (or most of it, for inflected Lithuanian) appears in the domain,
    title or description. Names with no distinctive word ("Bistro 18") pass. Wrong websites in
    OSM/Overture (another business, a hotel group, an expired domain) are common: their titles and
    images must not describe the place."""
    from overture import norm_name  # local: overture.py needs nothing from here
    text = f"{entry.get('title') or ''} {entry.get('description') or ''}"
    if SPAM.search(text):
        return False
    tokens = {t for n in names if n for t in norm_name(n).split() if len(t) >= 3 and t not in CITY_WORDS}
    if not tokens:
        return True
    hay = _compact(domain(url)) + _compact(text)
    return any(t[:max(4, len(t) - 2)] in hay for t in tokens)


def page_facts(entry, url, names):
    """(title, description) of a homepage that is about the place, junk titles dropped; else (None, None)."""
    if not entry or entry.get("status") != "ok" or not about_place(entry, url, names):
        return None, None
    title = entry.get("title")
    if title and (JUNK_TITLE.match(title.strip()) or len(_compact(title)) < 3):
        title = None
    return title, entry.get("description")


def cache_path(slug):
    return cache_dir(slug) / "websites.json"


def load_cache(slug):
    path = cache_path(slug)
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}


def save_cache(slug, cache):
    cache_path(slug).write_text(json.dumps(cache, ensure_ascii=False, sort_keys=True, indent=0), encoding="utf-8")


def _get(url, max_bytes, headers=None):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.geturl(), resp.headers, resp.read(max_bytes)


_robots = {}


def allowed(url):
    """True when robots.txt lets our user agent fetch `url`. A missing robots.txt allows all;
    401/403 forbids all (as urllib.robotparser does); an unreachable one forbids (be polite)."""
    parts = urllib.parse.urlsplit(url)
    root = f"{parts.scheme}://{parts.netloc}"
    if root not in _robots:
        rp = urllib.robotparser.RobotFileParser()
        try:
            _, _, body = _get(root + "/robots.txt", 200_000)
            rp.parse(body.decode("utf-8", "replace").splitlines())
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                rp.disallow_all = True
            else:
                rp.allow_all = True
        except Exception:
            rp.disallow_all = True
        _robots[root] = rp
    return _robots[root].can_fetch(USER_AGENT, url)


class _Head(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title, self.meta, self._in_title = "", {}, False

    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v or "") for k, v in attrs}
        if tag == "title":
            self._in_title = True
        elif tag == "meta":
            key = (a.get("property") or a.get("name") or "").strip().lower()
            if key and "content" in a and key not in self.meta:
                self.meta[key] = a["content"].strip()

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._in_title and len(self.title) < 500:
            self.title += data


def clean_text(text, limit=300):
    text = " ".join(html.unescape(text or "").split())
    return text[:limit].rstrip() if text else None


def _charset(headers, raw):
    m = re.search(r"charset=([\w-]+)", headers.get("Content-Type", ""), re.I) \
        or re.search(rb"<meta[^>]+charset=[\"']?([\w-]+)", raw[:4000], re.I)
    name = m.group(1) if m else "utf-8"
    return name.decode() if isinstance(name, bytes) else name


def fetch(url, today):
    """One cache entry for a homepage: {checked, status, title?, description?, images?}."""
    entry = {"checked": today}
    if not is_own_site(url):
        return {**entry, "status": "not own site"}
    if not url.startswith(("http://", "https://")):
        return {**entry, "status": "bad url"}
    try:
        if not allowed(url):
            return {**entry, "status": "robots"}
        final, headers, raw = _get(url, MAX_HTML_BYTES)
        if "html" not in headers.get("Content-Type", "html"):
            return {**entry, "status": "not html"}
        if final != url and not allowed(final):
            return {**entry, "status": "robots"}
        try:
            text = raw.decode(_charset(headers, raw), "replace")
        except LookupError:
            text = raw.decode("utf-8", "replace")
        head = _Head()
        head.feed(text)
    except Exception as exc:  # network, TLS, HTTP errors: try again after MAX_AGE_DAYS
        return {**entry, "status": f"error: {type(exc).__name__}"}
    entry["status"] = "ok"
    title = clean_text(head.title, 200) or clean_text(head.meta.get("og:title"), 200)
    desc = clean_text(head.meta.get("description")) or clean_text(head.meta.get("og:description"))
    if title:
        entry["title"] = title
    if desc:
        entry["description"] = desc
    images = []
    for key in ("og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"):
        if head.meta.get(key):
            img = urllib.parse.urljoin(final, html.unescape(head.meta[key]).strip())
            if img.startswith("http://"):
                img = "https://" + img[len("http://"):]  # the schema wants https; probe_image checks it works
            if img not in images:
                images.append(img)
    if images:
        entry["images"] = images
    return entry


def image_size(data):
    """(width, height) from the first bytes of a PNG, GIF, JPEG or WebP, or None."""
    if data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) >= 24:
        return struct.unpack(">II", data[16:24])
    if data[:6] in (b"GIF87a", b"GIF89a") and len(data) >= 10:
        return struct.unpack("<HH", data[6:10])
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP" and len(data) >= 30:
        chunk = data[12:16]
        if chunk == b"VP8 ":
            w, h = struct.unpack("<HH", data[26:30])
            return w & 0x3FFF, h & 0x3FFF
        if chunk == b"VP8L":
            b = data[21:25]
            w = 1 + (((b[1] & 0x3F) << 8) | b[0])
            h = 1 + (((b[3] & 0xF) << 10) | (b[2] << 2) | ((b[1] & 0xC0) >> 6))
            return w, h
        if chunk == b"VP8X":
            return 1 + int.from_bytes(data[24:27], "little"), 1 + int.from_bytes(data[27:30], "little")
    if data[:2] == b"\xff\xd8":
        i = 2
        while i + 9 <= len(data):
            if data[i] != 0xFF:
                i += 1
                continue
            marker = data[i + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            length = struct.unpack(">H", data[i + 2:i + 4])[0]
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", data[i + 5:i + 9])
                return w, h
            i += 2 + length
    return None


def probe_image(url):
    """{ok, width?, height?, type?} for an image URL, reading only its first bytes (a range GET),
    where robots.txt allows it."""
    if not url.startswith("https://") or url.lower().split("?")[0].endswith(".svg"):
        return {"ok": False, "why": "svg or not https"}
    try:
        if not allowed(url):
            return {"ok": False, "why": "robots"}
        _, headers, data = _get(url, IMAGE_PROBE_BYTES, {"Range": f"bytes=0-{IMAGE_PROBE_BYTES - 1}"})
    except Exception as exc:
        return {"ok": False, "why": f"error: {type(exc).__name__}"}
    ctype = headers.get("Content-Type", "").split(";")[0].strip().lower()
    if ctype and not ctype.startswith("image/"):
        return {"ok": False, "why": f"type {ctype}"}
    if "svg" in ctype:
        return {"ok": False, "why": "svg"}
    out = {"ok": True, "type": ctype or None}
    size = image_size(data)
    if size:
        out["width"], out["height"] = size
    return out


def refresh(slug, urls, cache=None, max_age_days=MAX_AGE_DAYS):
    """Fetch every URL that is missing or older than max_age_days; returns the updated cache."""
    cache = load_cache(slug) if cache is None else cache
    today = datetime.date.today()
    limit = (today - datetime.timedelta(days=max_age_days)).isoformat()
    todo = sorted({u for u in urls if u and (u not in cache or cache[u].get("checked", "") < limit)})
    if todo:
        print(f"  websites: fetching {len(todo)} homepages ({len(cache)} cached)", flush=True)
        with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
            for url, entry in zip(todo, pool.map(lambda u: fetch(u, today.isoformat()), todo)):
                cache[url] = entry
        save_cache(slug, cache)
    return cache


def main():
    import score
    slug = sys.argv[1] if len(sys.argv) > 1 else sys.exit("usage: website.py <city>")
    ctx = score.candidates(slug)
    cache = refresh(slug, [p["site_url"] for p in ctx.pois])
    statuses = {}
    for p in ctx.pois:
        url = p["site_url"]
        if url:
            s = cache.get(url, {}).get("status", "missing").split(":")[0]
            statuses[s] = statuses.get(s, 0) + 1
    print(f"  websites for {len(ctx.pois)} places: {statuses}")


if __name__ == "__main__":
    main()
