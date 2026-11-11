// LiveChar camera helper.
// Registers the "LiveChar Camera" Windows 11 virtual camera for as long as the LiveChar app wants it,
// and owns the shared memory the app writes frames into.
//
// Usage: LiveCharCam.exe <parent process id> [class id]
// Prints "READY" or "ERROR 0x........ <step>" on stdout. Exits when the parent exits or stdin closes.
#include "framework.h"
#include "tools.h"
#include "VCamSample.h"
#include <sddl.h>

// 3b1915c6-4007-4040-8a70-ebce24ed2a23 (must match VCamSampleSource/dllmain.cpp)
static GUID CLSID_VCam = { 0x3b1915c6,0x4007,0x4040,{0x8a,0x70,0xeb,0xce,0x24,0xed,0x2a,0x23} };

#define LCV_WIDTH 1280
#define LCV_HEIGHT 720
#define LCV_HEADER_SIZE 64
#define LCV_SECTION_NAME L"Local\\LiveCharVCamFrame"

static void Say(const char* text)
{
	auto out = GetStdHandle(STD_OUTPUT_HANDLE);
	if (out && out != INVALID_HANDLE_VALUE)
	{
		DWORD written;
		WriteFile(out, text, (DWORD)strlen(text), &written, nullptr);
	}
}

static int Fail(HRESULT hr, const char* step)
{
	char text[128];
	StringCchPrintfA(text, _countof(text), "ERROR 0x%08X %s\n", (unsigned)hr, step);
	Say(text);
	return 1;
}

// Shared memory for frames. The camera source runs inside Windows services, so they need read access.
static HANDLE CreateFrameSection()
{
	// interactive users: read + write; everyone else (the camera services): read
	PSECURITY_DESCRIPTOR sd = nullptr;
	if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:(A;;GRGW;;;IU)(A;;GR;;;WD)", SDDL_REVISION_1, &sd, nullptr))
		return nullptr;

	SECURITY_ATTRIBUTES sa{};
	sa.nLength = sizeof(sa);
	sa.lpSecurityDescriptor = sd;
	const DWORD size = LCV_HEADER_SIZE + LCV_WIDTH * LCV_HEIGHT * 4;
	auto section = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE, 0, size, LCV_SECTION_NAME);
	LocalFree(sd);
	return section;
}

static DWORD WINAPI WaitForStdinClose(LPVOID param)
{
	auto in = GetStdHandle(STD_INPUT_HANDLE);
	if (in && in != INVALID_HANDLE_VALUE)
	{
		char buffer[16];
		DWORD read;
		while (ReadFile(in, buffer, sizeof(buffer), &read, nullptr) && read)
		{
		}
		SetEvent((HANDLE)param);
	}
	return 0;
}

int APIENTRY wWinMain(_In_ HINSTANCE hInstance, _In_opt_ HINSTANCE hPrevInstance, _In_ LPWSTR lpCmdLine, _In_ int nCmdShow)
{
	UNREFERENCED_PARAMETER(hInstance);
	UNREFERENCED_PARAMETER(hPrevInstance);
	UNREFERENCED_PARAMETER(nCmdShow);

	WinTraceRegister();
	WINTRACE(L"LiveCharCam starting '%s'", GetCommandLineW());

	// arguments: <parent pid> [class id of another camera source, for testing]
	unsigned long parentPid = 0;
	wchar_t otherClsid[64]{};
	if (lpCmdLine)
	{
		swscanf_s(lpCmdLine, L"%lu %63s", &parentPid, otherClsid, (unsigned)_countof(otherClsid));
	}
	auto section = CreateFrameSection(); // not fatal: the app falls back to a file

	winrt::init_apartment();
	auto hr = MFStartup(MF_VERSION);
	if (FAILED(hr))
		return Fail(hr, "MFStartup");

	int exitCode = 0;
	{
		wil::com_ptr_nothrow<IMFVirtualCamera> vcam;
		std::wstring clsid = otherClsid[0] ? std::wstring(otherClsid) : GUID_ToStringW(CLSID_VCam);
		hr = MFCreateVirtualCamera(
			MFVirtualCameraType_SoftwareCameraSource,
			MFVirtualCameraLifetime_Session,
			MFVirtualCameraAccess_CurrentUser,
			L"LiveChar Camera",
			clsid.c_str(),
			nullptr,
			0,
			&vcam);
		if (FAILED(hr))
		{
			exitCode = Fail(hr, "MFCreateVirtualCamera");
		}
		else if (FAILED(hr = vcam->Start(nullptr)))
		{
			exitCode = Fail(hr, "Start");
		}
		else
		{
			Say(section ? "READY section\n" : "READY file\n");

			// stay until the app goes away or asks us to stop (closes our stdin)
			HANDLE waits[2]{};
			DWORD count = 0;
			auto stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
			if (stop)
			{
				waits[count++] = stop;
				auto thread = CreateThread(nullptr, 0, WaitForStdinClose, stop, 0, nullptr);
				if (thread)
				{
					CloseHandle(thread);
				}
			}

			auto parent = parentPid ? OpenProcess(SYNCHRONIZE, FALSE, parentPid) : nullptr;
			if (parent)
			{
				waits[count++] = parent;
			}

			if (count)
			{
				WaitForMultipleObjects(count, waits, FALSE, INFINITE);
			}
			else
			{
				Sleep(INFINITE);
			}

			// NOTE: Remove only (no Shutdown), see the original sample
			auto removed = vcam->Remove();
			WINTRACE(L"Remove VCam hr:0x%08X", removed);
			if (parent)
			{
				CloseHandle(parent);
			}
		}
	}

	MFShutdown();
	if (section)
	{
		CloseHandle(section);
	}

	WINTRACE(L"LiveCharCam exiting");
	WinTraceUnregister();
	return exitCode;
}
