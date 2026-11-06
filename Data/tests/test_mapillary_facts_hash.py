"""BE-17: Mapillary search and selection (coverage tiles, facing rule) and the stable facts hash
with its re-key migration. Standard library only.

    python3 -m unittest discover -s Data/tests -t Data
"""
import gzip
import json
import math
import struct
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import hooks  # noqa: E402
import photos  # noqa: E402
import run_nightly  # noqa: E402
import website  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"


def fixture(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


# ---- A minimal Mapbox Vector Tile encoder, to build tile fixtures ------------------------------

def _varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _field(num, wire, payload):
    key = _varint(num << 3 | wire)
    if wire == 0:
        return key + _varint(payload)
    return key + _varint(len(payload)) + payload  # wire 2


def _zz(n):
    return (n << 1) ^ (n >> 63)


def encode_tile(images, z, x, y, extent=4096, layer="image"):
    keys, values, feats = [], [], b""
    def value_index(v):
        if isinstance(v, bool):
            enc = _field(7, 0, int(v))
        elif isinstance(v, float):
            enc = b"\x19" + struct.pack("<d", v)  # field 3, wire 1
        else:
            enc = _field(5, 0, v)
        values.append(enc)
        return len(values) - 1
    for img in images:
        lon, lat = img["geometry"]["coordinates"]
        n = 2 ** z
        fx = (lon + 180) / 360 * n
        fy = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
        px, py = round((fx - x) * extent), round((fy - y) * extent)
        tags = []
        for k in ("id", "compass_angle", "is_pano", "captured_at"):
            if k not in keys:
                keys.append(k)
            v = int(img[k]) if k == "id" else img[k]
            tags += [keys.index(k), value_index(v)]
        geom = [1 | (1 << 3), _zz(px), _zz(py)]
        feat = _field(2, 2, b"".join(_varint(t) for t in tags)) + _field(3, 0, 1) \
            + _field(4, 2, b"".join(_varint(g) for g in geom))
        feats += _field(2, 2, feat)
    body = _field(15, 0, 2) + _field(1, 2, layer.encode()) + feats \
        + b"".join(_field(3, 2, k.encode()) for k in keys) + b"".join(_field(4, 2, v) for v in values) \
        + _field(5, 0, extent)
    return _field(3, 2, _field(1, 2, b"sequence") + _field(15, 0, 2)) + _field(3, 2, body)


class TileTests(unittest.TestCase):
    def test_decode_round_trip(self):
        scene = fixture("mapillary_street.json")
        imgs = scene["images"][:5]
        z = photos.TILE_ZOOM
        x, y = photos.tile_xy(scene["place"]["lat"], scene["place"]["lon"])
        data = encode_tile(imgs, z, x, y)
        for raw in (data, gzip.compress(data)):
            got = photos.tile_images(raw, z, x, y)
            self.assertEqual([g["id"] for g in got], [i["id"] for i in imgs])
            for g, i in zip(got, imgs):
                (glon, glat), (ilon, ilat) = g["geometry"]["coordinates"], i["geometry"]["coordinates"]
                self.assertLess(photos.metres(glat, glon, ilat, ilon), 1.0)  # tile resolution ~0.35 m
                self.assertEqual(g["compass_angle"], i["compass_angle"])
                self.assertEqual(g["is_pano"], i["is_pano"])
                self.assertTrue(g["from_tile"])

    def test_tiles_around_covers_the_radius(self):
        lat, lon = 54.68170, 25.28720
        ts = photos.tiles_around(lat, lon)
        self.assertIn((photos.TILE_ZOOM, *photos.tile_xy(lat, lon)), ts)
        # A place right on a tile edge needs the neighbour too.
        x, y = photos.tile_xy(lat, lon)
        edge_lon, _ = photos.tile_lonlat(photos.TILE_ZOOM, x + 1, y)
        self.assertEqual(len({t[1] for t in photos.tiles_around(lat, edge_lon - 1e-7)}), 2)


class SelectionTests(unittest.TestCase):
    def test_angle_wraps_around_north(self):
        self.assertEqual(photos.angle_diff(355, 5), 10)
        self.assertEqual(photos.angle_diff(5, 355), 10)
        self.assertEqual(photos.angle_diff(90, 270), 180)
        lat, lon = 54.68, 25.28
        south = (lat - 0.0002, lon)  # 22 m south: the place is due north (bearing 0)
        img = {"id": 1, "compass_angle": 350.0, "geometry": {"coordinates": [south[1], south[0]]}}
        a = photos.assess(lat, lon, img)
        self.assertAlmostEqual(a["diff"], 10, delta=0.5)
        self.assertEqual(a["verdict"], "ok")

    def test_tolerance_shrinks_with_distance(self):
        tol = [photos.facing_tolerance(d) for d in (5, 10, 20, 40, 60)]
        self.assertEqual(tol, sorted(tol, reverse=True))
        self.assertEqual(tol[0], photos.MAX_FACING_DEG)
        self.assertAlmostEqual(photos.facing_tolerance(40), 46.3, delta=0.2)

    def test_street_scene_picks_an_image_that_shows_the_place(self):
        scene = fixture("mapillary_street.json")
        lat, lon = scene["place"]["lat"], scene["place"]["lon"]
        rows = photos.mapillary_ranked(lat, lon, scene["images"])
        self.assertTrue(rows)
        best = rows[0]
        self.assertFalse(best["img"]["is_pano"])
        self.assertLessEqual(best["diff"], best["tol"])
        self.assertLess(best["d"], 30)
        # The camera beside the place points along the street (~90° off): not in frame.
        beside = next(i for i in scene["images"] if i["x_m"] == 0 and not i["is_pano"])
        self.assertEqual(photos.assess(lat, lon, beside)["verdict"], "faces away")
        # Every eastbound image that passes is west of the place, every westbound one east of it.
        for r in rows:
            self.assertEqual(r["img"]["sequence"] == "east", r["img"]["x_m"] < 0)
        verdicts = {photos.assess(lat, lon, i)["verdict"] for i in scene["images"] if i["is_pano"]}
        self.assertEqual(verdicts, {"panorama"})  # in range and containing every direction, never published

    def test_far_close_and_pano_rules(self):
        lat, lon = 54.68, 25.28
        def at(dn, compass=0.0, **kw):
            return {"id": dn, "compass_angle": compass, "geometry": {"coordinates": [lon, lat - dn / 111_320]}, **kw}
        self.assertEqual(photos.assess(lat, lon, at(70))["verdict"], "too far")
        self.assertEqual(photos.assess(lat, lon, at(2))["verdict"], "too close (bearing unreliable)")
        self.assertEqual(photos.assess(lat, lon, at(20, is_pano=True))["verdict"], "panorama")
        self.assertEqual(photos.assess(lat, lon, at(20, compass=None))["verdict"], "no compass")
        # Centrality beats a little distance: dead-on at 30 m wins over 45° off at 15 m.
        best, _ = photos.mapillary_pick(lat, lon, [at(15, compass=45.0), at(30)])
        self.assertEqual(best["id"], 30)


class FetchTests(unittest.TestCase):
    def place(self, **kw):
        p = {"id": "osm:node:5", "name": "Kavinė", "lat": 54.68170, "lon": 25.28720, "category": "food",
             "tags": {}}
        p.update(kw)
        return p

    def test_bbox_fallback_without_thumbnails_looks_up_by_id(self):
        """The old search results carry no thumbnail and a null computed compass: the old pick skipped
        every such image. Now the best ones are looked up by id and checked on corrected values."""
        bbox, by_id = fixture("mapillary_bbox.json"), fixture("mapillary_images_by_id.json")
        calls = []
        def get(path, params, token):
            calls.append(path)
            return bbox if path == "images" else by_id.get(path, {"id": path})
        stats = {}
        with mock.patch.object(photos, "mapillary_get", side_effect=get):
            cand = photos.fetch_mapillary(self.place(), "tok", None, stats)
        self.assertEqual(cand["id"], "2002")
        self.assertEqual(cand["credit"], "vilniusmapper / Mapillary")
        self.assertEqual(cand["expires"], 0x6A000000)
        self.assertEqual(calls[0], "images")
        self.assertEqual(stats["picked"], 1)
        self.assertEqual(stats["searched with the Graph API (tile failed)"], 1)

    def test_tile_candidate_rejected_on_corrected_compass(self):
        scene = fixture("mapillary_street.json")
        good = photos.mapillary_ranked(scene["place"]["lat"], scene["place"]["lon"], scene["images"])
        first, second = good[0]["img"], good[1]["img"]
        tile_imgs = [{**i, "from_tile": True} for i in scene["images"]]
        def get(path, params, token):
            base = {"id": path, "thumb_1024_url": f"https://x/{path}.jpg?oe=6A000000"}
            if path == first["id"]:
                return {**base, "computed_compass_angle": (first["compass_angle"] + 180) % 360}
            return {**base, "computed_compass_angle": next(i for i in scene["images"] if i["id"] == path)["compass_angle"]}
        stats = {}
        with mock.patch.object(photos, "mapillary_get", side_effect=get):
            cand = photos.fetch_mapillary(self.place(), "tok", tile_imgs, stats)
        self.assertEqual(cand["id"], second["id"])
        self.assertNotIn("from_tile", cand)
        self.assertEqual(stats["rejected on corrected position/compass or no thumbnail"], 1)

    def test_run_researches_old_rules_and_writes_diagnostics(self):
        scene = fixture("mapillary_street.json")
        p = {**self.place(), "commons_file": None, "commons_cat": None, "site_url": None, "type": "cafe"}
        z = photos.TILE_ZOOM
        def tile(t, token):
            return photos.tile_images(encode_tile(scene["images"], *t), *t)
        data = {"places": {}, "commons_files": {}, "commons_categories": {}, "images": {},
                "mapillary": {f"{p['id']}@{p['lat']:.6f},{p['lon']:.6f},": {"checked": "2026-11-06", "photo": None}}}
        ctx = types.SimpleNamespace(slug="test", pois=[p])
        def get(path, params, token):
            if path == "images":
                return {"data": []}
            img = next(i for i in scene["images"] if i["id"] == path)
            return {"id": path, "thumb_1024_url": f"https://x/{path}.jpg?oe=7A000000",
                    "computed_compass_angle": img["compass_angle"]}
        with tempfile.TemporaryDirectory() as tmp:
            summary = Path(tmp) / "summary.md"
            with mock.patch.object(photos, "load", return_value=data), \
                    mock.patch.object(photos, "save"), \
                    mock.patch.object(website, "refresh", return_value={}), \
                    mock.patch.object(photos, "fetch_tile", side_effect=tile), \
                    mock.patch.object(photos, "mapillary_get", side_effect=get), \
                    mock.patch.dict("os.environ", {"GITHUB_STEP_SUMMARY": str(summary)}):
                import datetime
                counts, note = photos.run(ctx, 30, "secret-token", today=datetime.date(2026, 11, 7), diagnose=1)
            report = summary.read_text()
        self.assertEqual(counts, {"food": {"mapillary": 1}})
        entry = next(iter(data["mapillary"].values()))
        self.assertEqual(entry["rules"], photos.MAPILLARY_RULES)  # the old null result was searched again
        self.assertIsNotNone(entry["photo"])
        self.assertIn("## Mapillary diagnostics (1 places)", report)
        self.assertIn("| id | dist m | compass |", report)
        self.assertIn("Graph API bbox search: 0 images returned", report)
        self.assertNotIn("secret-token", report)
        self.assertEqual(z, 14)

    def test_diagnose_default_only_on_branch_dispatch(self):
        f = run_nightly.default_diagnose
        self.assertEqual(f({}), 0)
        self.assertEqual(f({"GITHUB_EVENT_NAME": "schedule", "GITHUB_REF_NAME": "main"}), 0)
        self.assertEqual(f({"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF_NAME": "main"}), 0)
        self.assertEqual(f({"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF_NAME": "data/x"}),
                         run_nightly.DIAGNOSE_ON_BRANCH)


# ---- Facts hash ----------------------------------------------------------------------------

def bundle(**kw):
    f = {"name": "Exo", "city": "Vilnius", "category": "food and drink", "kind": "Café", "type": "cafe",
         "cuisine": ["coffee shop", "cake"], "osm": {"outdoor_seating": "yes"}, "website": "exo.lt",
         "wikipedia": "Exo is a café in Vilnius. It opened in 2015.",
         "website_title": "Exo — roastery", "website_description": "We roast beans daily."}
    f.update(kw)
    return {k: v for k, v in f.items() if v is not None}


class FactsHashTests(unittest.TestCase):
    def test_volatile_changes_keep_the_hash(self):
        h = hooks.facts_hash(bundle())
        for change in (
            {"website_title": None, "website_description": None},          # fetch failed / bot wall
            {"website_description": "Mes skrudiname pupeles kasdien."},    # another language from a CI IP
            {"website_title": "Exo | Home"},                               # marketing copy rewritten
            {"name": "  EXO "},                                            # case and spacing
            {"cuisine": ["cake", "coffee shop"]},                          # order
            {"wikipedia": "Exo is a café in  Vilnius; it opened in 2015"},  # punctuation and spacing edit
            {"wikipedia": "Exo is a café in Vilnius. It opened in 2015."},  # Unicode normal form
        ):
            self.assertEqual(hooks.facts_hash(bundle(**change)), h, change)

    def test_real_changes_change_the_hash(self):
        h = hooks.facts_hash(bundle())
        for change in (
            {"wikipedia": "Exo is a café in Vilnius. It opened in 2016."},
            {"osm": {"outdoor_seating": "no"}},
            {"kind": "Bar"},
            {"cuisine": ["coffee shop"]},
            {"website": "exo-coffee.lt"},
            {"name": "Exo Coffee"},
            {"overture_category": "coffee shop"},
        ):
            self.assertNotEqual(hooks.facts_hash(bundle(**change)), h, change)

    def test_landmark_wording_from_sitelinks_does_not_count(self):
        self.assertEqual(hooks.facts_hash(bundle(kind="Landmark")), hooks.facts_hash(bundle(kind="Well-known landmark")))

    def test_website_domain_in_bundle_scheme_and_www_insensitive(self):
        from test_hooks_photos import place
        a = hooks.facts(place(site_url="http://www.exo.lt/"), "Vilnius", {})
        b = hooks.facts(place(site_url="https://exo.lt/en"), "Vilnius", {})
        self.assertEqual(a["website"], "exo.lt")
        self.assertEqual(hooks.facts_hash(a), hooks.facts_hash(b))

    def test_platform_listing_is_not_a_website_fact(self):
        from test_hooks_photos import place
        url = "https://tablein.com/lt/restaurant/exo"
        sites = {url: {"status": "ok", "title": "Frank Zappa table reservations | Tablein",
                       "description": "Book a table at Frank Zappa."}}
        f = hooks.facts(place(site_url=url), "Vilnius", sites)
        self.assertNotIn("website_title", f)
        legacy = hooks.facts(place(site_url=url), "Vilnius", sites, legacy=True)
        self.assertIn("website_title", legacy)


class RekeyTests(unittest.TestCase):
    def test_rekey_keeps_hooks_whose_facts_are_unchanged(self):
        now = {"a": bundle(), "b": bundle(name="Bee"), "c": bundle(name="Cee"), "d": bundle(name="Dee")}
        legacy = {k: {kk: vv for kk, vv in v.items() if kk != "website"} for k, v in now.items()}
        legacy["d"] = {**legacy["d"], "website_title": "Dee | Tablein"}  # v1 saw a listing title
        rows = {
            "a": {"id": "a", "facts_hash": hooks._sha16(legacy["a"]), "hook": "One line."},   # v1, unchanged
            "b": {"id": "b", "facts_hash": hooks.facts_hash(now["b"]), "hook": "Two line."},  # already v2
            "c": {"id": "c", "facts_hash": "0" * 16, "hook": "Old facts."},                   # stale: leave
            "d": {"id": "d", "facts_hash": hooks.legacy_facts_hash(legacy["d"]), "hook": None},
            "e": {"id": "e", "facts_hash": "1" * 16, "hook": "Gone."},                        # not a candidate
        }
        out, counts = hooks.rekey_rows(rows, now, legacy)
        self.assertEqual(counts, {"current": 1, "rekeyed": 2, "stale": 1, "not a candidate": 1})
        self.assertEqual(out["a"]["facts_hash"], hooks.facts_hash(now["a"]))
        self.assertEqual(out["d"]["facts_hash"], hooks.facts_hash(now["d"]))
        self.assertEqual(out["c"]["facts_hash"], "0" * 16)
        self.assertEqual(out["e"], rows["e"])
        for k in rows:
            self.assertEqual({x: y for x, y in out[k].items() if x != "facts_hash"},
                             {x: y for x, y in rows[k].items() if x != "facts_hash"})  # no hook rewritten
        again, counts2 = hooks.rekey_rows(out, now, legacy)
        self.assertEqual(again, out)  # idempotent
        self.assertEqual(counts2["rekeyed"], 0)

    def test_rekey_command_writes_a_valid_file(self):
        from test_hooks_photos import place
        p = place()
        legacy = hooks.facts(p, "Vilnius", {}, legacy=True)
        row = {"id": p["id"], "name": p["name"], "facts_hash": hooks.legacy_facts_hash(legacy),
               "hook": "A bust put up here in 1995 by Bogdanas.", "prompt_version": "1",
               "written_by": "unit test", "date": "2026-11-05"}
        ctx = types.SimpleNamespace(pois=[p], city={"name": "Vilnius"})
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "test.jsonl").write_text(json.dumps(row) + "\n")
            with mock.patch.object(hooks, "HOOKS_DIR", Path(tmp)), \
                    mock.patch("score.candidates", return_value=ctx), \
                    mock.patch.object(website, "load_cache", return_value={}):
                hooks.cmd_rekey(types.SimpleNamespace(city="test"))
            rows = hooks.read_jsonl(Path(tmp) / "test.jsonl")
        self.assertEqual(hooks.validate_rows(rows), [])
        self.assertEqual(rows[0][1]["facts_hash"], hooks.facts_hash(hooks.facts(p, "Vilnius", {})))
        self.assertEqual(rows[0][1]["date"], "2026-11-05")


if __name__ == "__main__":
    unittest.main()
