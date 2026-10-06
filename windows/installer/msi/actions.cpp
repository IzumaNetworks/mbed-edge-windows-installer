// SPDX-License-Identifier: Apache-2.0
// MSI properties become JSON data, never PowerShell code or command fragments.
#include <windows.h>
#include <msi.h>
#include <msiquery.h>
#include <wincrypt.h>
#include <shlobj.h>
#include <string>
#include <vector>
#include <stdexcept>
#include "config.h"

static std::wstring property(MSIHANDLE session, const wchar_t* name) {
    DWORD size = 0;
    wchar_t empty = 0;
    UINT result = MsiGetPropertyW(session, name, &empty, &size);
    if (result != ERROR_MORE_DATA && result != ERROR_SUCCESS) throw std::runtime_error("Property read failed");
    std::vector<wchar_t> buffer(static_cast<size_t>(size) + 1);
    DWORD capacity = size + 1;
    if (MsiGetPropertyW(session, name, buffer.data(), &capacity) != ERROR_SUCCESS) throw std::runtime_error("Property read failed");
    return std::wstring(buffer.data(), capacity);
}
static void log(MSIHANDLE session, const wchar_t* message) {
    MSIHANDLE record = MsiCreateRecord(0);
    if (record) {
        MsiRecordSetStringW(record, 0, message);
        MsiProcessMessage(session, INSTALLMESSAGE_INFO, record);
        MsiCloseHandle(record);
    }
}
static std::wstring json(const std::wstring& value) {
    std::wstring result = L"\"";
    for (wchar_t ch : value) {
        if (ch == L'"' || ch == L'\\') { result += L'\\'; result += ch; }
        else if (ch < 32) throw std::runtime_error("Control character in installer property");
        else result += ch;
    }
    return result + L"\"";
}
static std::wstring base64(const std::wstring& value) {
    int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (!length) throw std::runtime_error("UTF-8 conversion failed");
    std::vector<char> bytes(static_cast<size_t>(length));
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), bytes.data(), length, nullptr, nullptr)) throw std::runtime_error("UTF-8 conversion failed");
    DWORD size = 0;
    if (!CryptBinaryToStringW(reinterpret_cast<const BYTE*>(bytes.data()), static_cast<DWORD>(length), CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &size)) throw std::runtime_error("Base64 conversion failed");
    std::vector<wchar_t> buffer(size);
    if (!CryptBinaryToStringW(reinterpret_cast<const BYTE*>(bytes.data()), static_cast<DWORD>(length), CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, buffer.data(), &size)) throw std::runtime_error("Base64 conversion failed");
    return buffer.data();
}
static std::wstring join(std::wstring root, const std::wstring& child) {
    while (!root.empty() && root.back() == L'\\') root.pop_back();
    if (root.size() < 3 || root[1] != L':' || root[2] != L'\\') throw std::runtime_error("Expected local absolute MSI directory");
    return root + L"\\" + child;
}
static std::wstring booleanProperty(MSIHANDLE session, const wchar_t* name, const wchar_t* fallback) {
    auto value = property(session, name);
    if (value.empty()) value = fallback;
    if (value != L"0" && value != L"1") throw std::runtime_error("Installer boolean must be 0 or 1");
    return value;
}
static std::wstring knownFolder(REFKNOWNFOLDERID folder) {
    PWSTR path = nullptr;
    if (FAILED(SHGetKnownFolderPath(folder, 0, nullptr, &path))) throw std::runtime_error("Known folder unavailable");
    std::wstring result(path);
    CoTaskMemFree(path);
    return result;
}
static std::wstring payloadFolder() {
    return join(knownFolder(FOLDERID_ProgramFilesX64), L"Izuma\\EdgeMsiPayload" EDGE_FOLDER_SUFFIX L"\\" EDGE_VERSION);
}
extern "C" __declspec(dllexport) UINT __stdcall Prepare(MSIHANDLE session) {
    try {
        const auto payload = payloadFolder();
        // A public MSI directory property must never redirect SYSTEM script execution.
        if (_wcsicmp(property(session, L"PAYLOADDIR").c_str(), (payload + L"\\").c_str()) != 0) throw std::runtime_error("Payload directory cannot be overridden");
        const auto programs = knownFolder(FOLDERID_ProgramFilesX64);
        const auto data = knownFolder(FOLDERID_ProgramData);
        std::wstring mode = property(session, L"PROVISIONINGMODE");
        if (mode.empty()) mode = L"deferred";
        if (mode != L"deferred" && mode != L"developer" && mode != L"production") throw std::runtime_error("Invalid provisioning mode");
        auto monitor = property(session, L"INSTALLMONITOR");
        const bool explicitMonitor = !monitor.empty();
        if (monitor.empty()) {
            INSTALLSTATE installed = INSTALLSTATE_UNKNOWN, action = INSTALLSTATE_UNKNOWN;
            if (MsiGetFeatureStateW(session, L"Monitor", &installed, &action) != ERROR_SUCCESS) throw std::runtime_error("Cannot read monitor feature");
            monitor = (action == INSTALLSTATE_LOCAL || (action == INSTALLSTATE_UNKNOWN && installed == INSTALLSTATE_LOCAL)) ? L"1" : L"0";
        }
        if (monitor != L"0" && monitor != L"1") throw std::runtime_error("Invalid monitor option");
        if (explicitMonitor && property(session, L"REMOVE") != L"ALL" &&
            MsiSetFeatureStateW(session, L"Monitor", monitor == L"1" ? INSTALLSTATE_LOCAL : INSTALLSTATE_ABSENT) != ERROR_SUCCESS) throw std::runtime_error("Cannot set monitor feature");
        const std::wstring request = L"{\"action\":\"Apply\",\"serviceName\":" + json(EDGE_SERVICE_NAME) +
            L",\"appRoot\":" + json(join(programs, L"Izuma\\EdgeSetup" EDGE_FOLDER_SUFFIX)) +
            L",\"installRoot\":" + json(join(programs, L"Izuma\\EdgeCore" EDGE_FOLDER_SUFFIX)) +
            L",\"dataDirectory\":" + json(join(data, L"Izuma\\EdgeCore" EDGE_FOLDER_SUFFIX)) +
            L",\"bundleDirectory\":" + json(payload) +
            L",\"provisioningFile\":" + json(property(session, L"PROVISIONING")) +
            L",\"provisioningMode\":" + json(mode) +
            L",\"allowUnsigned\":" + std::to_wstring(EDGE_UNSIGNED) +
            L",\"signerThumbprint\":" + json(EDGE_CORE_SIGNER) +
            L",\"bundleSignerThumbprint\":" + json(EDGE_BUNDLE_SIGNER) +
            L",\"httpPort\":0,\"protocolPort\":7681,\"installMonitor\":" + monitor +
            L",\"monitorUserControl\":" + booleanProperty(session, L"MONITORUSERCONTROL", L"0") +
            L",\"monitorStartup\":" + booleanProperty(session, L"MONITORSTARTUP", L"1") +
            L",\"startService\":" + booleanProperty(session, L"STARTSERVICE", L"0") +
            L",\"monitorUserControlSpecified\":" + (property(session, L"MONITORUSERCONTROL").empty() ? L"0" : L"1") +
            L",\"monitorStartupSpecified\":" + (property(session, L"MONITORSTARTUP").empty() ? L"0" : L"1") +
            L",\"startServiceSpecified\":" + (property(session, L"STARTSERVICE").empty() ? L"0" : L"1") + L"}";
        const auto encoded = payload + L"|" + base64(request);
        for (const auto* action : {L"EdgeApply", L"EdgeRollback", L"EdgeCommit", L"EdgeUninstall", L"EdgeUndoUninstall", L"EdgeCommitUninstall"}) {
            if (MsiSetPropertyW(session, action, encoded.c_str()) != ERROR_SUCCESS) throw std::runtime_error("Cannot schedule deployment data");
        }
        return ERROR_SUCCESS;
    } catch (...) {
        log(session, L"Izuma Edge: invalid installation properties; deployment was not scheduled.");
        return ERROR_INSTALL_FAILURE;
    }
}
static UINT run(MSIHANDLE session, const wchar_t* action) {
    try {
        const auto data = property(session, L"CustomActionData");
        const auto separator = data.find(L'|');
        if (separator == std::wstring::npos) throw std::runtime_error("Missing custom action data");
        const auto payload = data.substr(0, separator);
        const auto encoded = data.substr(separator + 1);
        if (_wcsicmp(payload.c_str(), payloadFolder().c_str()) != 0 || payload.find_first_of(L"\"\r\n") != std::wstring::npos || encoded.empty() ||
            encoded.find_first_not_of(L"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=") != std::wstring::npos) throw std::runtime_error("Invalid custom action data");
        wchar_t system[MAX_PATH];
        if (!GetSystemDirectoryW(system, MAX_PATH)) throw std::runtime_error("System directory unavailable");
        const auto powershell = join(system, L"WindowsPowerShell\\v1.0\\powershell.exe");
        // RemoveFiles has deleted the MSI payload before uninstall commit runs.
        // Deployment keeps these protected maintenance helpers outside that cache.
        const bool uninstallCommit = wcscmp(action, L"CommitUninstall") == 0;
        const auto workingDirectory = uninstallCommit
            ? join(knownFolder(FOLDERID_ProgramFilesX64), L"Izuma\\EdgeSetup" EDGE_FOLDER_SUFFIX L"\\scripts")
            : payload;
        const auto script = join(workingDirectory, uninstallCommit ? L"msi-deploy.ps1" : L"scripts\\msi-deploy.ps1");
        std::wstring command = L"\"" + powershell + L"\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script +
            L"\" -Action " + action + L" -Parameters " + encoded;
        if (command.size() >= 32767) throw std::runtime_error("Installation properties too long");
        STARTUPINFOW startup{}; startup.cb = sizeof(startup);
        PROCESS_INFORMATION process{};
        if (!CreateProcessW(powershell.c_str(), command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, workingDirectory.c_str(), &startup, &process)) throw std::runtime_error("Deployment process failed");
        CloseHandle(process.hThread);
        const DWORD wait = WaitForSingleObject(process.hProcess, INFINITE);
        DWORD code = ERROR_INSTALL_FAILURE;
        const BOOL gotCode = GetExitCodeProcess(process.hProcess, &code);
        CloseHandle(process.hProcess);
        if (wait != WAIT_OBJECT_0 || !gotCode || code != ERROR_SUCCESS) {
            log(session, L"Izuma Edge deployment failed. Inspect deployment.log in the protected EdgeSetup directory.");
            return ERROR_INSTALL_FAILURE;
        }
        return ERROR_SUCCESS;
    } catch (...) {
        log(session, L"Izuma Edge: could not invoke the deployment helper.");
        return ERROR_INSTALL_FAILURE;
    }
}
extern "C" __declspec(dllexport) UINT __stdcall Apply(MSIHANDLE s) { return run(s, L"Apply"); }
extern "C" __declspec(dllexport) UINT __stdcall Rollback(MSIHANDLE s) { return run(s, L"Rollback"); }
extern "C" __declspec(dllexport) UINT __stdcall Commit(MSIHANDLE s) { return run(s, L"Commit"); }
extern "C" __declspec(dllexport) UINT __stdcall Uninstall(MSIHANDLE s) { return run(s, L"Uninstall"); }
extern "C" __declspec(dllexport) UINT __stdcall UndoUninstall(MSIHANDLE s) { return run(s, L"UndoUninstall"); }
extern "C" __declspec(dllexport) UINT __stdcall CommitUninstall(MSIHANDLE s) { return run(s, L"CommitUninstall"); }
