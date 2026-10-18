#!/bin/sh
# run-gateway-leaks.sh — Ombra gateway leak-test orchestrator (host side):
# drives the shipped root-owned /usr/local/sbin/ombra-leak-probe in the live
# gateway over vmrun guest ops (a shipped image has no sshd; nothing is
# downloaded), prints the mirrored report, exits the probe's code
# (0 = all seven pass, else the failing count; FATAL here exits 125).
# Usage: run-gateway-leaks.sh <gateway.vmx>   (or: OMBRA_VMX=<path>)
# (env: OMBRA_VMRUN / OMBRA_GUEST_USER / OMBRA_GUEST_PASS — the password has no default)

set -u

VMRUN="${OMBRA_VMRUN:-/Applications/VMware Fusion.app/Contents/Public/vmrun}"
GUEST_USER="${OMBRA_GUEST_USER:-ombra}"
GUEST_PASS="${OMBRA_GUEST_PASS:-}"
GUEST_REPORT="/run/ombra-leak/report.txt"

usage() {
    sed -n '2,8p' "$0" | sed -E 's/^# ?//'
    exit 2
}

die() { echo "FATAL: $*" >&2; exit 125; }

gop() {
    "$VMRUN" -T fusion -gu "$GUEST_USER" -gp "$GUEST_PASS" "$@"
}

[ $# -le 1 ] || usage
[ -n "$GUEST_PASS" ] || die "OMBRA_GUEST_PASS is not set (the guest account ships locked; there is no default password)"
VMX="${1:-${OMBRA_VMX:-}}"
[ -n "$VMX" ] || usage
case "$VMX" in
    /*) ;;
    *) VMX="$(pwd)/$VMX" ;;
esac

[ -x "$VMRUN" ] || die "vmrun not executable: $VMRUN (set OMBRA_VMRUN)"
[ -f "$VMX" ] || die "vmx not found: $VMX"

echo "==== ombra gateway leak tests ===="
echo "target: $VMX (vmrun guest ops; guest reboots are NOT allowed)"
echo

# vmrun list flakes — one reading is never trusted
IN_LIST=''
i=0
while [ "$i" -lt 3 ]; do
    if "$VMRUN" list 2>/dev/null | grep -Fq "$VMX"; then
        IN_LIST=1
        break
    fi
    i=$((i + 1))
    [ "$i" -lt 3 ] && sleep 2
done
[ -n "$IN_LIST" ] || \
    die "$VMX is not in vmrun list — power it on in Fusion first (never from here)"

# a stale report left in the guest would masquerade as this run's output
gop runProgramInGuest "$VMX" /bin/rm -f "$GUEST_REPORT" \
    || die "guest ops failed (vmrun error above; open-vm-tools live? OMBRA_GUEST_USER/OMBRA_GUEST_PASS right?)"

echo "running the shipped probe as root (no streaming output — the report prints when it returns)"
gop runProgramInGuest "$VMX" /usr/bin/sudo /usr/local/sbin/ombra-leak-probe
RC=$?

HOST_REPORT=$(umask 077; mktemp "${TMPDIR:-/tmp}/ombra-leak-report.XXXXXX") || die "mktemp failed"
# the report's existence is what separates a probe result from a vmrun failure
if ! gop CopyFileFromGuestToHost "$VMX" "$GUEST_REPORT" "$HOST_REPORT"; then
    rm -f "$HOST_REPORT"
    die "no report came back — the probe never ran (vmrun failure, not a probe result)"
fi
echo
echo "==== probe report (guest:$GUEST_REPORT) ===="
cat "$HOST_REPORT"
rm -f "$HOST_REPORT"

gop runProgramInGuest "$VMX" /bin/rm -f "$GUEST_REPORT" >/dev/null 2>&1 || true

echo
if [ "$RC" -eq 0 ]; then
    echo "==== RESULT: PASS (7/7) — no leaks detected ===="
else
    echo "==== RESULT: FAIL ($RC/7) — see the FAIL lines above; do NOT weaken a failing test, report it ===="
fi
exit "$RC"
