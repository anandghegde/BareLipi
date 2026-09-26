#!/usr/bin/env python3
"""Vendors the tree-sitter runtime and the PRD Appendix A.4 grammars.

    python3 Scripts/vendor-tree-sitter.py [--cache <dir>]

Downloads each repository at the pinned commit from codeload.github.com and
writes:

  Sources/CTreeSitter/                 runtime (lib/src, lib/include), MIT
  Sources/CTreeSitterGrammars/<id>/    parser.c, scanner.c, tree_sitter/*.h
  Sources/CTreeSitterGrammars/LICENSES grammar licences and provenance
  Sources/LipiHighlight/GrammarQueries.swift
                                       highlights.scm per language, embedded
                                       as Swift strings (no bundle resources)

LaTeX ships without a generated parser.c or queries, so the script runs
`npx tree-sitter-cli@<runtime version> generate` for it and uses
Scripts/queries/latex.scm. Local query overrides in Scripts/queries/<id>.scm
are appended to the upstream query.
"""
import io
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNTIME = ("tree-sitter/tree-sitter", "v0.25.10")

# id, repo, grammar directory in the repo, highlight queries (grammar id of the
# repo holding the file, path). Order matters: later patterns win ties.
GRAMMARS = [
    ("bash", "tree-sitter/tree-sitter-bash", ".", [("bash", "queries/highlights.scm")]),
    ("c", "tree-sitter/tree-sitter-c", ".", [("c", "queries/highlights.scm")]),
    ("c_sharp", "tree-sitter/tree-sitter-c-sharp", ".", [("c_sharp", "queries/highlights.scm")]),
    ("cpp", "tree-sitter/tree-sitter-cpp", ".", [("c", "queries/highlights.scm"), ("cpp", "queries/highlights.scm")]),
    ("css", "tree-sitter/tree-sitter-css", ".", [("css", "queries/highlights.scm")]),
    ("dart", "UserNobody14/tree-sitter-dart", ".", [("dart", "queries/highlights.scm")]),
    ("diff", "tree-sitter-grammars/tree-sitter-diff", ".", [("diff", "queries/highlights.scm")]),
    ("dockerfile", "camdencheek/tree-sitter-dockerfile", ".", [("dockerfile", "queries/highlights.scm")]),
    ("elixir", "elixir-lang/tree-sitter-elixir", ".", [("elixir", "queries/highlights.scm")]),
    ("fish", "ram02z/tree-sitter-fish", ".", [("fish", "queries/highlights.scm")]),
    ("go", "tree-sitter/tree-sitter-go", ".", [("go", "queries/highlights.scm")]),
    ("graphql", "bkegley/tree-sitter-graphql", ".", [("graphql", "queries/graphql/highlights.scm")]),
    ("haskell", "tree-sitter/tree-sitter-haskell", ".", [("haskell", "queries/highlights.scm")]),
    ("html", "tree-sitter/tree-sitter-html", ".", [("html", "queries/highlights.scm")]),
    ("java", "tree-sitter/tree-sitter-java", ".", [("java", "queries/highlights.scm")]),
    ("javascript", "tree-sitter/tree-sitter-javascript", ".",
     [("javascript", "queries/highlights-params.scm"), ("javascript", "queries/highlights-jsx.scm"),
      ("javascript", "queries/highlights.scm")]),
    ("json", "tree-sitter/tree-sitter-json", ".", [("json", "queries/highlights.scm")]),
    ("julia", "tree-sitter/tree-sitter-julia", ".", [("julia", "queries/highlights.scm")]),
    ("kotlin", "fwcd/tree-sitter-kotlin", ".", [("kotlin", "queries/highlights.scm")]),
    ("latex", "latex-lsp/tree-sitter-latex", ".", []),
    ("lua", "tree-sitter-grammars/tree-sitter-lua", ".", [("lua", "queries/highlights.scm")]),
    ("make", "tree-sitter-grammars/tree-sitter-make", ".", [("make", "queries/highlights.scm")]),
    ("objc", "tree-sitter-grammars/tree-sitter-objc", ".", [("c", "queries/highlights.scm"), ("objc", "queries/highlights.scm")]),
    ("php", "tree-sitter/tree-sitter-php", "php", [("php", "queries/highlights.scm")]),
    ("python", "tree-sitter/tree-sitter-python", ".", [("python", "queries/highlights.scm")]),
    ("r", "r-lib/tree-sitter-r", ".", [("r", "queries/highlights.scm")]),
    ("ruby", "tree-sitter/tree-sitter-ruby", ".", [("ruby", "queries/highlights.scm")]),
    ("rust", "tree-sitter/tree-sitter-rust", ".", [("rust", "queries/highlights.scm")]),
    ("scss", "tree-sitter-grammars/tree-sitter-scss", ".", [("css", "queries/highlights.scm"), ("scss", "queries/highlights.scm")]),
    ("swift", "alex-pinkus/tree-sitter-swift", ".", [("swift", "queries/highlights.scm")]),
    ("toml", "tree-sitter-grammars/tree-sitter-toml", ".", [("toml", "queries/highlights.scm")]),
    ("typescript", "tree-sitter/tree-sitter-typescript", "typescript",
     [("typescript", "queries/highlights.scm"), ("javascript", "queries/highlights.scm")]),
    ("tsx", "tree-sitter/tree-sitter-typescript", "tsx",
     [("typescript", "queries/highlights.scm"), ("javascript", "queries/highlights-jsx.scm"),
      ("javascript", "queries/highlights.scm")]),
    ("xml", "tree-sitter-grammars/tree-sitter-xml", "xml", [("xml", "queries/xml/highlights.scm")]),
    ("yaml", "tree-sitter-grammars/tree-sitter-yaml", ".", [("yaml", "queries/highlights.scm")]),
    ("zig", "tree-sitter-grammars/tree-sitter-zig", ".", [("zig", "queries/highlights.scm")]),
]

