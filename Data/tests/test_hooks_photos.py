"""Unit tests for the hook and photo steps and the gate (ADR 015). Standard library only.

    python3 -m unittest discover -s Data/tests -t Data
"""
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import hooks  # noqa: E402
import photos  # noqa: E402
import publish_gate  # noqa: E402
import score  # noqa: E402
import website  # noqa: E402


def place(**kw):
    p = {"id": "osm:node:1", "name": "Frank Zappa", "original_name": "Frank Zappa", "lat": 54.683, "lon": 25.2759,
         "category": "photo", "type": "bust", "reason": "Bust, well-known landmark, popular photo spot",
         "tags": {"artist_name": "Konstantinas Bogdanas", "start_date": "1995", "historic": "memorial",
                  "tourism": "attraction", "wikidata": "Q1"},
         "wikidata_label_en": "Frank Zappa memorial", "wiki_summary": None,
         "commons_file": None, "commons_cat": None, "site_url": None, "score": 60}
    p.update(kw)
    return p


class FactsTests(unittest.TestCase):
    def test_bundle_holds_only_our_facts(self):
        f = hooks.facts(place(), "Vilnius", {})
        self.assertEqual(f["kind"], "Bust")  # score-derived extras are not facts
        self.assertEqual(f["osm"], {"artist_name": "Konstantinas Bogdanas", "start_date": "1995",
                                    "historic": "memorial"})
        self.assertEqual(f["wikidata_label"], "Frank Zappa memorial")
        self.assertNotIn("score", f)
        self.assertNotIn("wikipedia", f)

    def test_website_and_wikipedia_and_overture(self):
        p = place(category="food", type="cafe", reason="Café", tags={"amenity": "cafe", "cuisine": "coffee_shop;cake"},
                  site_url="https://ex.lt/", ovt_category="coffee_shop",
                  wiki_summary={"extract": "First sentence here. Second one too."})
        p["name"] = "Exo"
        sites = {"https://ex.lt/": {"status": "ok", "title": "Exo — roastery", "description": "We roast beans."}}
        f = hooks.facts(p, "Vilnius", sites)
        self.assertEqual(f["category"], "food and drink")
        self.assertEqual(f["cuisine"], ["coffee shop", "cake"])
        self.assertEqual(f["website_title"], "Exo — roastery")
        self.assertEqual(f["website_description"], "We roast beans.")
        self.assertEqual(f["overture_category"], "coffee shop")
        self.assertEqual(f["wikipedia"], "First sentence here. Second one too.")
        blocked = {"https://ex.lt/": {"status": "robots"}}
        self.assertNotIn("website_title", hooks.facts(p, "Vilnius", blocked))

    def test_wikipedia_cut_at_sentence_end(self):
        long = " ".join(f"Sentence number {i} is here." for i in range(100))
        w = hooks.wiki_fact({"extract": long})
        self.assertLessEqual(len(w), hooks.WIKI_FACT_CHARS)
        self.assertTrue(w.endswith("."))

    def test_hash_is_stable_and_sensitive(self):
        a = hooks.facts(place(), "Vilnius", {})
        b = dict(reversed(list(a.items())))
        self.assertEqual(hooks.facts_hash(a), hooks.facts_hash(b))
        self.assertRegex(hooks.facts_hash(a), r"^[0-9a-f]{16}$")
        c = hooks.facts(place(tags={"artist_name": "Someone Else"}), "Vilnius", {})
        self.assertNotEqual(hooks.facts_hash(a), hooks.facts_hash(c))


class PromptTests(unittest.TestCase):
    def test_prompt_comes_from_writing_md(self):
        prompt = hooks.system_prompt()
        self.assertIn("at most 80 characters", prompt)
        self.assertIn("null", prompt)
        self.assertIn("use only the facts given", prompt)
        self.assertTrue(hooks.prompt_version())

    def test_request_params(self):
        b = {"id": "x", "name": "X", "facts_hash": "0" * 16, "facts": {"name": "X", "kind": "Bar"}}
        params = hooks.request_params(b, "low", "SYS")
        self.assertEqual(params["model"], hooks.MODEL)
        self.assertEqual(params["system"], "SYS")
        self.assertEqual(params["output_config"]["effort"], "low")
        self.assertEqual(params["output_config"]["format"]["type"], "json_schema")
        self.assertEqual(params["output_config"]["format"]["schema"]["required"], ["hook"])
        self.assertNotIn("thinking", params)
        self.assertIn('"kind": "Bar"', params["messages"][0]["content"])


