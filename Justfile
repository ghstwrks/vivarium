# Building and signing are one step on purpose.
#
# Virtualization.framework refuses to create a VZVirtualMachine without the
# com.apple.security.virtualization entitlement, and `swift build` produces an
# unsigned binary. Separating the two invites running a stale unsigned binary
# and reading the resulting failure as a framework problem.

binary_name := "viv"
entitlements := "Vivarium.entitlements"
release_binary := ".build/release/" + binary_name
debug_binary := ".build/debug/" + binary_name

default: build

# compile in release and ad-hoc sign with the virtualization entitlement
build:
    swift build -c release
    @just sign

# same, for a debug build
debug:
    swift build
    @just sign-debug

sign:
    codesign -s - --entitlements {{entitlements}} -f {{release_binary}}
    @codesign -d --entitlements - {{release_binary}} 2>&1 | grep -q virtualization \
        && echo "signed: {{release_binary}} carries com.apple.security.virtualization" \
        || (echo "ERROR: the entitlement is missing after signing" >&2; exit 1)

sign-debug:
    codesign -s - --entitlements {{entitlements}} -f {{debug_binary}}
    @codesign -d --entitlements - {{debug_binary}} 2>&1 | grep -q virtualization \
        && echo "signed: {{debug_binary}} carries com.apple.security.virtualization" \
        || (echo "ERROR: the entitlement is missing after signing" >&2; exit 1)

# build, sign, and run the entitlement/host preflight
check: build
    {{release_binary}} preflight

# build, sign, and preflight a specific IPSW
#   just preflight ~/Downloads/UniversalMac_27.0_26A5388g_Restore.ipsw
preflight ipsw: build
    {{release_binary}} preflight --ipsw {{ipsw}}

clean:
    swift package clean
    rm -rf .build
