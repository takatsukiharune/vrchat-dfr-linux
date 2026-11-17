#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""The Proton builds Steam can use, and the gaze DXVK DLLs in them."""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

REPO = Path(os.path.abspath(__file__)).parent.parent

# Present in every d3d11.dll built with the gaze patches, absent from stock DXVK.
MARKER = b"DXVK_GAZE_VRS"

# The `git describe` string DXVK embeds, e.g. v3.1.1-174-gf86377680682448-GE-Proton(dirty).
DLL_VERSION = re.compile(rb"v[0-9]+\.[0-9]+(?:\.[0-9]+)?-[0-9]+-g[0-9a-f]{7,}[-+.A-Za-z0-9()]*")

MANIFEST = """\
"compatibilitytools"
{
  "compat_tools"
  {
    "%(name)s"
    {
      "install_path" "."
      "display_name" "%(name)s"
      "from_oslist"  "windows"
      "to_oslist"    "linux"
    }
  }
}
"""

INSTALL_HELP = """\
Installs the patched d3d11.dll and dxgi.dll for one Proton build.

Default: copy PROTON to <name>-dfr beside it and patch the copy. PROTON itself
is not changed. PROTON may also name such a copy, to update it."""

UNINSTALL_HELP = """\
Undoes install for one Proton build.

A <name>-dfr copy is deleted, whether PROTON names the copy or its source. A
build patched with --in-place gets its own DLLs back from the .stock copies."""


def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def dxvk_dir(proton):
    return proton / "files/lib/wine/dxvk/x86_64-windows"


def is_patched(dll):
    return MARKER in dll.read_bytes()


def dll_version(dll):
    match = DLL_VERSION.search(dll.read_bytes())
    return match[0].decode() if match else ""


def version_commit(version):
    match = re.match(r"v[0-9.]+-[0-9]+-g([0-9a-f]{7,})", version)
    return match[1] if match else ""


def same_commit(a, b):
    return bool(a and b) and (a.startswith(b) or b.startswith(a))


def first_line(path):
    return path.read_text(errors="replace").partition("\n")[0] if path.is_file() else ""


def dxvk_commit(proton):
    """The DXVK commit a Proton build ships: from dxvk/version, else from its stock DLL."""
    version = dxvk_dir(proton).parent / "version"
    if version.is_file() and (match := re.search(r"[0-9a-f]{40}", version.read_text(errors="replace"))):
        return match[0]
    dll = dxvk_dir(proton) / "d3d11.dll"
    if dll.with_name("d3d11.dll.stock").is_file():
        dll = dll.with_name("d3d11.dll.stock")
    if not dll.is_file() or is_patched(dll):
        return ""
    return version_commit(dll_version(dll))


def variant(proton):
    """Release name of a Proton build that patches DXVK itself (GE-Proton11-12,
    cachyos-11.0-20261015-slr). Empty for every other Proton build."""
    words = first_line(proton / "version").split()
    name = words[1] if len(words) > 1 else ""
    return name if name.startswith(("GE-Proton", "cachyos-")) else ""


def made_for(version, release):
    """A build for a Proton release carries that release's DXVK patches and names it."""
    if release:
        return f"-{release}-dfr." in version
    return re.search(r"-g[0-9a-f]+-dfr\.", version) is not None


def parse_vdf(text):
    """Steam's text VDF as a list of (key, value) pairs, where a block's value is
    its own list of pairs."""
    token = re.compile(r'"(?P<string>(?:[^"\\]|\\.)*)"|(?P<brace>[{}])|//[^\n]*|(?P<word>[^\s{}"]+)')
    unescape = {"n": "\n", "t": "\t"}
    tokens = iter([
        (m.lastgroup, re.sub(r"\\(.)", lambda e: unescape.get(e[1], e[1]), m[m.lastgroup]))
        for m in token.finditer(text) if m.lastgroup
    ])

    def block():
        pairs = []
        for kind, key in tokens:
            if kind == "brace":
                break
            kind, value = next(tokens, ("brace", "}"))
            if kind == "brace" and value == "}":
                break
            pairs.append((key, block() if kind == "brace" else value))
        return pairs

    return block()


def find_block(pairs, name):
    for key, value in pairs:
        if isinstance(value, list):
            if key.lower() == name.lower():
                return value
            if (found := find_block(value, name)) is not None:
                return found
    return None


