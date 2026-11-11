#pragma once
#include <memory>

// LiveChar: frames come from the LiveChar app (see ../README.md), not from a drawn test card.
#define LCV_HEADER_SIZE 64
#define LCV_SECTION_NAME L"LiveCharVCamFrame"
#define LCV_FILE_PATH L"%ProgramData%\\LiveChar\\vcam.frame"
#define LCV_STALE_MS 2000

struct FrameSourceView
{
	HANDLE file = INVALID_HANDLE_VALUE;
	HANDLE mapping = nullptr;
	const BYTE* view = nullptr;

	void Close()
	{
		if (view) { UnmapViewOfFile(view); view = nullptr; }
		if (mapping) { CloseHandle(mapping); mapping = nullptr; }
		if (file != INVALID_HANDLE_VALUE) { CloseHandle(file); file = INVALID_HANDLE_VALUE; }
	}
};

class FrameGenerator
{
	UINT _width;
	UINT _height;
	ULONGLONG _frame;
	ULONGLONG _lastOpenTry;
	FrameSourceView _section; // shared memory created by the helper in the user's session
	FrameSourceView _disk;    // fallback: file in ProgramData
	std::unique_ptr<BYTE[]> _black;

	SIZE_T FrameBytes() const { return (SIZE_T)_width * _height * 4; }
	void OpenSection();
	void OpenDiskFile();
	const BYTE* CurrentPixels();

public:
	FrameGenerator() :
		_width(0),
		_height(0),
		_frame(0),
		_lastOpenTry(0)
	{
	}

	~FrameGenerator()
	{
		_section.Close();
		_disk.Close();
	}

	HRESULT SetD3DManager(IUnknown* manager, UINT width, UINT height);
	const bool HasD3DManager() const;
	HRESULT EnsureRenderTarget(UINT width, UINT height);
	HRESULT Generate(IMFSample* sample, REFGUID format, IMFSample** outSample);
};