class ValidationTests(unittest.TestCase):
    def test_good(self):
        self.assertIsNone(hooks.problem("A bust by sculptor Konstantinas Bogdanas, put up here in 1995.", "Frank Zappa"))
        self.assertIsNone(hooks.problem("1920s tiles line the old pharmacy counter.", "X"))

    def test_bad(self):
        cases = {
            "X" * 80 + ".": "characters",
            "Short.": "characters",
            "no capital at the start here.": "capital",
            "No full stop at the end": "full stop",
            "A fine place! Really.": "exclamation",
            "First sentence here. Second sentence here.": "more than one sentence",
            "Coffee roasted on site ☕.": "emoji",
            "The best dumplings in the Old Town.": "banned word",
            "A hidden gem behind the cathedral.": "banned word",
            "Frank Zappa's only statue in the world.": "own name",
            " Leading space here, that is.": "whitespace",
        }
        for hook, why in cases.items():
            with self.subTest(hook=hook):
                self.assertIn(why, hooks.problem(hook, "Frank Zappa") or "")
        self.assertIsNotNone(hooks.problem(None))

    def test_validate_rows(self):
        good = {"id": "a", "facts_hash": "0123456789abcdef", "hook": None, "prompt_version": "1",
                "written_by": "t", "date": "2026-11-06"}
        rows = [(1, good), (2, dict(good)), (3, {**good, "id": "b", "hook": "Amazing views over the river."}),
                (4, {**good, "id": "c", "facts_hash": "xyz"}), (5, {"id": "d"}), (6, ValueError("bad"))]
        msgs = dict(hooks.validate_rows(rows))
        self.assertNotIn(1, msgs)
        self.assertIn("duplicate", msgs[2])
        self.assertIn("banned", msgs[3])
        self.assertIn("facts_hash", msgs[4])
        self.assertIn("missing", msgs[5])
        self.assertIn("JSON", msgs[6])


class FakeMessage:
    def __init__(self, text=None, stop_reason="end_turn"):
        self.stop_reason = stop_reason
        self.content = [types.SimpleNamespace(type="thinking", thinking="")]
        if text is not None:
            self.content.append(types.SimpleNamespace(type="text", text=text))


class FakeErrors:
    class APIError(Exception):
        message = "x"

    class APIStatusError(APIError):
        status_code = 500

    class BadRequestError(APIStatusError):
        status_code = 400

    class AuthenticationError(APIStatusError):
        pass

    class PermissionDeniedError(APIStatusError):
        pass

    class NotFoundError(APIStatusError):
        pass

    class RateLimitError(APIStatusError):
        pass

    class APIConnectionError(APIError):
        pass


class FakeClient:
    def __init__(self, reply):
        self.calls = []
        self.messages = types.SimpleNamespace(create=self._create)
        self.reply = reply

    def _create(self, **params):
        self.calls.append(params)
        if isinstance(self.reply, Exception):
            raise self.reply
        return self.reply


class ClientTests(unittest.TestCase):
    bundle = {"id": "x", "name": "Frank Zappa", "facts_hash": "0" * 16, "facts": {"name": "Frank Zappa"}}

    def call(self, reply):
        client = FakeClient(reply)
        out = hooks.call_one(FakeErrors, client, self.bundle, "low", "SYS")
        return out, client

    def test_ok(self):
        (hook, status), client = self.call(FakeMessage('{"hook": "A bust put up here in 1995 by Bogdanas."}'))
        self.assertEqual((hook, status), ("A bust put up here in 1995 by Bogdanas.", "ok"))
        self.assertEqual(client.calls[0]["output_config"]["effort"], "low")

    def test_null_refusal_max_tokens_invalid(self):
        self.assertEqual(self.call(FakeMessage('{"hook": null}'))[0], (None, "null"))
        self.assertEqual(self.call(FakeMessage(None, "refusal"))[0], (None, "refusal"))
        self.assertEqual(self.call(FakeMessage('{"hook": "cut', "max_tokens"))[0], (None, "max_tokens"))
        hook, status = self.call(FakeMessage('{"hook": "The best place in town."}'))[0]
        self.assertIsNone(hook)
        self.assertTrue(status.startswith("invalid: banned word"))
        self.assertEqual(self.call(FakeMessage("not json"))[0], (None, "invalid: not the JSON schema"))

    def test_errors(self):
        self.assertTrue(self.call(FakeErrors.RateLimitError())[0][1].startswith("error: rate"))
        self.assertTrue(self.call(FakeErrors.BadRequestError())[0][1].startswith("error: bad request"))
        self.assertTrue(self.call(FakeErrors.APIConnectionError())[0][1].startswith("error: connection"))
        with self.assertRaises(SystemExit):
            self.call(FakeErrors.AuthenticationError())


