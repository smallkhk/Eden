#include "pch.h"
#include "Undocumented.h"
#include "Tools.h"
#include "EnumNames.h"
#include "MFTools.h"
#include "FrameGenerator.h"
#include <wtsapi32.h>
#include <memory>

#pragma comment(lib, "wtsapi32")

static ULONGLONG UnixMs()
{
	FILETIME ft;
	GetSystemTimeAsFileTime(&ft);
	ULARGE_INTEGER u;
	u.LowPart = ft.dwLowDateTime;
	u.HighPart = ft.dwHighDateTime;
	return (u.QuadPart - 116444736000000000ULL) / 10000ULL;
}

// time stamp of the frame in this view, or 0 if it does not hold a frame of the right size
static ULONGLONG FrameTime(const BYTE* view, UINT width, UINT height)
{
	if (!view)
		return 0;

	static const char magic[8] = { 'L', 'C', 'V', 'C', 'A', 'M', '1', 0 };
	if (memcmp(view, magic, sizeof(magic)) != 0)
		return 0;

	UINT w, h;
	ULONGLONG ts;
	memcpy(&w, view + 8, sizeof(w));
	memcpy(&h, view + 12, sizeof(h));
	memcpy(&ts, view + 24, sizeof(ts));
	return (w == width && h == height) ? ts : 0;
}

static bool IsFresh(ULONGLONG ts, ULONGLONG now)
{
	if (!ts)
		return false;

	auto age = now > ts ? now - ts : ts - now;
	return age < LCV_STALE_MS;
}

HRESULT FrameGenerator::EnsureRenderTarget(UINT width, UINT height)
{
	RETURN_HR_IF(E_INVALIDARG, !width || !height);
	if (width != _width || height != _height || !_black)
	{
		_section.Close();
		_disk.Close();
		_width = width;
		_height = height;
		_black.reset(new (std::nothrow) BYTE[FrameBytes()]);
		RETURN_IF_NULL_ALLOC(_black);
		ZeroMemory(_black.get(), FrameBytes());
	}

	_lastOpenTry = 0;
	_frame = 0;
	return S_OK;
}

// LiveChar always builds samples on the CPU
const bool FrameGenerator::HasD3DManager() const
{
	return false;
}

HRESULT FrameGenerator::SetD3DManager(IUnknown*, UINT, UINT)
{
	return S_OK;
}

void FrameGenerator::OpenSection()
{
	const SIZE_T size = LCV_HEADER_SIZE + FrameBytes();
	auto tryName = [&](const wchar_t* name) -> bool
		{
			auto mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, name);
			if (!mapping)
				return false;

			auto view = (const BYTE*)MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, size);
			if (!view)
			{
				CloseHandle(mapping);
				return false;
			}

			// only keep a section somebody is writing to right now
			if (!IsFresh(FrameTime(view, _width, _height), UnixMs()))
			{
				UnmapViewOfFile(view);
				CloseHandle(mapping);
				return false;
			}

			_section.mapping = mapping;
			_section.view = view;
			WINTRACE(L"FrameGenerator opened section '%s'", name);
			return true;
		};

	// same session (the source can also be loaded inside the app that reads the camera)
	if (tryName(L"Local\\" LCV_SECTION_NAME))
		return;

	// the frame server runs in session 0: look in the users' sessions
	PWTS_SESSION_INFOW sessions = nullptr;
	DWORD count = 0;
	if (WTSEnumerateSessionsW(WTS_CURRENT_SERVER_HANDLE, 0, 1, &sessions, &count))
	{
		for (DWORD i = 0; i < count; i++)
		{
			wchar_t name[96];
			if (SUCCEEDED(StringCchPrintfW(name, _countof(name), L"Session\\%u\\" LCV_SECTION_NAME, sessions[i].SessionId)) && tryName(name))
				break;
		}
		WTSFreeMemory(sessions);
	}
}

