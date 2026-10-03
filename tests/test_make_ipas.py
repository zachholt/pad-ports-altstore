import io
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import tempfile
import threading
import types
import unittest
from unittest import mock
import warnings
import zipfile


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "make-ipas.py"
make_ipas = types.ModuleType("make_ipas")
make_ipas.__file__ = str(MODULE_PATH)
exec(compile(MODULE_PATH.read_text(), str(MODULE_PATH), "exec"), make_ipas.__dict__)


def archive(entries):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as zf:
        for name, data in entries:
            zf.writestr(name, data)
    return output.getvalue()


class MakeIPAsTests(unittest.TestCase):
    def test_archive_rejects_traversal(self):
        with zipfile.ZipFile(io.BytesIO(archive([("PadMint-v0.3.4/../../escape", b"x")]))) as zf:
            with self.assertRaisesRegex(ValueError, "Unsafe archive path"):
                make_ipas.safe_members(zf)

    def test_archive_rejects_absolute_backslash_and_oversized_content(self):
        for name in ("/PadMint-v0.3.4/file", "PadMint-v0.3.4\\file", "C:/PadMint-v0.3.4/file"):
            data = archive([(name, b"x")])
            with zipfile.ZipFile(io.BytesIO(data)) as zf:
                with self.assertRaises(ValueError):
                    make_ipas.safe_members(zf)
        data = archive([("PadMint-v0.3.4/file", b"too large")])
        with zipfile.ZipFile(io.BytesIO(data)) as zf, mock.patch.object(make_ipas, "MAX_UNPACKED", 4):
            with self.assertRaisesRegex(ValueError, "safe size limit"):
                make_ipas.safe_members(zf)

    def test_archive_rejects_symlink_entry(self):
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w") as zf:
            info = zipfile.ZipInfo("PadMint-v0.3.4/link")
            info.external_attr = (0o120777 << 16)
            zf.writestr(info, "../../outside")
        with zipfile.ZipFile(io.BytesIO(payload.getvalue())) as zf:
            with self.assertRaisesRegex(ValueError, "Special file"):
                make_ipas.safe_members(zf)

    def test_archive_rejects_duplicate_normalized_paths(self):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            data = archive([("PadMint-v0.3.4/file", b"a"), ("PadMint-v0.3.4/file", b"b")])
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            with self.assertRaisesRegex(ValueError, "Duplicate"):
                make_ipas.safe_members(zf)

    def test_install_extracts_expected_official_package_atomically(self):
        data = archive([
            ("PadMint-v0.3.4/PadMint.command", b"launcher"),
            ("PadMint-v0.3.4/padmint/__main__.py", b"main"),
        ])
        expected = make_ipas.PIN.copy()
        expected.update(macOSArchiveBytes=len(data), macOSArchiveSha256=make_ipas.sha256(data))
        with tempfile.TemporaryDirectory(dir=Path.home()) as directory, mock.patch.object(make_ipas, "PIN", expected), \
                mock.patch.object(make_ipas, "cache_root", return_value=Path(directory) / "cache"):
            app = make_ipas.install_release(data)
            self.assertEqual((app / "PadMint.command").read_bytes(), b"launcher")
            self.assertEqual((app / "padmint/__main__.py").read_bytes(), b"main")
            (app / "padmint/__main__.py").write_bytes(b"tampered cache")
            second = make_ipas.install_release(data)
            self.assertNotEqual(app, second)
            self.assertTrue(app.is_dir())
            self.assertEqual((second / "padmint/__main__.py").read_bytes(), b"main")

    def test_install_rejects_symlinked_cache_root(self):
        data = archive([
            ("PadMint-v0.3.4/PadMint.command", b"launcher"),
            ("PadMint-v0.3.4/padmint/__main__.py", b"main"),
        ])
        expected = make_ipas.PIN.copy()
        expected.update(macOSArchiveBytes=len(data), macOSArchiveSha256=make_ipas.sha256(data))
        with tempfile.TemporaryDirectory(dir=Path.home()) as directory, tempfile.TemporaryDirectory(dir=Path.home()) as target, \
                mock.patch.object(make_ipas, "PIN", expected), \
                mock.patch.object(make_ipas, "cache_root", return_value=Path(directory) / "cache-link"):
            (Path(directory) / "cache-link").symlink_to(Path(target), target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symlink"):
                make_ipas.install_release(data)

    def test_archive_pin_rejects_wrong_size_or_hash(self):
        expected = make_ipas.PIN.copy()
        expected.update(macOSArchiveBytes=3, macOSArchiveSha256="0" * 64)
        with tempfile.NamedTemporaryFile() as archive_file, mock.patch.object(make_ipas, "PIN", expected):
            archive_file.write(b"bad")
            archive_file.flush()
            with self.assertRaisesRegex(ValueError, "size or SHA-256"):
                make_ipas.read_archive(Path(archive_file.name))

    def test_make_args_are_argv_safe_and_default_outside_repository(self):
        original_home = Path.home()
        args = ["make", "kartpad", "ios", "--disc", "/tmp/Game ; $stuff.iso"]
        result = make_ipas.passthrough_args(args)
        self.assertEqual(result[4], "/tmp/Game ; $stuff.iso")
        self.assertEqual(Path(result[-1]), original_home / "Downloads" / "PadPortsPersonalIPAs")
        relative = ["make", "kartpad", "ios", "--disc", "relative game ; $x.iso", "--out", "~/outside"]
        normalized = make_ipas.passthrough_args(relative)
        self.assertEqual(normalized[4], str((Path.cwd() / "relative game ; $x.iso").absolute()))
        equals = ["make", "kartpad", "ios", "--disc=relative path.iso", "--out=~/outside"]
        normalized_equals = make_ipas.passthrough_args(equals)
        self.assertEqual(normalized_equals[3], f"--disc={(Path.cwd() / 'relative path.iso').absolute()}")
        explicit = ["make", "kartpad", "ios", "--disc", "a b.iso", "--out", "~/outside/private ipa"]
        normalized = make_ipas.passthrough_args(explicit)
        self.assertEqual(normalized[-1], str(original_home / "outside/private ipa"))

    def test_make_rejects_repository_output(self):
        with self.assertRaisesRegex(ValueError, "outside Git repositories"):
            make_ipas.passthrough_args(["make", "kartpad", "ios", "--out", str(MODULE_PATH.parents[1])])

    def test_repository_output_through_external_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            link = Path(directory) / "repo-link"
            link.symlink_to(MODULE_PATH.parents[1] / "catalog", target_is_directory=True)
            self.assertTrue(make_ipas.is_inside_git_repo(link / "not-created" / "ipa"))

    def test_download_cache_replacements_are_safe_under_concurrency(self):
        data = b"pinned zip bytes"
        expected = make_ipas.PIN.copy()
        expected.update(macOSArchiveBytes=len(data), macOSArchiveSha256=make_ipas.sha256(data))
        barrier = threading.Barrier(2)

        def response(*_args, **_kwargs):
            result = io.BytesIO(data)
            result.geturl = lambda: "https://github.com/releases/asset.zip"
            return result

        original_exists = Path.exists

        def synchronized_archive_exists(path):
            result = original_exists(path)
            if path.name == "PadMint-macos.zip":
                barrier.wait(timeout=2)
            return result

        with tempfile.TemporaryDirectory(dir=Path.home()) as directory, \
                mock.patch.object(make_ipas, "PIN", expected), \
                mock.patch.object(make_ipas, "cache_root", return_value=Path(directory) / "cache"), \
                mock.patch.object(make_ipas.urllib.request, "urlopen", side_effect=response), \
                mock.patch.object(Path, "exists", synchronized_archive_exists):
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(lambda _: make_ipas.read_archive(None), range(2)))
            self.assertEqual(results, [data, data])
            self.assertEqual((Path(directory) / "cache/PadMint-macos.zip").read_bytes(), data)
            self.assertEqual(list((Path(directory) / "cache").glob(".padmint-*")), [])

    def test_help_does_not_download_or_launch(self):
        with mock.patch.object(make_ipas.urllib.request, "urlopen", side_effect=AssertionError("downloaded")), \
                mock.patch.object(make_ipas.subprocess, "run", side_effect=AssertionError("launched")):
            with self.assertRaises(SystemExit) as result:
                make_ipas.main(["--help"])
            self.assertEqual(result.exception.code, 0)

    def test_launch_forwards_paths_as_argv_and_defaults_to_official_ui(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory)
            runtime = app / "run"
            runtime.mkdir()
            subprocess_result = mock.Mock(returncode=0)
            with mock.patch.object(make_ipas, "read_archive", return_value=b"verified"), \
                    mock.patch.object(make_ipas, "install_release", return_value=runtime), \
                    mock.patch.object(make_ipas, "cache_root", return_value=app), \
                    mock.patch.object(make_ipas.subprocess, "run", return_value=subprocess_result) as run, \
                    mock.patch.object(Path, "home", return_value=app):
                self.assertEqual(make_ipas.main(["make", "kartpad", "ios", "--disc", "relative ; $b.iso"]), 0)
                command = run.call_args.args[0]
                self.assertEqual(command[:3], [make_ipas.sys.executable, "-m", "padmint"])
                self.assertEqual(command[3:8], ["make", "kartpad", "ios", "--disc",
                                                str((Path.cwd() / "relative ; $b.iso").absolute())])
                self.assertIn("--out", command)
                self.assertNotIn("shell", run.call_args.kwargs)
                private_dir = app / "Downloads" / "PadPortsPersonalIPAs"
                self.assertEqual(private_dir.stat().st_mode & 0o777, 0o700)
                self.assertFalse(runtime.exists())
            runtime.mkdir()
            with mock.patch.object(make_ipas, "read_archive", return_value=b"verified"), \
                    mock.patch.object(make_ipas, "install_release", return_value=runtime), \
                    mock.patch.object(make_ipas, "cache_root", return_value=app), \
                    mock.patch.object(make_ipas.subprocess, "run", return_value=subprocess_result) as run:
                self.assertEqual(make_ipas.main([]), 0)
                self.assertEqual(run.call_args.args[0][3:], ["ui", "--port", "0"])
                self.assertFalse(runtime.exists())


if __name__ == "__main__":
    unittest.main()