class PhotoTests(unittest.TestCase):
    def test_choose_priority(self):
        commons = {"source": "commons"}
        mly = {"source": "mapillary"}
        big = {"source": "website", "width": 1200}
        small = {"source": "website", "width": 600}
        sight, cafe = place(), place(category="food", type="cafe")
        theatre = place(type="theatre")
        self.assertIs(photos.choose(sight, commons, mly, big), commons)
        self.assertIs(photos.choose(sight, None, mly, big), mly)
        self.assertIs(photos.choose(cafe, None, mly, big), big)
        self.assertIs(photos.choose(theatre, None, mly, big), big)
        self.assertIs(photos.choose(cafe, None, mly, small), mly)
        self.assertIs(photos.choose(cafe, None, None, small), small)
        self.assertIs(photos.choose(sight, None, None, small), small)
        self.assertIsNone(photos.choose(sight, None, None, None))

    def test_logo_rules(self):
        self.assertTrue(photos.looks_like_logo("https://a.lt/logo.png", {"width": 1200, "height": 630}))
        self.assertTrue(photos.looks_like_logo("https://a.lt/x.svg", {}))
        self.assertTrue(photos.looks_like_logo("https://a.lt/x.png", {"width": 300, "height": 300}))
        self.assertTrue(photos.looks_like_logo("https://a.lt/x.png", {"width": 200, "height": 100}))
        self.assertFalse(photos.looks_like_logo("https://a.lt/x.jpg", {"width": 500, "height": 500}))
        self.assertFalse(photos.looks_like_logo("https://a.lt/hero.jpg", {"width": 1200, "height": 630}))
        self.assertFalse(photos.looks_like_logo("https://a.lt/hero.jpg", {}))
        self.assertTrue(photos.looks_like_logo("https://a.lt/img/brand/og.jpg", {"width": 1200, "height": 630}))

    def test_shared_website_image_is_skipped(self):
        p = place(category="food", site_url="https://a.lt/")
        entry = {"status": "ok", "title": "Frank Zappa kavinė", "images": ["https://cdn.x/og.png", "https://a.lt/hero.jpg"]}
        probes = {u: {"probe": {"ok": True, "width": 1200, "height": 630}} for u in entry["images"]}
        self.assertEqual(photos.website_candidate(p, entry, probes)["url"], "https://cdn.x/og.png")
        got = photos.website_candidate(p, entry, probes, frozenset({"https://cdn.x/og.png"}))
        self.assertEqual(got["url"], "https://a.lt/hero.jpg")

    def test_mapillary_pick_facing_and_distance(self):
        lat, lon = 54.683, 25.2759
        south = (lat - 0.0002, lon)  # ~22 m south of the place, so facing north (0°) looks at it
        def img(i, pt, compass, **kw):
            return {"id": i, "thumb_1024_url": f"https://x/{i}?oe=6A000000", "compass_angle": compass,
                    "geometry": {"type": "Point", "coordinates": [pt[1], pt[0]]}, **kw}
        far = (lat - 0.0006, lon)  # ~67 m
        images = [img(1, south, 180), img(2, far, 0), img(3, south, 30), img(4, south, 0, is_pano=True)]
        best, d = photos.mapillary_pick(lat, lon, images)
        self.assertEqual(best["id"], 3)
        self.assertLess(d, 40)
        self.assertEqual(photos.mapillary_pick(lat, lon, images[:2]), (None, None))
        cand = photos.mapillary_candidate({**best, "creator": {"username": "alice"}}, d)
        self.assertEqual(cand["page"], "https://www.mapillary.com/app/?pKey=3")
        self.assertEqual(cand["expires"], 0x6A000000)
        self.assertEqual(photos.public(cand).keys(), {"url", "source", "credit", "license", "page"})

    def test_commons_info(self):
        page = {"title": "File:A.jpg", "imageinfo": [{"mime": "image/jpeg", "width": 4000, "height": 3000,
                "url": "https://upload.wikimedia.org/wikipedia/commons/a/ab/A.jpg",
                "descriptionurl": "https://commons.wikimedia.org/wiki/File:A.jpg",
                "extmetadata": {"Artist": {"value": "<a href='x'>Jane &amp; Doe</a>"},
                                "LicenseShortName": {"value": "CC BY-SA 4.0"}}}]}
        c = photos.commons_info(page)
        self.assertEqual(c["credit"], "Jane & Doe")
        self.assertEqual(c["url"], "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/A.jpg/1280px-A.jpg")
        self.assertEqual(c["license"], "CC BY-SA 4.0")
        small = json.loads(json.dumps(page))
        small["imageinfo"][0]["width"] = 640
        self.assertIsNone(photos.commons_info(small))
        svg = json.loads(json.dumps(page))
        svg["imageinfo"][0]["mime"] = "image/svg+xml"
        self.assertIsNone(photos.commons_info(svg))
        maps = [dict(c, title="File:Map of Vilnius.jpg", width=9000, height=6000), dict(c, width=1000, height=1500), c]
        self.assertIs(photos.category_pick(maps), c)

    def test_cache_key_tracks_inputs(self):
        cache = {"places": {}}
        p = place()
        self.assertEqual(photos.photo_for(p, cache), (None, False))
        cache["places"][p["id"]] = {"key": photos.input_key(p), "photo": {"url": "https://u"}}
        self.assertEqual(photos.photo_for(p, cache), ({"url": "https://u"}, True))
        moved = place(lat=54.7)
        self.assertEqual(photos.photo_for(moved, cache), (None, False))
        self.assertNotEqual(photos.input_key(place(commons_file="B.jpg")), photos.input_key(p))

    def test_image_size(self):
        png = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + (1200).to_bytes(4, "big") + (630).to_bytes(4, "big")
        self.assertEqual(website.image_size(png), (1200, 630))
        jpeg = b"\xff\xd8\xff\xe0\x00\x04ab\xff\xc0\x00\x11\x08" + (630).to_bytes(2, "big") + (1200).to_bytes(2, "big")
        self.assertEqual(website.image_size(jpeg), (1200, 630))
        self.assertIsNone(website.image_size(b"junk"))

    def test_about_place(self):
        names = ("La Piazza", "La Piazza")
        self.assertFalse(website.about_place({"title": "laprovence.lt"}, "http://www.laprovence.lt/", names))
        self.assertTrue(website.about_place({"title": "Picerija"}, "https://lapiazza.lt/", names))
        self.assertTrue(website.about_place({"title": "Kas naujo"}, "https://b.lt/", ("Bistro 18",)))
        spam = {"title": "Užsienio Kazino 2026 – 10 Geriausių Svetainių"}
        self.assertFalse(website.about_place(spam, "https://livin.lt/", ("LivIn restoranas",)))
        self.assertTrue(website.about_place({"title": "Evangelikų liuteronų bažnyčia"}, "https://x.lt/",
                                            ("Lutheran Church", "Vilniaus evangelikų liuteronų bažnyčia")))
        self.assertEqual(website.page_facts({"status": "ok", "title": "404", "description": "D"}, "https://lapiazza.lt",
                                            names), (None, "D"))

    def test_own_site(self):
        self.assertTrue(website.is_own_site("https://www.kavine.lt/"))
        self.assertFalse(website.is_own_site("https://m.facebook.com/kavine"))
        self.assertFalse(website.is_own_site("https://www.treatwell.lt/salonas/x"))


