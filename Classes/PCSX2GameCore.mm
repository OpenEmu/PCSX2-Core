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
#include "../pcsx2/pcsx2/Plugins.h"
#include "../pcsx2/pcsx2/GS.h"
#include "../pcsx2/pcsx2/gui/AppConfig.h"
#include "../pcsx2/pcsx2/gui/App.h"
#include "../pcsx2/pcsx2/SPU2/Global.h"
#include "../pcsx2/pcsx2/SPU2/SndOut.h"
//#include "gui/Dialogs/ModalPopups.h"
#undef BOOL

static __weak PCSX2GameCore *_current;
__aligned16 AppCorePlugins CorePlugins;

SysCorePlugins& GetCorePlugins()
{
	return CorePlugins;
}

wxString AppConfig::FullpathToBios() const				{ return Path::Combine( Folders.Bios, BaseFilenames.Bios ); }

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

//Hijack the SDL plug-in
struct SDLAudioMod : public SndOutModule
{
	static SDLAudioMod mod;
	std::string m_api;

	s32 Init()
	{
		return -1;
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

SysMainMemory& GetVmMemory()
{
	return wxGetApp().GetVmReserve();
}

SysCoreThread& GetCoreThread()
{
	return CoreThread;
}

SysMtgsThread& GetMTGS()
{
	return mtgsThread;
}

SysCpuProviderPack& GetCpuProviders()
{
	return *wxGetApp().m_CpuProviders;
}

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
wxIMPLEMENT_APP(Pcsx2App);
