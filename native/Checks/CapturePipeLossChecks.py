"""Compile the production PCM/lifecycle boundaries with synthetic carrier operations."""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
source = (root / "native/Sources/FaceTimeAudioCapture/FaceTimeAudioCapture.swift").read_text()
fixture = (root / "native/Checks/CapturePipeLossChecks.swift").read_text()


def fragment(start, end):
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError(f"Ambiguous production boundary: {start}")
    first = source.index(start)
    return source[first:source.index(end, first)]


parts = {
    "ERRORS": fragment("private enum CaptureError:", "\nprivate struct Arguments"),
    "WRITER_AND_LIFECYCLE": fragment("private final class ConverterInput:", "\nprivate func audioDevice("),
    "PCM_CALLBACK": fragment("    self.writer = try PCMWriter", "\n    } catch {\n      // A throwing initializer"),
    "OWNER_SETUP": fragment("      let ownerRef = CaptureCarrierOwner(", "      // The OpenClaw host owns playback"),
    "PARENT_READER": fragment("private final class ParentCommandReader:", "\nprivate final class ProcessTap:"),
    "WAIT_LOOP": fragment("private func waitForTerminationSignal(", "\n@main\nprivate struct FaceTimeAudioCapture"),
}
for name, text in parts.items():
    marker = f"/* OPENCLAW_{name} */"
    if fixture.count(marker) != 1:
        raise RuntimeError(f"Missing fixture boundary: {name}")
    fixture = fixture.replace(marker, text)
pathlib.Path(sys.argv[2]).write_text(fixture)
