"""Initialize NAS shares, archive files, verify copies and record camera streams."""
import argparse
import getpass
import gzip
import hashlib
from itertools import chain
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
from tempfile import TemporaryDirectory
from urllib.parse import urlsplit


SHARES = ("Backups", "Películas", "Datos", "Trabajos", "Universidad", "Privado")


def init_nas(root):
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    for name in SHARES:
        directory = root / name
        if directory.is_symlink():
            raise ValueError(f"{directory} es un enlace simbólico.")
        directory.mkdir(mode=0o700, exist_ok=True)


def copy_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(archive, expected=None):
    actual = copy_digest(archive)
    if expected is not None and actual != expected.lower():
        raise ValueError("El SHA-256 de la copia cambió.")
    # Force the gzip stream to EOF so its CRC is checked even after the tar end marker.
    with gzip.open(archive, "rb") as source:
        while source.read(1024 * 1024):
            pass
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            path = Path(member.name)
            if path.is_absolute() or ".." in path.parts or not (member.isdir() or member.isfile()):
                raise ValueError(f"Entrada de archivo no admitida: {member.name}")
    return actual


def backup(source, archive):
    source = source.resolve(strict=True)
    archive = archive.resolve()
    if archive == source or (source.is_dir() and source in archive.parents):
        raise ValueError("La copia debe quedar fuera del origen.")
    # Publish only a complete verified copy. A preexisting name always wins.
    with TemporaryDirectory(prefix=".nexus-backup-", dir=archive.parent) as scratch:
        work = Path(scratch) / "backup.tar.gz"
        with tarfile.open(work, "w:gz") as target:
            def regular_only(member):
                if not (member.isfile() or member.isdir()):
                    raise ValueError(f"Tipo de archivo no admitido: {member.name}")
                return member
            for path in chain((source,), source.rglob("*") if source.is_dir() else ()):
                if path.is_symlink():
                    raise ValueError(f"Enlace simbólico no admitido: {path}")
                target.add(path, arcname=str(path.relative_to(source.parent)), recursive=False, filter=regular_only)
        digest = verify(work)
        os.link(work, archive)
        return digest


def restore(archive, destination, expected=None):
    destination.mkdir(mode=0o700)
    try:
        # Verify and extract from a private copy to keep the input stable throughout restoration.
        with TemporaryDirectory(prefix=".nexus-restore-", dir=destination.parent) as work:
            snapshot = Path(work) / "backup.tar.gz"
            shutil.copyfile(archive, snapshot)
            verify(snapshot, expected)
            with tarfile.open(snapshot, "r:gz") as source:
                for member in source:
                    target = destination / member.name
                    if member.isdir():
                        target.mkdir(mode=0o700, parents=True, exist_ok=True)
                    else:
                        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                        with source.extractfile(member) as data, target.open("xb") as file:
                            shutil.copyfileobj(data, file)
    except (OSError, tarfile.TarError, ValueError, EOFError):
        shutil.rmtree(destination)
        raise


def record(source, output, seconds, *, rtsp):
    if not (1 <= seconds <= 3600):
        raise ValueError("La duración debe estar entre 1 y 3600 segundos.")
    if not 1 <= len(output.name) <= 63 or not re.fullmatch(r"[-_a-zA-Z0-9]+", output.name):
        raise ValueError("Usa un nombre de cámara con letras, números, guion o guion bajo.")
    if rtsp and urlsplit(source).scheme not in ("rtsp", "rtsps"):
        raise ValueError("Se necesita una URL RTSP o RTSPS de la cámara.")
    options = ["-rtsp_transport", "tcp", "-timeout", "8000000"] if rtsp else []
    output.mkdir(mode=0o700)
    try:
        subprocess.run(
            ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", *options, "-i", source,
             "-t", str(seconds), "-map", "0:v:0", "-c:v", "copy", "-f", "segment",
             "-segment_time", "60", "-reset_timestamps", "1", str(output / "tramo-%04d.mkv")],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=seconds + 20,
        )
        if not any(file.stat().st_size > 0 for file in output.glob("tramo-*.mkv")):
            raise ValueError("El origen no entregó vídeo.")
    except (subprocess.SubprocessError, OSError) as error:
        raise ValueError("Grabación interrumpida. Revisa FFmpeg, el origen y los permisos de escritura.") from error


def self_test():
    with TemporaryDirectory(prefix="nexus-ops-") as work:
        root = Path(work)
        init_nas(root / "nas")
        track = root / "nas" / "Universidad" / "redes.txt"
        track.write_text("VLAN 10\n", encoding="utf-8")
        archive = root / "copia.tar.gz"
        digest = backup(track.parent, archive)
        assert digest == verify(archive, digest)
        restore(archive, root / "recuperacion", digest)
        assert (root / "recuperacion" / "Universidad" / track.name).read_bytes() == track.read_bytes()
        try:
            backup(track.parent, archive)
        except FileExistsError:
            pass
        else:
            raise AssertionError("Se sustituyó una copia previa.")
        assert digest == copy_digest(archive)
        if shutil.which("ffmpeg"):
            media = root / "source.mkv"
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi", "-i",
                            "color=black:s=128x72:d=1", "-c:v", "mpeg4", str(media)], check=True)
            record(str(media), root / "CAM-ACCESO", 1, rtsp=False)
            print("PASS · Captura segmentada desde archivo con FFmpeg")
        print("PASS · Carpetas NAS, SHA-256, restauración y protección contra sobrescritura")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    nas = actions.add_parser("init-nas")
    nas.add_argument("root", type=Path)
    copy = actions.add_parser("backup")
    copy.add_argument("source", type=Path)
    copy.add_argument("archive", type=Path)
    validation = actions.add_parser("verify")
    validation.add_argument("archive", type=Path)
    validation.add_argument("--sha256")
    recovery = actions.add_parser("restore")
    recovery.add_argument("archive", type=Path)
    recovery.add_argument("destination", type=Path)
    recovery.add_argument("--sha256")
    camera = actions.add_parser("record")
    camera.add_argument("output", type=Path)
    camera.add_argument("--seconds", type=int, default=60)
    camera.add_argument("--file", type=Path, help="Origen de vídeo local para comprobar la grabación")
    actions.add_parser("self-test")
    args = parser.parse_args()
    try:
        if args.action == "init-nas":
            init_nas(args.root)
            print("\n".join(str(args.root / name) for name in SHARES))
        elif args.action == "backup":
            print(backup(args.source, args.archive))
        elif args.action == "verify":
            print(verify(args.archive, args.sha256))
        elif args.action == "restore":
            restore(args.archive, args.destination, args.sha256)
        elif args.action == "record":
            source = str(args.file.resolve(strict=True)) if args.file else getpass.getpass("URL RTSP de la cámara: ")
            record(source, args.output, args.seconds, rtsp=args.file is None)
        else:
            self_test()
    except (ValueError, OSError, tarfile.TarError, EOFError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