class GateTests(unittest.TestCase):
    def ctx(self, pois):
        return types.SimpleNamespace(slug="test", city={"name": "Vilnius"}, pois=pois)

    def run_gate(self, pois, hook_rows, photo_places):
        cache = {"places": photo_places}
        with mock.patch.object(hooks, "load", return_value=hook_rows), \
                mock.patch.object(photos, "load", return_value=cache), \
                mock.patch.object(website, "load_cache", return_value={}):
            return score.gate(self.ctx(pois))

    def test_needs_both_and_current_facts(self):
        a, b, c, d = (place(id=f"osm:node:{i}", name=f"Place {i}") for i in range(4))
        e = place(id="osm:node:9", name="Curated", popular_override=True, hook_override="Hand-written and checked line.")
        rows = {}
        for p in (a, b, d):
            rows[p["id"]] = {"id": p["id"], "facts_hash": hooks.facts_hash(hooks.facts(p, "Vilnius", {})),
                             "hook": "A line that is fine for the card."}
        rows[d["id"]]["facts_hash"] = "0" * 16  # stale: facts changed since it was written
        photo = {"url": "https://u", "source": "commons", "credit": "x"}
        photo_places = {p["id"]: {"key": photos.input_key(p), "photo": photo} for p in (a, c, d, e)}
        kept, report = self.run_gate([a, b, c, d, e], rows, photo_places)
        self.assertEqual([p["id"] for p in kept], [a["id"], e["id"]])
        self.assertEqual(kept[0]["hook_text"], "A line that is fine for the card.")
        self.assertEqual(kept[1]["hook_text"], "Hand-written and checked line.")
        self.assertEqual(report["no_photo"], {"photo": 1})   # b
        self.assertEqual(report["no_hook"], {"photo": 2})    # c, d (stale)
        self.assertEqual(report["stale_hook"], 1)
        self.assertEqual(report["curated_hook"], 1)

    def test_popular_does_not_bypass(self):
        p = place(popular_override=True)
        kept, _ = self.run_gate([p], {}, {})
        self.assertEqual(kept, [])

    def test_bad_curated_hook_is_rejected(self):
        p = place(hook_override="The best spot!")
        kept, report = self.run_gate([p], {}, {p["id"]: {"key": photos.input_key(p), "photo": {"url": "https://u"}}})
        self.assertEqual(kept, [])
        self.assertEqual(len(report["bad_curated_hook"]), 1)

    def test_curation_hook_action(self):
        p = place()
        kept, applied = score.apply_curation([p], {p["id"]: [("hook", "A hand-written line for the card.")]})
        self.assertEqual(kept[0]["hook_override"], "A hand-written line for the card.")


