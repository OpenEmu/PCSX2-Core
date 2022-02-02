// Copyright (c) 2021, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

#import "PCSX2GameCore.h"

#define BOOL PCSX2BOOL
#include "../pcsx2/pcsx2/PrecompiledHeader.h"
//#include "../pcsx2/pcsx2/Plugins.h"
#include "../pcsx2/pcsx2/GS.h"
#include "../pcsx2/pcsx2/Host.h"
#include "../pcsx2/pcsx2/HostDisplay.h"
#include "../pcsx2/pcsx2/VMManager.h"
//#include "../pcsx2/pcsx2/gui/AppConfig.h"
#include "../pcsx2/pcsx2/SPU2/Global.h"
#include "../pcsx2/pcsx2/SPU2/SndOut.h"
#include "MTVU.h"
#undef BOOL

#include <wx/stdpaths.h>

bool renderswitch = false;

namespace GSDump
{
	bool isRunning = false;
}

static __weak PCSX2GameCore *_current;

@implementation PCSX2GameCore

- (oneway void)didMovePS2JoystickDirection:(OEPS2Button)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
	
}

- (oneway void)didPushPS2Button:(OEPS2Button)button forPlayer:(NSUInteger)player
{
	
}

- (oneway void)didReleasePS2Button:(OEPS2Button)button forPlayer:(NSUInteger)player {
	
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
	if (error) {
		*error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:nil];
	}
	return NO;
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:nil]);
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:nil]);
}

- (void)resetEmulation
{
	
}

- (void)stopEmulation
{
	[super stopEmulation];
}

- (OEIntSize)aspectSize
{
	return (OEIntSize){ 4, 3 };
}

- (BOOL)tryToResizeVideoTo:(OEIntSize)size
{
	return YES;
}

- (OEGameCoreRendering)gameCoreRendering
{
	return OEGameCoreRenderingOpenGL3Video;
}

- (NSUInteger)channelCount
{
	return 2;
}

- (NSUInteger)audioBitDepth
{
	return 16;
}

- (double)audioSampleRate
{
	return 44100;
}

- (OEIntSize)bufferSize
{
	return (OEIntSize){ 640, 480 };
}

- (void)executeFrame
{
	
}

@end

alignas(16) static SysMtgsThread s_mtgs_thread;

SysMtgsThread& GetMTGS()
{
	return s_mtgs_thread;
}

#pragma mark - Host Namespace

std::optional<std::vector<u8>> Host::ReadResourceFile(const char* filename)
{
	GET_CURRENT_OR_RETURN({});
	return {};
}

std::optional<std::string> Host::ReadResourceFileToString(const char* filename)
{
	return {};
}

void Host::AddOSDMessage(std::string message, float duration)
{
	
}

void Host::AddKeyedOSDMessage(std::string key, std::string message, float duration)
{
	
}

void Host::AddFormattedOSDMessage(float duration, const char* format, ...)
{
	
}

void Host::AddKeyedFormattedOSDMessage(std::string key, float duration, const char* format, ...)
{
	
}

void Host::RemoveKeyedOSDMessage(std::string key)
{
	
}

void Host::ClearOSDMessages()
{
	
}


void Host::ReportErrorAsync(const std::string_view& title, const std::string_view& message)
{
	
}

#pragma mark Host Thread
void Host::OnVMStarting()
{
	
}

void Host::OnVMStarted()
{
	
}

void Host::OnVMDestroyed()
{
	
}

void Host::OnVMPaused()
{
	
}

void Host::OnVMResumed()
{
	
}

void Host::OnSaveStateLoading(const std::string_view& filename)
{
	
}

void Host::OnSaveStateLoaded(const std::string_view& filename, bool was_successful)
{
	
}

void Host::OnSaveStateSaved(const std::string_view& filename)
{
	
}

void Host::OnGameChanged(const std::string& disc_path, const std::string& game_serial, const std::string& game_name, u32 game_crc)
{
	
}

