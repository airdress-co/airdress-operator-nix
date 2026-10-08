"""Tests for check-conventional-commit.py (run: python3 -m unittest)."""

import importlib.util
import pathlib
import tempfile
import unittest

_PATH = pathlib.Path(__file__).with_name("check-conventional-commit.py")
_spec = importlib.util.spec_from_file_location("ccc", _PATH)
ccc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ccc)


class Accepts(unittest.TestCase):
    def test_conventional_headers(self):
        for msg in [
            "feat: a thing",
            "fix(pyinfra): render the wake block",
            "docs(runbooks): record the review verdict",
            "deps(cargo): bump serde",
            "chore(release): v0.1.124",
            "feat(api)!: drop the v1 route",
            "refactor(chat/envelopes): one delivery path",
            "feat(federation): admit peers\n\nBody explains why.\n",
        ]:
            with self.subTest(msg=msg):
                self.assertIsNone(ccc.check(msg))

    def test_tool_written_messages_are_exempt(self):
        for msg in [
            "Merge pull request #401 from airdress-co/fix/federation-meets-wake",
            "Merge remote-tracking branch 'origin/main' into feat/x",
            'Revert "feat: a thing"',
            "fixup! feat: a thing",
            "squash! fix: b",
            "amend! docs: c",
        ]:
            with self.subTest(msg=msg):
                self.assertIsNone(ccc.check(msg))

    def test_comments_and_scissors_are_ignored(self):
        msg = (
            "# Please enter the commit message\n"
            "fix: the real header\n"
            "# a comment\n"
            "# ------------------------ >8 ------------------------\n"
            "diff --git a/x b/x\n"
        )
        self.assertIsNone(ccc.check(msg))

    def test_empty_message_is_left_to_git(self):
        self.assertIsNone(ccc.check("# only comments\n\n"))


class Refuses(unittest.TestCase):
    def test_area_prefix_is_not_a_type(self):
        self.assertIn("not a commit type", ccc.check("pyinfra: pin VM3"))

    def test_no_colon_space(self):
        self.assertIn("not `type(scope): subject`", ccc.check("feat add a thing"))
        self.assertIn("not `type(scope): subject`", ccc.check("feat:no space"))

    def test_uppercase_type(self):
        self.assertIn("not `type(scope): subject`", ccc.check("Feat: a thing"))

    def test_ticket_prefix_alone(self):
        self.assertIn("not `type(scope): subject`", ccc.check("PROJ-12: rulings"))

    def test_empty_subject_or_scope(self):
        self.assertIn("not `type(scope): subject`", ccc.check("fix: "))
        self.assertIn("not `type(scope): subject`", ccc.check("fix(): x"))

    def test_long_header(self):
        self.assertIn("characters", ccc.check("feat: " + "x" * 120))

    def test_body_needs_blank_line(self):
        self.assertIn("blank line", ccc.check("fix: x\nbody right away"))


class Main(unittest.TestCase):
    def _run(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write(text)
        return ccc.main(["x", f.name])

    def test_exit_codes(self):
        self.assertEqual(self._run("fix: ok\n"), 0)
        self.assertEqual(self._run("nope\n"), 1)
        self.assertEqual(ccc.main(["x"]), 2)


if __name__ == "__main__":
    unittest.main()