def internal_name(proton):
    """The name Steam stores per game for a compatibility tool: the first key
    under "compat_tools" in its manifest. Valve's Proton has no manifest, and
    its directory name stands in."""
    manifest = proton / "compatibilitytool.vdf"
    if manifest.is_file():
        tools = find_block(parse_vdf(manifest.read_text(errors="replace")), "compat_tools")
        if tools:
            return tools[0][0]
    return proton.name


def write_manifest(proton, name):
    quoted = name.replace("\\", "\\\\").replace('"', '\\"')
    (proton / "compatibilitytool.vdf").write_text(MANIFEST % {"name": quoted})


def copy_source(proton):
    """The Proton build that install copied to this one, or None."""
    source = first_line(proton / ".dfr-clone")
    return Path(source) if source else None


def same_version(a, b):
    """Same version file, or neither has one."""
    def read(proton):
        path = proton / "version"
        return path.read_bytes() if path.exists() else None
    return read(a) == read(b)


def steam_roots():
    home = os.environ.get("HOME", "")
    roots = []
    for root in (os.environ.get("STEAM_DIR", ""), f"{home}/.local/share/Steam", f"{home}/.steam/steam",
                 f"{home}/.var/app/com.valvesoftware.Steam/.local/share/Steam"):
        if root and os.path.isdir(root) and Path(os.path.realpath(root)) not in roots:
            roots.append(Path(os.path.realpath(root)))
    return roots


def proton_installs():
    """Every Proton build Steam can use."""
    found = []
    for root in steam_roots():
        for parent in (root / "compatibilitytools.d", root / "steamapps/common"):
            if not parent.is_dir():
                continue
            dirs = [d for d in parent.iterdir() if d.is_dir() and not d.name.startswith(".")]
            found += [d for d in sorted(dirs, key=lambda d: d.name.casefold())
                      if (dxvk_dir(d) / "d3d11.dll").is_file()]
    return found


def listing():
    lines = []
    for proton in proton_installs():
        dll = dxvk_dir(proton) / "d3d11.dll"
        state = "patched" if is_patched(dll) else "stock"
        lines.append(f"  {state:<8} {dll_version(dll):<34} {proton}")
    return "\n".join(lines)


def resolve(name):
    """A path, or the directory name of a discovered Proton build."""
    if os.path.isdir(name):
        return Path(os.path.abspath(name))
    for proton in proton_installs():
        if proton.name == name:
            return proton
    die(f"No Proton build '{name}'. Found:\n{listing()}")


def tools_dir_of(proton):
    """compatibilitytools.d of the Steam installation that holds a Proton build."""
    for parent in ("/compatibilitytools.d/", "/steamapps/common/"):
        steam, found, _ = str(proton).rpartition(parent)
        if found:
            return Path(steam) / "compatibilitytools.d"
    return None