# Pinned commits (resolved 2026-09-26). The swift grammar's generated
# parser lives on its `with-generated-files` branch.
COMMITS = {
    "UserNobody14/tree-sitter-dart": "be07cf7118d3dba06236a3f19541685a68209934",
    "alex-pinkus/tree-sitter-swift": "31d17fe7e818a2048c808b5c6fdc2dc792f4f5b5",
    "bkegley/tree-sitter-graphql": "5e66e961eee421786bdda8495ed1db045e06b5fe",
    "camdencheek/tree-sitter-dockerfile": "971acdd908568b4531b0ba28a445bf0bb720aba5",
    "elixir-lang/tree-sitter-elixir": "4b0c7118760af58a2e7081bbc8396e136f820b37",
    "fwcd/tree-sitter-kotlin": "1852ea17b7f60fb3f9d84e0b1555d56b46b39fb1",
    "latex-lsp/tree-sitter-latex": "fa8df448fc2c0192a8c2f8cfc97de53cb2b4ecb9",
    "r-lib/tree-sitter-r": "58a22794466c0fc15b0d3b40531db751593721e8",
    "ram02z/tree-sitter-fish": "b7f1d682941e0c62dfcd6bf9ef481638351bab16",
    "tree-sitter-grammars/tree-sitter-diff": "ada384ac7bfc1307f32de474620120add29998fb",
    "tree-sitter-grammars/tree-sitter-lua": "10fe0054734eec83049514ea2e718b2a56acd0c9",
    "tree-sitter-grammars/tree-sitter-make": "70613f3d812cbabbd7f38d104d60a409c4008b43",
    "tree-sitter-grammars/tree-sitter-objc": "181a81b8f23a2d593e7ab4259981f50122909fda",
    "tree-sitter-grammars/tree-sitter-scss": "2ef6d42e3ad7a8208900f9346f4529806ae0f9f9",
    "tree-sitter-grammars/tree-sitter-toml": "64b56832c2cffe41758f28e05c756a3a98d16f41",
    "tree-sitter-grammars/tree-sitter-xml": "5000ae8f22d11fbe93939b05c1e37cf21117162d",
    "tree-sitter-grammars/tree-sitter-yaml": "a1c4812a73ec5e089de8e441fdea3a921e8d5079",
    "tree-sitter-grammars/tree-sitter-zig": "6479aa13f32f701c383083d8b28360ebd682fb7d",
    "tree-sitter/tree-sitter-bash": "a06c2e4415e9bc0346c6b86d401879ffb44058f7",
    "tree-sitter/tree-sitter-c": "b780e47fc780ddc8da13afa35a3f4ed5c157823d",
    "tree-sitter/tree-sitter-c-sharp": "9150f7d56bb47f1a809fa23623f1ba1413e93fa9",
    "tree-sitter/tree-sitter-cpp": "c009222808634c1014f82438d4883753516a2c24",
    "tree-sitter/tree-sitter-css": "dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f",
    "tree-sitter/tree-sitter-go": "2346a3ab1bb3857b48b29d779a1ef9799a248cd7",
    "tree-sitter/tree-sitter-haskell": "0975ef72fc3c47b530309ca93937d7d143523628",
    "tree-sitter/tree-sitter-html": "73a3947324f6efddf9e17c0ea58d454843590cc0",
    "tree-sitter/tree-sitter-java": "e10607b45ff745f5f876bfa3e94fbcc6b44bdc11",
    "tree-sitter/tree-sitter-javascript": "58404d8cf191d69f2674a8fd507bd5776f46cb11",
    "tree-sitter/tree-sitter-json": "254c42a6476413b776221e03982ac8ae159eeb72",
    "tree-sitter/tree-sitter-julia": "e0f9dcd180fdcfcfa8d79a3531e11d99e79321d3",
    "tree-sitter/tree-sitter-php": "92b5271b60bec77fb65b5e5bc41561e8dac81299",
    "tree-sitter/tree-sitter-python": "26855eabccb19c6abf499fbc5b8dc7cc9ab8bc64",
    "tree-sitter/tree-sitter-ruby": "ad907a69da0c8a4f7a943a7fe012712208da6dee",
    "tree-sitter/tree-sitter-rust": "77a3747266f4d621d0757825e6b11edcbf991ca5",
    "tree-sitter/tree-sitter-typescript": "75b3874edb2dc714fb1fd77a32013d0f8699989f",
}

