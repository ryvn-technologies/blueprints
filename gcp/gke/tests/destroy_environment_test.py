import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "destroy_environment", Path(__file__).resolve().parents[1] / "destroy-environment.py"
)
teardown = importlib.util.module_from_spec(spec)
spec.loader.exec_module(teardown)


class DestroyEnvironmentTest(unittest.TestCase):
    def test_override_write_failure_removes_only_created_override(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "module"
            directory.mkdir()
            state = {"outputs": {"vpc": {"value": {"id": "test-network"}}}, "resources": [
                {"mode": "managed", "type": "google_compute_address", "name": "nat"}
            ]}
            override = directory / "allocation_teardown_override.tf"
            path_open = Path.open

            def failing_open(path, *args, **kwargs):
                stream = path_open(path, *args, **kwargs)
                if path == override:
                    stream.close()
                    failing_stream = mock.MagicMock()
                    failing_stream.__enter__.return_value = failing_stream
                    failing_stream.write.side_effect = OSError("disk full")
                    return failing_stream
                return stream

            with mock.patch.object(teardown, "terraform", return_value=json.dumps(state)) as terraform_mock:
                with mock.patch.object(Path, "open", failing_open), self.assertRaisesRegex(OSError, "disk full"):
                    teardown.destroy(directory, Path(temporary) / "evidence", "test-network", [])
                terraform_mock.assert_called_once_with(directory.resolve(), "state", "pull")
            self.assertFalse(override.exists())
            self.assertTrue((Path(temporary) / "evidence" / "state-before.json").exists())

            override.write_text("existing operator file")
            with mock.patch.object(teardown, "terraform", return_value=json.dumps(state)), self.assertRaises(FileExistsError):
                teardown.destroy(directory, Path(temporary) / "existing-evidence", "test-network", [])
            self.assertEqual(override.read_text(), "existing operator file")

    def test_nat_only_full_teardown(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "module"
            directory.mkdir()
            state = {"outputs": {"vpc": {"value": {"id": "test-network"}}}, "resources": [
                {"mode": "managed", "type": "google_compute_address", "name": "nat"}
            ]}
            plan = {"resource_changes": [{"mode": "managed", "change": {"actions": ["delete"]}}]}
            def terraform_mock(_, *args, **kwargs):
                if args[:2] == ("state", "pull"):
                    return json.dumps(state)
                override = (directory / "allocation_teardown_override.tf").read_text()
                self.assertIn('resource "google_compute_address" "nat"', override)
                self.assertNotIn("additional_subnet_geometry", override)
                if args[0] == "show":
                    return json.dumps(plan)
                if args[0] == "apply":
                    state["resources"] = []
                return ""
            evidence = Path(temporary) / "evidence"
            with mock.patch.object(teardown, "terraform", side_effect=terraform_mock):
                teardown.destroy(directory, evidence, "test-network", [])
            self.assertFalse((directory / "allocation_teardown_override.tf").exists())
            self.assertEqual(evidence.stat().st_mode & 0o777, 0o700)
            for file in evidence.iterdir():
                self.assertEqual(file.stat().st_mode & 0o777, 0o600)

    def test_evidence_refuses_symlink_and_existing_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "link").symlink_to(root, target_is_directory=True)
            for path in [root, root / "link" / "evidence"]:
                with self.subTest(path=path), self.assertRaises(OSError):
                    with teardown.private_evidence_directory(path):
                        self.fail("unsafe path accepted")

    def test_evidence_writes_remain_anchored_after_ancestor_move(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            parent = root / "parent"
            parent.mkdir()
            with teardown.private_evidence_directory(parent / "evidence") as descriptor:
                parent.rename(root / "moved")
                parent.mkdir()
                teardown.write_private(descriptor, "state.json", "private")
                with self.assertRaises(FileExistsError):
                    teardown.write_private(descriptor, "state.json", "overwrite")
                (root / "moved" / "evidence" / "link").symlink_to(root / "target")
                with self.assertRaises(FileExistsError):
                    teardown.write_private(descriptor, "link", "overwrite")
            self.assertFalse((parent / "evidence").exists())
            self.assertFalse((root / "target").exists())
            self.assertEqual((root / "moved" / "evidence" / "state.json").read_text(), "private")

    def test_refuses_updates_replacements_and_empty_plans(self):
        for actions in (["update"], ["create"], ["delete", "create"], ["no-op"]):
            with self.subTest(actions=actions), self.assertRaises(ValueError):
                teardown.validate_destroy_plan({"resource_changes": [
                    {"mode": "managed", "change": {"actions": actions}}
                ]})
        with self.assertRaises(ValueError):
            teardown.validate_destroy_plan({})

    def test_real_terraform_guard_and_explicit_teardown(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "module"
            directory.mkdir()
            (directory / "main.tf").write_text(
                'resource "terraform_data" "additional_subnet_geometry" {\n'
                '  for_each = { batch = "10.0.193.0/26" }\n'
                '  input = each.value\n'
                '  lifecycle { prevent_destroy = true }\n'
                '}\n'
                'resource "terraform_data" "workload" {\n'
                '  input = terraform_data.additional_subnet_geometry["batch"].output\n'
                '}\n'
                'output "vpc" { value = { id = "test-network" } }\n'
            )
            teardown.terraform(directory, "init", "-backend=false", "-input=false")
            teardown.terraform(directory, "apply", "-auto-approve", "-input=false")
            with self.assertRaises(subprocess.CalledProcessError):
                teardown.terraform(directory, "plan", "-destroy", "-input=false")
            with self.assertRaisesRegex(ValueError, "Confirmation"):
                teardown.destroy(directory, Path(temporary) / "wrong", "wrong-network", [])
            self.assertFalse((directory / "allocation_teardown_override.tf").exists())
            teardown.destroy(directory, Path(temporary) / "evidence", "test-network", [])
            state = json.loads(teardown.terraform(directory, "state", "pull"))
            self.assertFalse(state.get("resources"))
            self.assertFalse((directory / "allocation_teardown_override.tf").exists())
            self.assertIn("prevent_destroy = true", (directory / "main.tf").read_text())

    def test_failure_removes_override_and_preserves_state(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "module"
            directory.mkdir()
            # A real guarded allocation and deliberately failing destroy provisioner.
            (directory / "main.tf").write_text(
                'resource "terraform_data" "additional_subnet_geometry" {\n'
                '  lifecycle { prevent_destroy = true }\n'
                '}\n'
                'resource "terraform_data" "workload" {\n'
                '  depends_on = [terraform_data.additional_subnet_geometry]\n'
                '  provisioner "local-exec" {\n'
                '    when = destroy\n'
                '    command = "exit 1"\n'
                '  }\n'
                '}\n'
                'output "vpc" { value = { id = "test-network" } }\n'
            )
            teardown.terraform(directory, "init", "-backend=false", "-input=false")
            teardown.terraform(directory, "apply", "-auto-approve", "-input=false")
            evidence = Path(temporary) / "evidence"
            with self.assertRaises(subprocess.CalledProcessError):
                teardown.destroy(directory, evidence, "test-network", [])
            self.assertFalse((directory / "allocation_teardown_override.tf").exists())
            self.assertTrue((evidence / "state-before.json").exists())
            self.assertTrue(json.loads(teardown.terraform(directory, "state", "pull"))["resources"])


if __name__ == "__main__":
    unittest.main()