def replace_file(src, dst):
    """Replace a file, read-only or not, by renaming a new one over it. A running
    game keeps its old copy, and the new file gets the mode of the original."""
    fd, tmp = tempfile.mkstemp(prefix=dst.name + ".", dir=dst.parent)
    os.close(fd)
    try:
        shutil.copyfile(src, tmp)
        shutil.copymode(dst, tmp)
        os.replace(tmp, dst)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def install(args):
    target = resolve(args.proton)
    if not (dxvk_dir(target) / "d3d11.dll").is_file():
        die(f"No DXVK in {target}.")

    # source: the Proton build a copy is made from, None for --in-place. dest: where the DLLs go.
    source = copy_source(target)
    tools_dir = None
    if source:
        dest, tools_dir = target, target.parent
    elif args.in_place:
        dest = target
    else:
        source = target
        tools_dir = Path(args.tools_dir) if args.tools_dir else tools_dir_of(source)
        if not tools_dir:
            die(f"Cannot tell which Steam has {source}. Pass --tools-dir DIR.")
        dest = tools_dir / f"{source.name}-dfr"
        if dest.exists() and not copy_source(dest):
            die(f"{dest} exists and was not made by this script. Remove it, or patch it with: "
                f"{sys.argv[0]} install --in-place '{dest}'")
        if dest.exists() and copy_source(dest) != source:
            die(f"{dest} is a copy of {copy_source(dest)}, not of {source}.")

    # A new copy is made when there is none yet, or when --refresh asks for one
    # because its source changed.
    fresh = False
    if source:
        if not dest.exists():
            fresh = True
        elif not source.is_dir():
            if args.refresh:
                die(f"{source} no longer exists, so {dest} cannot be copied again.")
        elif not same_version(source, dest):
            if not args.refresh:
                die(f"{source} changed after {dest} was made.\n"
                    "Close the game and run again with --refresh to copy it again.")
            fresh = True

    # The DLLs must fit the DXVK the game will run with: the copy's own, unless a
    # new copy is about to replace it.
    shipped = source if fresh else dest
    commit, release = dxvk_commit(shipped), variant(shipped)

    dxvk_from = args.dxvk_from
    if not dxvk_from:
        for build in sorted((REPO / "dist").glob("dxvk*"), key=lambda d: d.name.casefold()):
            if not ((build / "d3d11.dll").is_file() and (build / "dxgi.dll").is_file()):
                continue
            version = dll_version(build / "d3d11.dll")
            if same_commit(commit, version_commit(version)) and made_for(version, release):
                dxvk_from = build
                break
        else:
            die(f"No build in {REPO / 'dist'} was made for {release or 'DXVK ' + (commit or 'of this Proton build')}.\n"
                f"Build it with: scripts/dev-container.sh build --proton '{shipped}'")

    with tempfile.TemporaryDirectory() as unpacked:
        dlls = Path(dxvk_from)
        if dlls.is_file() and dlls.suffix == ".zip":
            with zipfile.ZipFile(dlls) as archive:
                archive.extractall(unpacked)
            found = sorted(Path(unpacked).rglob("d3d11.dll"))
            dlls = found[0].parent if found else Path(unpacked)
        if not ((dlls / "d3d11.dll").is_file() and (dlls / "dxgi.dll").is_file()):
            die(f"No d3d11.dll and dxgi.dll in {dlls}.")
        if not is_patched(dlls / "d3d11.dll"):
            die(f"{dlls / 'd3d11.dll'} is not a gaze-VRS build.")

        new_version = dll_version(dlls / "d3d11.dll")
        if not commit:
            print("Cannot tell which DXVK commit this Proton build ships; version match not checked.")
        elif not same_commit(commit, version_commit(new_version)):
            message = f"The DLLs are DXVK {new_version}, but this Proton build ships DXVK commit {commit[:12]}."
            if not args.force:
                die(f"{message}\nBuild matching DLLs with: scripts/dev-container.sh build --proton '{shipped}'\n"
                    "or pass --force to install these.")
            print(f"{message} Installing them because of --force.")
        if not made_for(new_version, release):
            print(f"Note: these DLLs were not built with the DXVK patches of {release or 'plain upstream DXVK'}.")

        # Steam keeps the internal name per game. The copy uses its source's name
        # plus -dfr, so a game set to a hand-made copy of the same name keeps working.
        name = None
        if source and source.is_dir():
            name = internal_name(source) + "-dfr"
            others = tools_dir.iterdir() if tools_dir.is_dir() else []
            for other in others:
                if other.is_dir() and not other.name.startswith(".") and other != dest and internal_name(other) == name:
                    die(f"{other} already uses the name {name}; Steam could pick either. Remove one of them.")

        def install_dlls(proton):
            for dll in ("d3d11.dll", "dxgi.dll"):
                replace_file(dlls / dll, dxvk_dir(proton) / dll)

        if fresh:
            tools_dir.mkdir(parents=True, exist_ok=True)
            staging = Path(tempfile.mkdtemp(prefix=dest.name + ".", dir=tools_dir))
            try:
                if subprocess.run(["cp", "-a", "--reflink=auto", f"{source}/.", f"{staging}/"]).returncode:
                    die(f"Cannot copy {source} to {staging}.")
                (staging / ".dfr-clone").write_text(f"{source}\n")
                write_manifest(staging, name)
                install_dlls(staging)
                if dest.exists():
                    shutil.rmtree(dest)
                staging.rename(dest)
            finally:
                shutil.rmtree(staging, ignore_errors=True)
            print(f"Made {dest} from {source} with DXVK {new_version}.")
            print(f"Select '{name}' as the compatibility tool for the game in Steam (restart Steam if it is not listed).")
            return

        if name:
            write_manifest(dest, name)
        elif not source:
            # Keep Proton's own DLLs once. A patched DLL is never kept as stock.
            target_dlls = dxvk_dir(dest)
            if not is_patched(target_dlls / "d3d11.dll"):
                for dll in ("d3d11.dll", "dxgi.dll"):
                    stock = target_dlls / f"{dll}.stock"
                    stock.unlink(missing_ok=True)
                    shutil.copy2(target_dlls / dll, stock)
                print(f"Kept Proton's DLLs as {target_dlls}/{{d3d11,dxgi}}.dll.stock")
            elif not (target_dlls / "d3d11.dll.stock").is_file():
                print(f"{dest} is already patched and has no .stock copy; uninstall cannot bring its own DLLs back.")
        install_dlls(dest)
        print(f"Installed DXVK {new_version} into {dest}.")