void Host::PumpMessagesOnCPUThread()
{
	
}

void Host::InvalidateSaveStateCache()
{
	
}

void Host::RequestResizeHostDisplay(s32 width, s32 height)
{
	
}

void Host::RunOnCPUThread(std::function<void()> function, bool block)
{
	
}

#pragma mark Host Display

HostDisplay* Host::AcquireHostDisplay(HostDisplay::RenderAPI api)
{
	return nil;
}

void Host::ReleaseHostDisplay()
{
	
}

HostDisplay* Host::GetHostDisplay()
{
	return nil;
}

/// Returns false if the window was completely occluded. If frame_skip is set, the frame won't be
/// displayed, but the GPU command queue will still be flushed.
bool Host::BeginPresentFrame(bool frame_skip)
{
	return false;
}

void Host::EndPresentFrame()
{
	
}

void Host::ResizeHostDisplay(u32 new_window_width, u32 new_window_height, float new_window_scale)
{
	
}

void Host::UpdateHostDisplay()
{
	
}


#pragma mark -

void DspUpdate()
{
}

s32 DspLoadLibrary(wchar_t* fileName, int modnum)
{
	return 0;
}

//Hijack the SDL plug-in
struct SDLAudioMod : public SndOutModule
{
	static SDLAudioMod mod;
	std::string m_api;

	bool Init()
	{
		return true;
	}

	const wchar_t* GetIdent() const { return L"OEAudio"; }
	const wchar_t* GetLongName() const { return L"OpenEmu Audio"; }

	void Close()
	{
	}

	~SDLAudioMod() { Close(); }

	s32 Test() const { return 0; }
	int GetEmptySampleCount() { return 0; }

	void Configure(uptr parent) {}

	void ReadSettings()
	{
	}

	void WriteSettings() const
	{
	};

	void SetApiSettings(wxString api)
	{
	}

	void SetPaused(bool paused)
	{
	}

private:
//	SDL_AudioSpec spec;

	SDLAudioMod()
		: m_api("pulseaudio")
	{
		// Number of samples must be a multiple of packet size.
	}
};

SDLAudioMod SDLAudioMod::mod;

SndOutModule* const SDLOut = &SDLAudioMod::mod;

wxDirName GetProgramDataDir()
{
	GET_CURRENT_OR_RETURN(wxDirName(""));
	return wxDirName([NSBundle bundleForClass:[current class]].resourceURL.fileSystemRepresentation);
}

void UI_UpdateSysControls()
{
}

void UI_EnableSysActions()
{
}

void StateCopy_LoadFromSlot(uint slot, bool isFromBackup)
{
	// do nothing
}

class Pcsx2StandardPaths : public wxStandardPaths
{
public:
	virtual wxString GetExecutablePath() const
	{
		const char* system = [NSBundle bundleForClass:[PCSX2GameCore class]].resourceURL.fileSystemRepresentation;
		return system;
	}
	wxString GetResourcesDir() const
	{
		const char* system = [NSBundle bundleForClass:[PCSX2GameCore class]].resourceURL.fileSystemRepresentation;
		return system;
	}
	wxString GetUserLocalDataDir() const
	{
		PCSX2GameCore *current = _current;
		const char* savedir = current.batterySavesDirectoryPath.fileSystemRepresentation;
		return Path::Combine(savedir, "pcsx2");
	}
};

void OSDlog(ConsoleColors color, bool console, const std::string& str)
{
}

wxString pxGetAppName()
{
	return wxString("OpenEmu");
}

#pragma mark - Pcsx2App stubs

// Safe to remove these lines when this is handled properly.
#ifdef __WXMAC__
// Great joy....
#undef EBP
#undef ESP
#undef EDI
#undef ESI
#undef EDX
#undef EAX
#undef EBX
#undef ECX
#include <wx/osx/private.h>		// needed to implement the app!
#endif

WindowInfo g_gs_window_info;
