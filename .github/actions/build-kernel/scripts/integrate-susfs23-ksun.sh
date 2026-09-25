#!/usr/bin/env bash
# KernelSU-Next + SUSFS v2.3.x compatibility shim.
#
# SUSFS' upstream 10_enable_susfs_for_ksu.patch targets official KernelSU.
# KernelSU-Next 3.3.x has a materially different hook/supercall architecture,
# so forcing that patch onto KSUN produces rejects and can discard KSUN logic.
#
# This shim follows the proven KSUN/SUSFS integration model used by kernels
# already shipping KSUN 3.3.0 + SUSFS 2.3.0:
#   * append the upstream SUSFS Kconfig menu
#   * graft SUSFS commands into KSUN's existing reboot supercall path
#   * initialize SUSFS from KSUN init without replacing KSUN's lifecycle
#   * provide the small SELinux/domain glue required by the fs-side patch
#   * trim raw-KernelSU-only hooks from the fs-side 50_ patch
#
# Args:
#   1: KernelSU-Next root (directory containing kernel/)
#   2: susfs4ksu root
#   3: common kernel root
#   4: SUSFS GKI branch, e.g. gki-android14-6.1

set -euo pipefail

KSUN_DIR="${1:?KernelSU-Next root required}"
SUSFS_DIR="${2:?susfs4ksu root required}"
KROOT="${3:?common kernel root required}"
SUSFS_GKI_BRANCH="${4:?SUSFS GKI branch required}"

P10="$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
P50="$SUSFS_DIR/kernel_patches/50_add_susfs_in_${SUSFS_GKI_BRANCH}.patch"
TRIMMED="$KROOT/susfs50-v23-ksun.patch"

[ -f "$P10" ] || { echo "::error::Missing SUSFS driver patch: $P10"; exit 1; }
[ -f "$P50" ] || { echo "::error::Missing SUSFS kernel patch: $P50"; exit 1; }
[ -d "$KSUN_DIR/kernel" ] || { echo "::error::Invalid KernelSU-Next tree: $KSUN_DIR"; exit 1; }

echo "Integrating SUSFS v2.3.x with KernelSU-Next without replacing KSUN hooks"

# 1) Add the SUSFS Kconfig menu verbatim from the upstream KernelSU patch.
python3 - "$P10" "$KSUN_DIR/kernel/Kconfig" <<'PY'
import re, sys
patch, target = sys.argv[1], sys.argv[2]
src = open(patch, encoding="utf-8", errors="replace").read()
code = open(target, encoding="utf-8").read()
if re.search(r'^config KSU_SUSFS$', code, re.M):
    print("  [=] KSU_SUSFS Kconfig already present")
    raise SystemExit(0)

m = re.search(r'diff --git a/kernel/Kconfig.*?(?=\ndiff --git |\Z)', src, re.S)
if not m:
    raise SystemExit("Kconfig section not found in SUSFS driver patch")
added = [ln[1:] for ln in m.group(0).splitlines()
         if ln.startswith('+') and not ln.startswith('+++')]
menu = "\n".join(added)
if 'config KSU_SUSFS' not in menu or 'endmenu' not in menu:
    raise SystemExit("Could not extract SUSFS Kconfig menu")

# Some upstream revisions contain list-looking help text without a help keyword.
fixed, in_stanza, seen_help = [], False, False
for ln in menu.splitlines():
    s = ln.strip()
    if s.startswith('config '):
        in_stanza, seen_help = True, False
    elif s.startswith('menu') or s == 'endmenu':
        in_stanza, seen_help = False, False
    elif s == 'help':
        seen_help = True
    elif in_stanza and s.startswith('- ') and not seen_help:
        fixed.append('\thelp')
        seen_help = True
    fixed.append(ln)

with open(target, 'a', encoding='utf-8') as f:
    f.write("\n" + "\n".join(fixed) + "\n")
print("  [+] appended SUSFS Kconfig menu")
PY

# 2) Graft the SUSFS command switch into KSUN's existing reboot handler.
python3 - "$P10" "$KSUN_DIR/kernel/supercall/supercall.c" <<'PY'
import re, sys
patch, target = sys.argv[1], sys.argv[2]
src = open(patch, encoding="utf-8", errors="replace").read()
code = open(target, encoding="utf-8").read()

if 'susfs command dispatch (KSUN compatibility)' in code:
    print("  [=] SUSFS supercall dispatch already present")
    raise SystemExit(0)

