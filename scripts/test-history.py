#!/usr/bin/env python3
"""Compile the real App with a test entry point; never run its launch lifecycle.

Requires existing vendor libraries. No download, install or model setup.
Optional argument: directory for PNG renders of the real History view.
--brain-fixture substitutes only Brain readiness/response in the scratch copy.
"""
import pathlib
import re
import subprocess
import sys
import tempfile
import uuid

root = pathlib.Path(__file__).resolve().parents[1]
arguments = sys.argv[1:]
brain_fixture = "--brain-fixture" in arguments
arguments = [arg for arg in arguments if arg != "--brain-fixture"]
with tempfile.TemporaryDirectory(prefix="giga-history-") as scratch:
    scratch = pathlib.Path(scratch)
    bundle = scratch / "HistoryTests.app/Contents"
    binary = bundle / "MacOS/HistoryTests"
    binary.parent.mkdir(parents=True)
    domain = "ru.panda.giga.history-test." + uuid.uuid4().hex
    (bundle / "Info.plist").write_text(
        '<?xml version="1.0"?><plist version="1.0"><dict>'
        '<key>CFBundleIdentifier</key><string>' + domain + '</string>'
        '<key>CFBundleExecutable</key><string>HistoryTests</string></dict></plist>'
    )
    original = (root / "main.swift").read_text()
    # Keep all application code; replace only the launch/diagnostics entry points.
    original = original[:original.index("// Предпросмотр окна первого запуска:")]
    main = scratch / "main.swift"
    # Redirect Copy Last's pasteboard only in this test copy, to avoid the user's clipboard.
    original = original.replace("let pb = NSPasteboard.general", 'let pb = NSPasteboard(name: .init("' + domain + '"))')
    main.write_text(original + "\nlet usesBrainFixture = " + str(brain_fixture).lower() + "\n" + (root / "scripts/test-history.swift").read_text())
    sources = re.search(r"SOURCES=\((.*?)\)", (root / "build.sh").read_text(), re.S).group(1).split()
    if brain_fixture:
        brain = (root / "swift/Brain.swift").read_text()
        start = brain.index("    var ready: Bool {")
        end = brain.index("    /// Send every take", start)
        brain = brain[:start] + "    var ready: Bool { true }\n" + brain[end:]
        start = brain.index("    func transform(_ body:")
        end = brain.index("    private func transformNow", start)
        brain = brain[:start] + '''    func transform(_ body: String, command: String, mode: Mode = .dictation,
                   done: @escaping (String?) -> Void) {
        precondition(command == "исправь")
        done("fixture: " + body)
    }
''' + brain[end:]
        (scratch / "Brain.swift").write_text(brain)
        sources[sources.index("swift/Brain.swift")] = str(scratch / "Brain.swift")
    ort = root / "vendor/onnxruntime-osx-universal2-1.23.2"
    subprocess.run(["swiftc", "-import-objc-header", str(root / "swift/bridge.h"),
                    "-I", str(ort / "include"), "-L", str(ort / "lib"), "-lonnxruntime",
                    "-Xlinker", "-rpath", "-Xlinker", str((ort / "lib").resolve()),
                    "-o", str(binary), str(main)] + [str(root / path) for path in sources[1:]], check=True)
    subprocess.run([str(binary)] + arguments, check=True)