class MergeTests(unittest.TestCase):
    def test_merge_checks_rules_and_hash(self):
        p = place()
        f = hooks.facts(p, "Vilnius", {})
        b = {"id": p["id"], "name": p["name"], "facts_hash": hooks.facts_hash(f), "facts": f}
        with tempfile.TemporaryDirectory() as tmp:
            answers = Path(tmp) / "a.jsonl"
            answers.write_text("\n".join(json.dumps(r) for r in [
                {"id": p["id"], "facts_hash": b["facts_hash"], "hook": "A bust put up here in 1995 by Bogdanas."},
                {"id": "osm:node:404", "facts_hash": "0" * 16, "hook": None},
            ]) + "\n")
            with mock.patch.object(hooks, "bundles", return_value=([b], [b])), \
                    mock.patch.object(hooks, "HOOKS_DIR", Path(tmp)):
                args = types.SimpleNamespace(city="test", answers=str(answers), written_by="unit test")
                status = hooks.cmd_merge(args)
                rows = hooks.read_jsonl(Path(tmp) / "test.jsonl")
        self.assertEqual(status, 1)  # one rejected line
        self.assertEqual(len(rows), 1)
        row = rows[0][1]
        self.assertEqual(row["hook"], "A bust put up here in 1995 by Bogdanas.")
        self.assertEqual(row["prompt_version"], hooks.prompt_version())
        self.assertEqual(hooks.validate_rows(rows), [])


class PublishGateTests(unittest.TestCase):
    def test_allow_shrink(self):
        def doc(n, t1):
            return {"city": "Vilnius", "generated": "x", "pois": [
                {"id": f"p{i}", "category": "food", "tier": 1 if i < t1 else 3} for i in range(n)]}
        with tempfile.TemporaryDirectory() as tmp:
            new, prev = Path(tmp) / "new.json", Path(tmp) / "prev.json"
            new.write_text(json.dumps(doc(10, 1)))
            prev.write_text(json.dumps(doc(100, 5)))
            cur = Path(tmp) / "c.csv"
            cur.write_text("osm_id,action,value\n")
            base = dict(new=str(new), previous=str(prev), curation=str(cur), rerun=None, allow_growth=False)
            with mock.patch.object(publish_gate, "validate", return_value=[]):
                strict, _, _ = publish_gate.run(types.SimpleNamespace(**base, allow_shrink=False))
                loose, _, n = publish_gate.run(types.SimpleNamespace(**base, allow_shrink=True))
                md = publish_gate.markdown(loose, [], n, types.SimpleNamespace(**base, allow_shrink=True))
        self.assertEqual({r[0] for r in strict.failed}, {"Count: food", "Tier 1 kept"})
        self.assertEqual(loose.failed, [])
        self.assertIn("--allow-shrink is on", md)


if __name__ == "__main__":
    unittest.main()