REPO_OF = {g[0]: g[1] for g in GRAMMARS}
REPO_OF["typescript"] = "tree-sitter/tree-sitter-typescript"


def fetch(repo, ref, cache):
    path = os.path.join(cache, repo.replace("/", "__") + "@" + ref)
    if os.path.isdir(path):
        return path
    url = f"https://codeload.github.com/{repo}/tar.gz/{ref}"
    data = urllib.request.urlopen(url).read()
    tmp = path + ".tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        tar.extractall(tmp)
    top = os.path.join(tmp, os.listdir(tmp)[0])
    os.rename(top, path)
    shutil.rmtree(tmp)
    return path


def copy_tree(src, dst, keep):
    for dirpath, _, files in os.walk(src):
        for f in files:
            if keep(f):
                rel = os.path.relpath(os.path.join(dirpath, f), src)
                os.makedirs(os.path.dirname(os.path.join(dst, rel)), exist_ok=True)
                shutil.copy(os.path.join(dirpath, f), os.path.join(dst, rel))


def licence_file(repo_dir):
    for name in sorted(os.listdir(repo_dir)):
        if name.upper().startswith(("LICENSE", "LICENCE", "COPYING")):
            return os.path.join(repo_dir, name)
    raise SystemExit(f"no licence in {repo_dir}")


