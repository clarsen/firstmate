#!/usr/bin/env python3
import importlib.util
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "bin" / "fm-herdr-resume-config.py"
SPEC = importlib.util.spec_from_file_location("fm_herdr_resume_config", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ComputeNewTextTest(unittest.TestCase):
    def test_no_session_table_appends_one(self):
        original = "onboarding = false\n[remote]\nmanage_ssh_config = false\n"
        new_text = MODULE.compute_new_text(original)
        self.assertTrue(new_text.startswith(original.rstrip("\n") + "\n\n"))
        self.assertIn("[session]\nresume_agents_on_restore = false\n", new_text)

    def test_empty_file_gets_minimal_session_table(self):
        new_text = MODULE.compute_new_text("")
        self.assertEqual(new_text, "[session]\nresume_agents_on_restore = false\n")

    def test_session_table_without_key_inserts_right_after_header(self):
        original = "[session]\nstartup_per_agent_delay_ms = 100\n"
        new_text = MODULE.compute_new_text(original)
        self.assertEqual(
            new_text,
            "[session]\nresume_agents_on_restore = false\nstartup_per_agent_delay_ms = 100\n",
        )

    def test_session_table_with_true_value_is_flipped_in_place(self):
        original = (
            "[session]\nresume_agents_on_restore = true\n"
            "startup_per_agent_delay_ms = 100\n"
        )
        new_text = MODULE.compute_new_text(original)
        self.assertEqual(
            new_text,
            "[session]\nresume_agents_on_restore = false\n"
            "startup_per_agent_delay_ms = 100\n",
        )

    def test_commented_out_key_is_not_treated_as_active(self):
        original = (
            "[session]\n# resume_agents_on_restore = true\n"
            "startup_per_agent_delay_ms = 100\n"
        )
        new_text = MODULE.compute_new_text(original)
        self.assertEqual(
            new_text,
            "[session]\nresume_agents_on_restore = false\n"
            "# resume_agents_on_restore = true\n"
            "startup_per_agent_delay_ms = 100\n",
        )

    def test_later_tables_are_preserved_untouched(self):
        original = "[session]\nresume_agents_on_restore = true\n[remote]\nmanage_ssh_config = false\n"
        new_text = MODULE.compute_new_text(original)
        self.assertEqual(
            new_text,
            "[session]\nresume_agents_on_restore = false\n[remote]\nmanage_ssh_config = false\n",
        )


class MainTest(unittest.TestCase):
    def test_absent_file_is_created_and_reports_changed(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = str(Path(tmp) / "nested" / "config.toml")
            rc = MODULE.main(["prog", path])
            self.assertEqual(rc, 0)
            self.assertEqual(
                Path(path).read_text(encoding="utf-8"),
                "[session]\nresume_agents_on_restore = false\n",
            )

    def test_already_false_reports_unchanged_and_leaves_file_byte_identical(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            original = "[session]\nresume_agents_on_restore = false\n[remote]\nmanage_ssh_config = false\n"
            path.write_text(original, encoding="utf-8")
            rc = MODULE.main(["prog", str(path)])
            self.assertEqual(rc, 0)
            self.assertEqual(path.read_text(encoding="utf-8"), original)

    def test_second_run_after_a_real_change_is_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text("onboarding = false\n", encoding="utf-8")
            self.assertEqual(MODULE.main(["prog", str(path)]), 0)
            first = path.read_text(encoding="utf-8")
            self.assertEqual(MODULE.main(["prog", str(path)]), 0)
            self.assertEqual(path.read_text(encoding="utf-8"), first)

    def test_malformed_toml_is_refused_and_left_untouched(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            original = "[session\nresume_agents_on_restore = true\n"
            path.write_text(original, encoding="utf-8")
            rc = MODULE.main(["prog", str(path)])
            self.assertEqual(rc, 1)
            self.assertEqual(path.read_text(encoding="utf-8"), original)

    def test_bad_argument_count_is_a_usage_error(self):
        self.assertEqual(MODULE.main(["prog"]), 2)
        self.assertEqual(MODULE.main(["prog", "a", "b"]), 2)


if __name__ == "__main__":
    unittest.main()