def uninstall(args):
    proton = resolve(args.proton)
    removed_message = "Removed {}. Select another compatibility tool for the game in Steam."
    if copy_source(proton):
        shutil.rmtree(proton)
        print(removed_message.format(proton))
        return
    removed = False
    for copy in proton_installs():
        if copy_source(copy) == proton:
            shutil.rmtree(copy)
            print(removed_message.format(copy))
            removed = True

    dlls = dxvk_dir(proton)
    if not (dlls / "d3d11.dll").is_file():
        die(f"No DXVK in {proton}.")
    stock = {dll: dlls / f"{dll}.stock" for dll in ("d3d11.dll", "dxgi.dll")}
    if not is_patched(dlls / "d3d11.dll"):
        # A Proton update put its own, newer DLLs back: the kept ones are older.
        for path in stock.values():
            path.unlink(missing_ok=True)
        if not removed:
            print(f"{proton} already has Proton's own DXVK.")
        return
    if not all(path.is_file() for path in stock.values()):
        die(f"{proton} is patched but has no .stock copies. Reinstall this Proton build, or verify its files in Steam.")
    for dll, path in stock.items():
        os.replace(path, dlls / dll)
    print(f"Proton's own DXVK is back in {proton}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True, metavar="COMMAND")
    commands.add_parser("list", help="list the Proton builds found")

    proton_help = "a directory, or the directory name of a Proton build that 'list' shows"
    raw = argparse.RawDescriptionHelpFormatter
    command = commands.add_parser("install", help="install the gaze DXVK DLLs", description=INSTALL_HELP, formatter_class=raw)
    command.add_argument("--in-place", action="store_true",
                         help="patch PROTON itself and keep its DLLs as d3d11.dll.stock and dxgi.dll.stock")
    command.add_argument("--refresh", action="store_true", help="copy PROTON again when it changed after <name>-dfr was made")
    command.add_argument("--dxvk-from", metavar="PATH", default=os.environ.get("DXVK_FROM", ""),
                         help="directory or .zip with d3d11.dll and dxgi.dll "
                              "(default: the build in dist/ made for PROTON with `build --proton`)")
    command.add_argument("--force", action="store_true", help="install DLLs built from a different DXVK commit than PROTON ships")
    command.add_argument("--tools-dir", metavar="DIR",
                         help="where <name>-dfr goes (default: the compatibilitytools.d of PROTON's Steam)")
    command.add_argument("proton", metavar="PROTON", help=proton_help)
    command = commands.add_parser("uninstall", help="undo install", description=UNINSTALL_HELP, formatter_class=raw)
    command.add_argument("proton", metavar="PROTON", help=proton_help)

    command = commands.add_parser("resolve", help="print the directory of a Proton build")
    command.add_argument("proton", metavar="PROTON", help=proton_help)
    command = commands.add_parser("commit", help="print the DXVK commit a Proton build ships; fails when unknown")
    command.add_argument("dir", metavar="DIR", type=Path)
    command = commands.add_parser("variant", help="print the GE-Proton or proton-cachyos release of a Proton build, if any")
    command.add_argument("dir", metavar="DIR", type=Path)
    command = commands.add_parser("dll-version", help="print the DXVK version a DLL names")
    command.add_argument("dll", metavar="DLL", type=Path)

    args = parser.parse_args()
    if args.command == "list":
        print(listing())
    elif args.command == "install":
        install(args)
    elif args.command == "uninstall":
        uninstall(args)
    elif args.command == "resolve":
        print(resolve(args.proton))
    elif args.command == "commit":
        commit = dxvk_commit(args.dir)
        if not commit:
            sys.exit(1)
        print(commit)
    elif args.command == "variant":
        print(variant(args.dir))
    elif args.command == "dll-version":
        print(dll_version(args.dll))


if __name__ == "__main__":
    main()