def main():
    cache = sys.argv[sys.argv.index("--cache") + 1] if "--cache" in sys.argv else os.path.join(ROOT, ".build", "vendor-cache")
    os.makedirs(cache, exist_ok=True)

    # Runtime.
    rt = fetch(*RUNTIME, cache)
    out = os.path.join(ROOT, "Sources", "CTreeSitter")
    shutil.rmtree(out, ignore_errors=True)
    copy_tree(os.path.join(rt, "lib", "src"), os.path.join(out, "src"),
              lambda f: f.endswith((".c", ".h")))
    copy_tree(os.path.join(rt, "lib", "include"), os.path.join(out, "include"), lambda f: f.endswith(".h"))
    shutil.copy(licence_file(rt), os.path.join(out, "LICENSE"))

    # Grammars.
    gout = os.path.join(ROOT, "Sources", "CTreeSitterGrammars")
    shutil.rmtree(gout, ignore_errors=True)
    lic = os.path.join(gout, "LICENSES")
    os.makedirs(lic)
    repos = {}
    manifest = [f"tree-sitter runtime: https://github.com/{RUNTIME[0]} @ {RUNTIME[1]} (MIT)\n\n"]
    queries = {}
    for gid, repo, sub, qfiles in GRAMMARS:
        commit = COMMITS[repo]
        repo_dir = repos.setdefault(repo, fetch(repo, commit, cache))
        src = os.path.join(repo_dir, sub, "src")
        if not os.path.exists(os.path.join(src, "parser.c")):
            subprocess.run(["npx", "-y", f"tree-sitter-cli@{RUNTIME[1].lstrip('v')}", "generate"],
                           cwd=os.path.join(repo_dir, sub), check=True)
        dst = os.path.join(gout, gid)
        # tree-sitter-swift also ships parser_abi13.c / parser_abi14.c copies.
        copy_tree(src, dst, lambda f: f.endswith((".c", ".h")) and not f.startswith("parser_abi"))
        # typescript/tsx, php and xml share a scanner header at the repo root;
        # inline it so each grammar directory is self-contained.
        for name in os.listdir(dst):
            if not name.endswith(".c"):
                continue
            path = os.path.join(dst, name)
            text = open(path).read()
            if "#include <tree_sitter/" in text:
                # Angled includes would find another grammar's (or the
                # runtime's) headers first; keep each grammar on its own.
                text = text.replace("#include <tree_sitter/parser.h>", '#include "tree_sitter/parser.h"')
                text = text.replace("#include <tree_sitter/alloc.h>", '#include "tree_sitter/alloc.h"')
                text = text.replace("#include <tree_sitter/array.h>", '#include "tree_sitter/array.h"')
                with open(path, "w") as f:
                    f.write(text)
            if '#include "../../common/scanner.h"' in text:
                # Inline it: its own `#include "tree_sitter/parser.h"` then
                # resolves next to scanner.c.
                header = open(os.path.join(repo_dir, "common", "scanner.h")).read()
                with open(path, "w") as f:
                    f.write(text.replace('#include "../../common/scanner.h"',
                                         "// Inlined from the grammar repo's common/scanner.h.\n" + header))
        shutil.copy(licence_file(repo_dir), os.path.join(lic, f"{gid}.txt"))
        manifest.append(f"{gid}: https://github.com/{repo} @ {commit} ({sub}/src)\n")
        parts = []
        for qrepo_id, qpath in qfiles:
            qrepo = REPO_OF[qrepo_id]
            qdir = repos.setdefault(qrepo, fetch(qrepo, COMMITS[qrepo], cache))
            parts.append(f"; {qrepo} {qpath}\n" + open(os.path.join(qdir, qpath)).read())
        local = os.path.join(ROOT, "Scripts", "queries", f"{gid}.scm")
        if os.path.exists(local):
            parts.append("; Scripts/queries/" + gid + ".scm\n" + open(local).read())
        queries[gid] = "\n".join(parts)
    with open(os.path.join(lic, "VENDORED.txt"), "w") as f:
        f.write("Generated by Scripts/vendor-tree-sitter.py. Do not edit the grammar sources by hand.\n\n")
        f.writelines(manifest)

    # Umbrella header.
    inc = os.path.join(gout, "include")
    os.makedirs(inc)
    with open(os.path.join(inc, "CTreeSitterGrammars.h"), "w") as f:
        f.write("// Generated by Scripts/vendor-tree-sitter.py.\n#ifndef C_TREE_SITTER_GRAMMARS_H\n"
                "#define C_TREE_SITTER_GRAMMARS_H\n\n"
                "// Each returns a `const TSLanguage *` (typed as `const void *` so this\n"
                "// header does not depend on the runtime's).\n")
        for gid, *_ in GRAMMARS:
            f.write(f"const void *tree_sitter_{gid}(void);\n")
        f.write("\n#endif\n")

    # Queries as Swift source.
    swift = os.path.join(ROOT, "Sources", "LipiHighlight", "GrammarQueries.swift")
    os.makedirs(os.path.dirname(swift), exist_ok=True)
    with open(swift, "w") as f:
        f.write("// Generated by Scripts/vendor-tree-sitter.py from each grammar's highlights.scm\n"
                "// (licences in Sources/CTreeSitterGrammars/LICENSES). Do not edit.\n\n"
                "enum GrammarQueries {\n    static let highlights: [String: String] = [\n")
        for gid in sorted(queries):
            body = queries[gid]
            assert '"####' not in body
            f.write(f'        "{gid}": ####"""\n{body}\n"""####,\n')
        f.write("    ]\n}\n")


if __name__ == "__main__":
    main()
