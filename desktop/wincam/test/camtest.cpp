// Test tool: open the "LiveChar Camera" like any app would and print a few pixels of a frame.
// Build: cl /EHsc /std:c++20 camtest.cpp /link mfplat.lib mf.lib mfreadwrite.lib mfuuid.lib ole32.lib
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <stdio.h>
#include <wchar.h>

#define CHECK(step) if (FAILED(hr)) { printf("FAIL 0x%08X %s\n", (unsigned)hr, step); return 3; }

int wmain(int argc, wchar_t** argv)
{
	const wchar_t* wanted = argc > 1 ? argv[1] : L"LiveChar";
	auto hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED); CHECK("CoInitializeEx");
	hr = MFStartup(MF_VERSION); CHECK("MFStartup");

	IMFAttributes* attrs = nullptr;
	hr = MFCreateAttributes(&attrs, 1); CHECK("MFCreateAttributes");
	attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
	IMFActivate** devices = nullptr;
	UINT32 count = 0;
	hr = MFEnumDeviceSources(attrs, &devices, &count); CHECK("MFEnumDeviceSources");
	printf("cameras: %u\n", count);

	IMFActivate* found = nullptr;
	for (UINT32 i = 0; i < count; i++)
	{
		wchar_t* name = nullptr; UINT32 len = 0;
		if (SUCCEEDED(devices[i]->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &len)))
		{
			printf("  camera: %ls\n", name);
			if (!found && wcsstr(name, wanted)) found = devices[i];
			CoTaskMemFree(name);
		}
	}
	if (!found) { printf("FAIL camera not listed\n"); return 2; }

	IMFMediaSource* source = nullptr;
	hr = found->ActivateObject(IID_PPV_ARGS(&source)); CHECK("ActivateObject");
	IMFAttributes* readerAttrs = nullptr;
	MFCreateAttributes(&readerAttrs, 1);
	readerAttrs->SetUINT32(MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, TRUE);
	IMFSourceReader* reader = nullptr;
	hr = MFCreateSourceReaderFromMediaSource(source, readerAttrs, &reader); CHECK("MFCreateSourceReaderFromMediaSource");

	// native formats the camera offers
	for (DWORD i = 0; ; i++)
	{
		IMFMediaType* native = nullptr;
		if (FAILED(reader->GetNativeMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, i, &native))) break;
		GUID sub{}; UINT32 w = 0, h = 0;
		native->GetGUID(MF_MT_SUBTYPE, &sub); MFGetAttributeSize(native, MF_MT_FRAME_SIZE, &w, &h);
		printf("  native format %lu: %c%c%c%c %ux%u\n", i, (char)(sub.Data1 & 0xff) > 31 ? (char)(sub.Data1 & 0xff) : '#', (char)((sub.Data1 >> 8) & 0xff) > 31 ? (char)((sub.Data1 >> 8) & 0xff) : '#',
			(char)((sub.Data1 >> 16) & 0xff) > 31 ? (char)((sub.Data1 >> 16) & 0xff) : '#', (char)((sub.Data1 >> 24) & 0xff) > 31 ? (char)((sub.Data1 >> 24) & 0xff) : '#', w, h);
		native->Release();
	}

	IMFMediaType* type = nullptr;
	MFCreateMediaType(&type);
	type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
	type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
	hr = reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, type); CHECK("SetCurrentMediaType RGB32");
	IMFMediaType* current = nullptr;
	hr = reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &current); CHECK("GetCurrentMediaType");
	UINT32 width = 0, height = 0;
	MFGetAttributeSize(current, MF_MT_FRAME_SIZE, &width, &height);
	INT32 stride = (INT32)MFGetAttributeUINT32(current, MF_MT_DEFAULT_STRIDE, width * 4);
	printf("reading %ux%u stride %d\n", width, height, stride);

	int frames = 0;
	for (int i = 0; i < 300 && frames < 30; i++)
	{
		DWORD stream = 0, flags = 0; LONGLONG time = 0; IMFSample* sample = nullptr;
		hr = reader->ReadSample((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &stream, &flags, &time, &sample); CHECK("ReadSample");
		if (flags & MF_SOURCE_READERF_ENDOFSTREAM) { printf("FAIL end of stream\n"); return 4; }
		if (!sample) continue;
		frames++;
		if (frames == 30)
		{
			IMFMediaBuffer* buffer = nullptr;
			hr = sample->ConvertToContiguousBuffer(&buffer); CHECK("ConvertToContiguousBuffer");
			BYTE* data = nullptr; DWORD length = 0;
			hr = buffer->Lock(&data, nullptr, &length); CHECK("Lock");
			auto px = [&](UINT x, UINT y)
				{
					UINT row = stride < 0 ? height - 1 - y : y;
					const BYTE* p = data + (size_t)row * width * 4 + (size_t)x * 4;
					printf("%u,%u,%u", p[0], p[1], p[2]);
				};
			printf("PIXELS(BGR) topleft="); px(5, 5); printf(" center="); px(width / 2, height / 2);
			printf(" left="); px(100, height / 2); printf(" right="); px(width - 100, height / 2); printf("\n");
			buffer->Unlock(); buffer->Release();
		}
		sample->Release();
	}
	printf(frames >= 30 ? "OK frames=%d\n" : "FAIL only %d frames\n", frames);
	reader->Release(); source->Shutdown(); source->Release();
	MFShutdown();
	return frames >= 30 ? 0 : 5;
}
