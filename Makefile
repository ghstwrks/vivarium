# Building and signing are one step on purpose.
#
# Virtualization.framework refuses to create a VZVirtualMachine without the
# com.apple.security.virtualization entitlement, and `swift build` produces an
# unsigned binary. Separating the two invites running a stale unsigned binary
# and reading the resulting failure as a framework problem.

BINARY_NAME := vre-poc
ENTITLEMENTS := VREPOC.entitlements
RELEASE_BINARY := .build/release/$(BINARY_NAME)
DEBUG_BINARY := .build/debug/$(BINARY_NAME)

.PHONY: all build debug sign sign-debug clean preflight check

all: build

## build: compile in release and ad-hoc sign with the virtualization entitlement
build:
	swift build -c release
	@$(MAKE) --no-print-directory sign

## debug: same, for a debug build
debug:
	swift build
	@$(MAKE) --no-print-directory sign-debug

sign:
	codesign -s - --entitlements $(ENTITLEMENTS) -f $(RELEASE_BINARY)
	@codesign -d --entitlements - $(RELEASE_BINARY) 2>&1 | grep -q virtualization \
		&& echo "signed: $(RELEASE_BINARY) carries com.apple.security.virtualization" \
		|| (echo "ERROR: the entitlement is missing after signing" >&2; exit 1)

sign-debug:
	codesign -s - --entitlements $(ENTITLEMENTS) -f $(DEBUG_BINARY)
	@codesign -d --entitlements - $(DEBUG_BINARY) 2>&1 | grep -q virtualization \
		&& echo "signed: $(DEBUG_BINARY) carries com.apple.security.virtualization" \
		|| (echo "ERROR: the entitlement is missing after signing" >&2; exit 1)

## check: build, sign, and run the entitlement/host preflight
check: build
	$(RELEASE_BINARY) preflight

## preflight: build, sign, and preflight a specific IPSW
##   make preflight IPSW=~/Downloads/UniversalMac_27.0_26A5388g_Restore.ipsw
preflight: build
	@test -n "$(IPSW)" || (echo "usage: make preflight IPSW=<path to .ipsw>" >&2; exit 2)
	$(RELEASE_BINARY) preflight --ipsw $(IPSW)

clean:
	swift package clean
	rm -rf .build