m = re.search(r'diff --git a/kernel/supercall/dispatch\.c.*?(?=\ndiff --git |\Z)', src, re.S)
if not m:
    raise SystemExit("dispatch.c section not found in SUSFS driver patch")
added = "\n".join(ln[1:] for ln in m.group(0).splitlines()
                   if ln.startswith('+') and not ln.startswith('+++'))
sm = re.search(r'switch\s*\(cmd\)\s*\{\n(.*?)\n\s*\}\n\s*\}', added, re.S)
if not sm:
    raise SystemExit("Could not extract SUSFS command switch")
switch_body = sm.group(1).rstrip()
if 'CMD_SUSFS_ADD_SUS_PATH' not in switch_body:
    raise SystemExit("Extracted command switch does not contain SUSFS commands")

# A kprobe pre-handler must return 0. The upstream dispatcher returns -EINVAL
# for unknown commands because it is a normal function.
switch_body = re.sub(r'default:\s*\n\s*return -EINVAL;',
                     'default:\n                return 0;',
                     switch_body)

uts_inc = '#include <linux/utsname.h> // utsname() and uts_sem\n'
if uts_inc in code and '#include <linux/susfs.h>' not in code:
    code = code.replace(
        uts_inc,
        uts_inc +
        '#ifdef CONFIG_KSU_SUSFS\n'
        '#include <linux/cred.h>\n'
        '#include <linux/sched.h>\n'
        '#include <linux/susfs.h>\n'
        '#endif\n',
        1)
elif '#include <linux/susfs.h>' not in code:
    # Keep a conservative fallback for small upstream include reordering.
    marker = '#include <linux/utsname.h>\n'
    if marker not in code:
        raise SystemExit("Could not find utsname include in KSUN supercall.c")
    code = code.replace(
        marker,
        marker +
        '#ifdef CONFIG_KSU_SUSFS\n'
        '#include <linux/cred.h>\n'
        '#include <linux/sched.h>\n'
        '#include <linux/susfs.h>\n'
        '#endif\n',
        1)

anchor = '    unsigned long reply = (unsigned long)arg4;\n'
if anchor not in code:
    raise SystemExit("Could not find KSUN reboot_handler_pre argument anchor")

dispatch = (
    '\n#ifdef CONFIG_KSU_SUSFS\n'
    '    /* susfs command dispatch (KSUN compatibility) */\n'
    '    if (magic2 == SUSFS_MAGIC && current_uid().val == 0) {\n'
    '        void __user *susfs_uptr = (void __user *)arg4;\n'
    '        void __user **arg = &susfs_uptr;\n'
    '        {\n'
    '            extern u32 susfs_ksu_sid;\n'
    '            extern void susfs_ksu_resolve_sids(void);\n'
    '            if (unlikely(!susfs_ksu_sid))\n'
    '                susfs_ksu_resolve_sids();\n'
    '        }\n'
    '        switch (cmd) {\n' + switch_body + '\n'
    '        }\n'
    '    }\n'
    '#endif\n'
)
code = code.replace(anchor, anchor + dispatch, 1)
open(target, 'w', encoding='utf-8').write(code)
print("  [+] grafted SUSFS command dispatch into KSUN reboot handler")
PY

# 3) Add the fs-side SELinux/domain glue without replacing KSUN's own
# SELinux-hide implementation.
python3 - "$KSUN_DIR/kernel/selinux/selinux.c" <<'PY'
import sys
target = sys.argv[1]
code = open(target, encoding='utf-8').read()
if 'susfs_is_current_ksu_domain(void)' in code:
    print("  [=] SUSFS SELinux glue already present")
    raise SystemExit(0)
if 'bool is_ksu_domain(' not in code:
    raise SystemExit("KSUN is_ksu_domain() API not found")
if 'security_secctx_to_secid(' not in code:
    raise SystemExit("KSUN security_secctx_to_secid() API not found")

