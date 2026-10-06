#include <windows.h>
#include <cstdio>
#include <string>
#include <iterator>

int wmain(int argc, wchar_t** argv) {
    if (argc != 2) return 2;
    std::wstring root = argv[1];
    if (!root.empty() && root.back() != L'\\') root += L'\\';
    const wchar_t* files[] = {L"vcruntime140.dll", L"vcruntime140_1.dll", L"msvcp140.dll",
        L"event.dll", L"event_core.dll", L"libcrypto-3-x64.dll", L"libssl-3-x64.dll"};
    if (GetModuleHandleW(L"vcruntime140.dll") || GetModuleHandleW(L"msvcp140.dll")) {
        std::fwprintf(stderr, L"Probe must start without a shared VC++ module.\n");
        return 3;
    }
    for (const auto* file : files) {
        const auto expected = root + file;
        auto module = LoadLibraryExW(expected.c_str(), nullptr,
            LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (!module) {
            std::fwprintf(stderr, L"Cannot load %ls: %lu\n", expected.c_str(), GetLastError());
            return 4;
        }
        wchar_t actual[32768]{};
        if (!GetModuleFileNameW(module, actual, static_cast<DWORD>(std::size(actual))) ||
            _wcsicmp(actual, expected.c_str()) != 0) {
            std::fwprintf(stderr, L"Module did not load from the installed Edge directory: %ls\n", file);
            return 5;
        }
        std::wprintf(L"PASS private dependency: %ls\n", file);
    }
    return 0;
}
