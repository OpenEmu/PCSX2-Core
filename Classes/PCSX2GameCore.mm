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
#include "../pcsx2/pcsx2/gui/AppConfig.h"
#include "../pcsx2/pcsx2/gui/App.h"
#include "../pcsx2/pcsx2/SPU2/Global.h"
#include "../pcsx2/pcsx2/SPU2/SndOut.h"
//#include "gui/Dialogs/ModalPopups.h"
#undef BOOL

#include <wx/stdpaths.h>

bool renderswitch = false;

static __weak PCSX2GameCore *_current;
//__aligned16 AppCorePlugins CorePlugins;
//
//SysCorePlugins& GetCorePlugins()
//{
//	return CorePlugins;
//}
//
//wxString AppConfig::FullpathToBios() const				{ return Path::Combine( Folders.Bios, BaseFilenames.Bios ); }

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

SysMainMemory& GetVmMemory()
{
	return wxGetApp().GetVmReserve();
}

SysCpuProviderPack& GetCpuProviders()
{
	return *wxGetApp().m_CpuProviders;
}

wxDirName GetProgramDataDir()
{
	GET_CURRENT_OR_RETURN(wxDirName(""));
	return wxDirName([NSBundle bundleForClass:[current class]].resourceURL.fileSystemRepresentation);
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

wxStandardPaths& Pcsx2AppTraits::GetStandardPaths()
{
	static Pcsx2StandardPaths stdPaths;
	return stdPaths;
}

// --------------------------------------------------------------------------------------
//  SynchronousActionState Implementations
// --------------------------------------------------------------------------------------

void SynchronousActionState::SetException(const BaseException& ex)
{
	m_exception = ScopedExcept(ex.Clone());
}

void SynchronousActionState::SetException(BaseException* ex)
{
	if (!m_posted)
	{
		m_exception = ScopedExcept(ex);
	}
	else if (wxTheApp)
	{
		// transport the exception to the main thread, since the message is fully
		// asynchronous, or has already entered an asynchronous state.  Message is sent
		// as a non-blocking action since proper handling of user errors on async messages
		// is *usually* to log/ignore it (hah), or to suspend emulation and issue a dialog
		// box to the user.

		pxExceptionEvent ev(ex);
		wxTheApp->AddPendingEvent(ev);
	}
}

void SynchronousActionState::RethrowException() const
{
	if (m_exception)
		m_exception->Rethrow();
}

int SynchronousActionState::WaitForResult()
{
	m_sema.WaitNoCancel();
	RethrowException();
	return return_value;
}

int SynchronousActionState::WaitForResult_NoExceptions()
{
	m_sema.WaitNoCancel();
	return return_value;
}

void SynchronousActionState::PostResult(int res)
{
	return_value = res;
	PostResult();
}

void SynchronousActionState::ClearResult()
{
	m_posted = false;
	m_exception = NULL;
}

void SynchronousActionState::PostResult()
{
	if (m_posted)
		return;
	m_posted = true;
	m_sema.Post();
}

wxDEFINE_EVENT(pxEvt_StartIdleEventTimer, wxCommandEvent);
wxDEFINE_EVENT(pxEvt_DeleteObject, wxCommandEvent);
wxDEFINE_EVENT(pxEvt_DeleteThread, wxCommandEvent);
wxDEFINE_EVENT(pxEvt_InvokeAction, pxActionEvent);
wxDEFINE_EVENT(pxEvt_SynchronousCommand, pxSynchronousCommandEvent);

wxIMPLEMENT_DYNAMIC_CLASS(pxSimpleEvent, wxEvent);

// --------------------------------------------------------------------------------------
//  pxActionEvent Implementations
// --------------------------------------------------------------------------------------

wxIMPLEMENT_DYNAMIC_CLASS(pxActionEvent, wxEvent);

pxActionEvent::pxActionEvent(SynchronousActionState* sema, int msgtype)
	: wxEvent(0, msgtype)
{
	m_state = sema;
}

pxActionEvent::pxActionEvent(SynchronousActionState& sema, int msgtype)
	: wxEvent(0, msgtype)
{
	m_state = &sema;
}

pxActionEvent::pxActionEvent(const pxActionEvent& src)
	: wxEvent(src)
{
	m_state = src.m_state;
}

void pxActionEvent::SetException(const BaseException& ex)
{
	SetException(ex.Clone());
}

void pxActionEvent::SetException(BaseException* ex)
{
	const wxString& prefix(pxsFmt(L"(%s) ", GetClassInfo()->GetClassName()));
	ex->DiagMsg() = prefix + ex->DiagMsg();

	if (!m_state)
	{
		ScopedExcept exptr(ex); // auto-delete it after handling.
		ex->Rethrow();
	}

	m_state->SetException(ex);
}

// --------------------------------------------------------------------------------------
//  pxExceptionEvent implementations
// --------------------------------------------------------------------------------------
pxExceptionEvent::pxExceptionEvent(const BaseException& ex)
{
	m_except = ex.Clone();
}

void pxExceptionEvent::InvokeEvent()
{
	ScopedExcept deleteMe(m_except);
	if (deleteMe)
		deleteMe->Rethrow();
}

// --------------------------------------------------------------------------------------
//  CoreThreadStatusEvent Implementations
// --------------------------------------------------------------------------------------
CoreThreadStatusEvent::CoreThreadStatusEvent( CoreThreadStatus evt, SynchronousActionState* sema )
	: pxActionEvent( sema )
{
	m_evt = evt;
}

CoreThreadStatusEvent::CoreThreadStatusEvent( CoreThreadStatus evt, SynchronousActionState& sema )
	: pxActionEvent( sema )
{
	m_evt = evt;
}

void CoreThreadStatusEvent::InvokeEvent()
{
	sApp.DispatchEvent( m_evt );
}


void OSDlog(ConsoleColors color, bool console, const std::string& str)
{
}

wxString pxGetAppName()
{
	return wxString("OpenEmu");
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