glue = r'''
#ifdef CONFIG_KSU_SUSFS
#include <linux/jump_label.h>

u32 susfs_ksu_sid __read_mostly = 0;
u32 susfs_priv_app_sid __read_mostly = 0;

bool susfs_is_current_ksu_domain(void)
{
    return is_ksu_domain();
}

void susfs_ksu_resolve_sids(void)
{
    u32 sid = 0;

    if (!security_secctx_to_secid(KERNEL_SU_CONTEXT, strlen(KERNEL_SU_CONTEXT), &sid) &&
        sid > 1)
        susfs_ksu_sid = sid;

    sid = 0;
    if (!security_secctx_to_secid("u:r:priv_app:s0:c512,c768",
                                  strlen("u:r:priv_app:s0:c512,c768"), &sid) &&
        sid > 1)
        susfs_priv_app_sid = sid;

    pr_info("susfs: ksu_sid=%u priv_app_sid=%u\n",
            susfs_ksu_sid, susfs_priv_app_sid);
}

/*
 * These are raw-KernelSU manual-hook entry points referenced by the fs-side
 * SUSFS patch. KSUN uses its own kprobe hook path, so keep these inert while
 * preserving the symbols expected by the common kernel sources.
 */
int ksu_handle_stat(int *dfd, void *filename, int *flags) { return 0; }
void ksu_handle_vfs_fstat(int fd, void *kstat_size_ptr) { }
int ksu_handle_execveat(int *fd, void *filename_ptr, void *argv,
                        void *envp, int *flags) { return 0; }
int ksu_handle_execveat_sucompat(int *fd, void *filename_ptr, void *argv,
                                 void *envp, int *flags) { return 0; }
int ksu_handle_faccessat(int *dfd, void *filename_user, int *mode,
                         int *flags) { return 0; }

bool ksu_selinux_hide_running __read_mostly;
struct selinux_state fake_state;
DEFINE_STATIC_KEY_TRUE(ksu_is_init_rc_hook_enabled);
#endif
'''
code = code.rstrip() + '\n' + glue
open(target, 'w', encoding='utf-8').write(code)
print("  [+] added SUSFS domain/SID compatibility glue")
PY

# 4) Initialize SUSFS while preserving KSUN's own init/exit lifecycle.
python3 - "$KSUN_DIR/kernel/core/init.c" <<'PY'
import sys
target = sys.argv[1]
code = open(target, encoding='utf-8').read()
if 'susfs_ksu_resolve_sids' in code:
    print("  [=] SUSFS init glue already present")
    raise SystemExit(0)
anchor = '\tksu_supercalls_init();'
if anchor not in code:
    anchor = '    ksu_supercalls_init();'
if anchor not in code:
    raise SystemExit("Could not find ksu_supercalls_init() in KSUN init.c")
block = (
    '#ifdef CONFIG_KSU_SUSFS\n'
    '\t{ extern void susfs_init(void); susfs_init(); }\n'
    '\t{ extern void susfs_ksu_resolve_sids(void); susfs_ksu_resolve_sids(); }\n'
    '#endif\n'
)
code = code.replace(anchor, block + anchor, 1)
open(target, 'w', encoding='utf-8').write(code)
print("  [+] wired SUSFS initialization into KSUN")
PY

# 5) Build a filesystem-side patch with raw-KernelSU-only hooks removed.
# The remaining hunks are the actual SUSFS filesystem implementation and are
# still taken directly from the exact SUSFS revision selected by the workflow.
python3 - "$P50" "$TRIMMED" <<'PY'
import re, sys
src_path, out_path = sys.argv[1], sys.argv[2]
src = open(src_path, encoding='utf-8', errors='replace').read()
out = []

# KSUN supplies these facilities via its own driver/hook architecture.
drop_whole = (
    'a/kernel/reboot.c',
    'a/security/selinux/selinuxfs.c',
    'a/drivers/input/input.c',
    'a/fs/read_write.c',
)

for chunk in re.split(r'(?=^diff --git )', src, flags=re.M):
    if not chunk:
        continue
    if any(chunk.startswith('diff --git ' + p) for p in drop_whole):
        continue

    # Raw KernelSU calls ksu_handle_setresuid() directly from kernel/sys.c.
    # KSUN keeps its own setresuid hook, so remove only that hunk.
    if chunk.startswith('diff --git a/kernel/sys.c'):
        hunks = re.split(r'(?=^@@ )', chunk, flags=re.M)
        kept = [hunks[0]]
        for hunk in hunks[1:]:
            if 'ksu_handle_setresuid' not in hunk:
                kept.append(hunk)
        chunk = ''.join(kept)

    out.append(chunk)

result = ''.join(out)
if 'diff --git a/fs/namespace.c' not in result:
    raise SystemExit("Trimmed SUSFS patch unexpectedly lost fs/namespace.c")
open(out_path, 'w', encoding='utf-8').write(result)
print("  [+] prepared KSUN-safe fs-side SUSFS patch:", out_path)
PY

echo "SUSFS23_KSUN_PATCH=$TRIMMED" >> "${GITHUB_ENV:?GITHUB_ENV is required}"
echo "✅ SUSFS v2.3.x KernelSU-Next compatibility shim prepared"