void FrameGenerator::OpenDiskFile()
{
	wchar_t path[MAX_PATH];
	auto len = ExpandEnvironmentStringsW(LCV_FILE_PATH, path, _countof(path));
	if (!len || len > _countof(path))
		return;

	auto file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
	if (file == INVALID_HANDLE_VALUE)
		return;

	const SIZE_T size = LCV_HEADER_SIZE + FrameBytes();
	LARGE_INTEGER fileSize{};
	if (!GetFileSizeEx(file, &fileSize) || (ULONGLONG)fileSize.QuadPart < size)
	{
		CloseHandle(file);
		return;
	}

	auto mapping = CreateFileMappingW(file, nullptr, PAGE_READONLY, 0, 0, nullptr);
	if (!mapping)
	{
		CloseHandle(file);
		return;
	}

	auto view = (const BYTE*)MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, size);
	if (!view)
	{
		CloseHandle(mapping);
		CloseHandle(file);
		return;
	}

	_disk.file = file;
	_disk.mapping = mapping;
	_disk.view = view;
	WINTRACE(L"FrameGenerator opened file '%s'", path);
}

// BGRA rows (top-down) of the newest frame, or black when the app is not sending
const BYTE* FrameGenerator::CurrentPixels()
{
	auto now = UnixMs();
	auto sectionTime = FrameTime(_section.view, _width, _height);
	auto diskTime = FrameTime(_disk.view, _width, _height);
	auto sectionFresh = IsFresh(sectionTime, now);
	auto diskFresh = IsFresh(diskTime, now);

	if (!sectionFresh && !diskFresh)
	{
		// nothing live: look again once a second (the app may have started or restarted)
		auto tick = GetTickCount64();
		if (!_lastOpenTry || tick - _lastOpenTry >= 1000)
		{
			_lastOpenTry = tick;
			_section.Close();
			OpenSection();
			if (!_disk.view)
			{
				OpenDiskFile();
			}

			now = UnixMs();
			sectionTime = FrameTime(_section.view, _width, _height);
			diskTime = FrameTime(_disk.view, _width, _height);
			sectionFresh = IsFresh(sectionTime, now);
			diskFresh = IsFresh(diskTime, now);
		}
	}

	if (sectionFresh && (!diskFresh || sectionTime >= diskTime))
		return _section.view + LCV_HEADER_SIZE;

	if (diskFresh)
		return _disk.view + LCV_HEADER_SIZE;

	return _black.get();
}

HRESULT FrameGenerator::Generate(IMFSample* sample, REFGUID format, IMFSample** outSample)
{
	RETURN_HR_IF_NULL(E_POINTER, sample);
	RETURN_HR_IF_NULL(E_POINTER, outSample);
	*outSample = nullptr;
	RETURN_HR_IF(E_UNEXPECTED, !_black || !_width || !_height);

	wil::com_ptr_nothrow<IMFMediaBuffer> mediaBuffer;
	RETURN_IF_FAILED(sample->GetBufferByIndex(0, &mediaBuffer));
	wil::com_ptr_nothrow<IMF2DBuffer2> buffer2D;
	BYTE* scanline;
	LONG pitch;
	BYTE* start;
	DWORD length;
	RETURN_IF_FAILED(mediaBuffer->QueryInterface(IID_PPV_ARGS(&buffer2D)));
	RETURN_IF_FAILED(buffer2D->Lock2DSize(MF2DBuffer_LockFlags_Write, &scanline, &pitch, &start, &length));

	// regular HRESULT handling from here: the buffer must be unlocked on every path
	auto hr = S_OK;
	auto pixels = CurrentPixels();
	const LONG stride = (LONG)_width * 4;
	if (format == MFVideoFormat_NV12)
	{
		hr = RGB32ToNV12((BYTE*)pixels, (ULONG)FrameBytes(), stride, _width, _height, scanline, length, pitch);
	}
	else
	{
		const ULONG needed = (ULONG)(pitch < 0 ? -pitch : pitch) * _height;
		hr = (needed > length || (pitch < 0 ? -pitch : pitch) < stride) ? E_UNEXPECTED : S_OK;
		if (SUCCEEDED(hr))
		{
			for (UINT y = 0; y < _height; y++)
			{
				CopyMemory(scanline + (LONG_PTR)y * pitch, pixels + (SIZE_T)y * stride, stride);
			}
		}
	}

	buffer2D->Unlock2D();
	if (SUCCEEDED(hr))
	{
		_frame++;
		sample->AddRef();
		*outSample = sample;
	}
	return hr;
}
