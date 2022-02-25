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
#import <OpenEmuBase/OETimingUtils.h>
#import <OpenEmuBase/OERingBuffer.h>
#include "Audio/OESndOut.h"
#include "Input/keymap.h"

#define BOOL PCSX2BOOL
#include "PrecompiledHeader.h"
#include "GS.h"
#include "HostSettings.h"
#include "HostDisplay.h"
#include "VMManager.h"
#include "AppConfig.h"
#include "Frontend/InputManager.h"
#include "Frontend/INISettingsInterface.h"
#include "Frontend/OpenGLHostDisplay.h"
#include "common/SettingsWrapper.h"
#include "CDVD/CDVDaccess.h"
#include "SPU2/Global.h"
#include "SPU2/SndOut.h"
#include "PAD/Host/KeyStatus.h"
#include "R3000A.h"
#include "MTVU.h"
#undef BOOL

#include <OpenGL/gl3.h>
#include <OpenGL/gl3ext.h>

std::unique_ptr<AppConfig> g_Conf;
static bool ExitRequested = false;

bool renderswitch = false;

namespace GSDump
{
	bool isRunning = false;
}

alignas(16) static SysMtgsThread s_mtgs_thread;
PCSX2GameCore *_current;

@interface PCSX2GameCore ()

@end

@implementation PCSX2GameCore {
	@package
	bool hasInitialized;
	NSString* gamePath;
	std::unique_ptr<INISettingsInterface> s_base_settings_interface;
	std::unique_ptr<HostDisplay> hostDisplay;
	
	VMBootParameters params;
}

- (instancetype)init
{
	if (self = [super init]) {
		_current = self;
		VMManager::InitializeMemory();
	}
	return self;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
	// PCSX2 can't handle cue files... but can read bin files
	if ([[path pathExtension] caseInsensitiveCompare:@"cue"] == NSOrderedSame) {
		// Assume the bin file is the same as the cue.
		gamePath = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"bin"];
	} else {
		gamePath = [path copy];
	}
	return true;
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	bool success = true; //VMManager::LoadState(fileName.fileSystemRepresentation);
	//block(success, success ? nil : [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{NSFilePathErrorKey: fileName}]);
	block(success, nil);
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	Console.Error("SaveState Requested");
	bool success = true ; //VMManager::SaveState(fileName.fileSystemRepresentation);
	//block(success, success ? nil : [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{NSFilePathErrorKey: fileName}]);
	block(success, nil);
}

- (void)setupEmulation
{
	const std::string pcsx2ini(Path::CombineStdString([self.supportDirectoryPath stringByAppendingPathComponent:@"/inis"].fileSystemRepresentation, "PCSX2.ini"));
	s_base_settings_interface = std::make_unique<INISettingsInterface>(std::move(pcsx2ini));
	Host::Internal::SetBaseSettingsLayer(s_base_settings_interface.get());
	
	//EmuConfig = Pcsx2Config();
	EmuFolders::SetDefaults();

	SettingsInterface& si = *s_base_settings_interface.get();
	si.SetUIntValue("UI", "SettingsVersion", 1);

	{
		SettingsSaveWrapper wrapper(si);
		EmuConfig.LoadSave(wrapper);
	}

	NSString *path = self.batterySavesDirectoryPath;
	if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:NULL]) {
		[[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
	}

	EmuFolders::MemoryCards = path.fileSystemRepresentation;
	EmuFolders::Bios = self.biosDirectoryPath.fileSystemRepresentation;
	EmuFolders::AppRoot = [[NSBundle bundleForClass:[self class]] resourceURL].fileSystemRepresentation;
	EmuFolders::DataRoot = self.supportDirectoryPath.fileSystemRepresentation;
	EmuFolders::Settings = [self.supportDirectoryPath stringByAppendingPathComponent:@"/inis"].fileSystemRepresentation;
	EmuFolders::Resources = [[NSBundle bundleForClass:[self class]] resourceURL].fileSystemRepresentation;
	EmuFolders::Cache = [self.supportDirectoryPath stringByAppendingPathComponent:@"/Cache"].fileSystemRepresentation;
	EmuFolders::Snapshots = [self.supportDirectoryPath stringByAppendingPathComponent:@"/snaps"].fileSystemRepresentation;
	EmuFolders::Savestates = [self.supportDirectoryPath stringByAppendingPathComponent:@"/sstates"].fileSystemRepresentation;
	EmuFolders::Logs = [self.supportDirectoryPath stringByAppendingPathComponent:@"/Logs"].fileSystemRepresentation;
	EmuFolders::Cheats = [self.supportDirectoryPath stringByAppendingPathComponent:@"/Cheats"].fileSystemRepresentation;
	EmuFolders::CheatsWS = [self.supportDirectoryPath stringByAppendingPathComponent:@"/cheats_ws"].fileSystemRepresentation;
	EmuFolders::Covers = [self.supportDirectoryPath stringByAppendingPathComponent:@"/Covers"].fileSystemRepresentation;
	EmuFolders::GameSettings = [self.supportDirectoryPath stringByAppendingPathComponent:@"/gamesettings"].fileSystemRepresentation;
	EmuFolders::EnsureFoldersExist();
	
	EmuConfig.Mcd[0].Enabled = true;
	EmuConfig.Mcd[0].Type = MemoryCardType::Folder;
	EmuConfig.Mcd[0].Filename = "Memory folder 1.ps2";

	EmuConfig.Mcd[1].Enabled = true;
	EmuConfig.Mcd[1].Type = MemoryCardType::Folder;
	EmuConfig.Mcd[1].Filename = "Memory folder 2.ps2";
	
	// TODO: select based on loaded game's region?
	EmuConfig.BaseFilenames.Bios = "scph39001.bin";
	
#ifdef DEBUG
	si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableEE", false);
#else
	si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableEE", true);
#endif
	si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableEECache", false);
	si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableIOP", true);
	si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU0", true);
	si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU1", true);
	si.SetStringValue("EmuCore/SPU2", "OutputModule", "NullOut");
	si.SetBoolValue("", "EnableGameFixes", true);
	si.SetBoolValue("EmuCore", "EnablePatches", true);
	si.SetBoolValue("EmuCore", "EnableCheats", false);
	si.SetBoolValue("EmuCore", "EnablePerGameSettings", true);
	si.SetBoolValue("EmuCore", "HostFs", false);
	si.SetBoolValue("EmuCore/Speedhacks", "vuFlagHack", true);
	si.SetBoolValue("EmuCore/Speedhacks", "IntcStat", true);
	si.SetBoolValue("EmuCore/Speedhacks", "WaitLoop", true);
	si.SetIntValue("EmuCore/GS", "FramesToDraw", 1);
	si.SetIntValue("EmuCore/GS", "upscale_multiplier", 2);
	si.SetBoolValue("EmuCore/GS", "FrameLimitEnable", true);
	si.SetBoolValue("EmuCore/GS", "SyncToHostRefreshRate",false);
	si.SetBoolValue("EmuCore/GS", "UserHacks", true);
	si.SetBoolValue("EmuCore/GS", "UserHacks_WildHack", true);
	
	wxModule::RegisterModules();
	wxModule::InitializeModules();
}

- (void)resetEmulation
{
	VMManager::SetState(VMState::Stopping);
}

- (void)setPauseEmulation:(BOOL)pauseEmulation
{
	if (pauseEmulation) {
		VMManager::SetState(VMState::Paused);
	} else {
		VMManager::SetState(VMState::Running);
	}
	[super setPauseEmulation:pauseEmulation];
}

- (void)startEmulation
{
	[super startEmulation];
	
	[self.renderDelegate willRenderFrameOnAlternateThread];
	[self.renderDelegate suspendFPSLimiting];
	
	params.source = gamePath.fileSystemRepresentation;
	params.save_state = "";
	params.source_type = CDVD_SourceType::Iso;
	params.elf_override = "";
	params.fast_boot = true;
	params.fullscreen = false;
	params.batch_mode = std::nullopt;
   
	if(!hasInitialized){
	hostDisplay = HostDisplay::CreateDisplayForAPI(OpenGLHostDisplay::RenderAPI::OpenGL);
	WindowInfo wi;
		wi.type = WindowInfo::Type::MacOS;
		wi.surface_width = 640 ;
		wi.surface_height = 448 ;
	hostDisplay->CreateRenderDevice(wi,
			Host::GetStringSettingValue("EmuCore/GS", "Adapter", ""),
			VsyncMode::Adaptive,
			Host::GetBoolSettingValue("EmuCore/GS", "ThreadedPresentation", false),
			Host::GetBoolSettingValue("EmuCore/GS", "UseDebugDevice", false));
		
		
		if(VMManager::Initialize(params)){
			hasInitialized = true;
				VMManager::SetState(VMState::Running);
				[NSThread detachNewThreadSelector:@selector(runVMThread) toTarget:self withObject:nil];
		}
	}
}

- (void)runVMThread
{
	OESetThreadRealtime(1. / 50, .007, .03); // guessed from bsnes
		
	while(!ExitRequested)
	{
		if(VMManager::HasValidVM()){
				VMManager::Execute();
		}else{
			if(VMManager::GetState() == VMState::Stopping)
				VMManager::Reset();
		}
	}
}

- (void)stopEmulation
{
	ExitRequested = true;
	VMManager::SetState(VMState::Stopping);
	VMManager::Shutdown();
	[super stopEmulation];
}

- (void)executeFrame
{
	//Console.Error("UpScale Multiplier: %d", GSConfig.UpscaleMultiplier);
//	if(VMManager::HasValidVM()){
//		VMManager::Execute();
//	}
}

#pragma mark Video
- (OEIntSize)aspectSize
{
	return (OEIntSize){ 4, 3 };
}

- (NSTimeInterval)frameInterval
{
	return 60;
}

- (BOOL)tryToResizeVideoTo:(OEIntSize)size
{
	return YES;
}

- (OEGameCoreRendering)gameCoreRendering
{
	//TODO: return OEGameCoreRenderingMetal1Video;
	return OEGameCoreRenderingOpenGL3Video;
}

- (BOOL)hasAlternateRenderingThread
{
	return YES;
}

- (BOOL)needsDoubleBufferedFBO
{
	return NO;
}

- (OEIntSize)bufferSize
{
	return (OEIntSize){ 640 , 448  };
}

#pragma mark Audio
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
	return 48000;
}

#pragma mark Input
- (oneway void)didMovePS2JoystickDirection:(OEPS2Button)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
	g_key_status.Set(u32(player - 1), ps2keymap[button].ps2key , value);
}

- (oneway void)didPushPS2Button:(OEPS2Button)button forPlayer:(NSUInteger)player
{
	g_key_status.Set(u32(player - 1), ps2keymap[button].ps2key , 1.0f);
	
}

- (oneway void)didReleasePS2Button:(OEPS2Button)button forPlayer:(NSUInteger)player {
	g_key_status.Set(u32(player - 1), ps2keymap[button].ps2key, 0.0f);
}

#pragma mark - Discs

- (NSUInteger)discCount
{
	return 1;
}

- (void)setDisc:(NSUInteger)discNumber
{
}

@end

SysMtgsThread& GetMTGS()
{
	return s_mtgs_thread;
}

#pragma mark - Host Namespace

std::optional<std::vector<u8>> Host::ReadResourceFile(const char* filename)
{
	@autoreleasepool {
	NSString *nsFile = @(filename);
	NSString *baseName = nsFile.lastPathComponent.stringByDeletingPathExtension;
	NSString *upperName = nsFile.stringByDeletingLastPathComponent;
	NSString *baseExt = nsFile.pathExtension;
	if (baseExt.length == 0) {
		baseExt = nil;
	}
	if (upperName.length == 0 || [upperName isEqualToString:@"/"]) {
		upperName = nil;
	}
	NSURL *aURL;
	if (upperName) {
		aURL = [[NSBundle bundleForClass:[PCSX2GameCore class]] URLForResource:baseName withExtension:baseExt subdirectory:upperName];
	} else {
		aURL = [[NSBundle bundleForClass:[PCSX2GameCore class]] URLForResource:baseName withExtension:baseExt];
	}
	if (!aURL) {
		return std::nullopt;
	}
	NSData *data = [[NSData alloc] initWithContentsOfURL:aURL];
	if (!data) {
		return std::nullopt;
	}
	auto retVal = std::vector<u8>(data.length);
	[data getBytes:retVal.data() length:retVal.size()];
	return retVal;
	}
}

std::optional<std::string> Host::ReadResourceFileToString(const char* filename)
{
	@autoreleasepool {
	NSString *nsFile = @(filename);
	NSString *baseName = nsFile.lastPathComponent.stringByDeletingPathExtension;
	NSString *upperName = nsFile.stringByDeletingLastPathComponent;
	NSString *baseExt = nsFile.pathExtension;
	if (baseExt.length == 0) {
		baseExt = nil;
	}
	if (upperName.length == 0 || [upperName isEqualToString:@"/"]) {
		upperName = nil;
	}
	NSURL *aURL;
	if (upperName) {
		aURL = [[NSBundle bundleForClass:[PCSX2GameCore class]] URLForResource:baseName withExtension:baseExt subdirectory:upperName];
	} else {
		aURL = [[NSBundle bundleForClass:[PCSX2GameCore class]] URLForResource:baseName withExtension:baseExt];
	}
	if (!aURL) {
		return std::nullopt;
	}
	NSData *data = [[NSData alloc] initWithContentsOfURL:aURL];
	if (!data) {
		return std::nullopt;
	}
	std::string ret;
	ret.resize(data.length);
	[data getBytes:ret.data() length:ret.size()];
	return ret;
	}
}

void Host::WriteToSoundBuffer(s16 Left, s16 Right)
{
	GET_CURRENT_OR_RETURN();
	
	[[_current audioBufferAtIndex:0] write:(&Left) maxLength:sizeof(s16)];
	[[_current audioBufferAtIndex:0] write:(&Right) maxLength:sizeof(s16)];
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
	//Console.Error("Reported Error: '%s':'%s'", title, message);
}

#pragma mark Host Thread

void Host::OnVMStarting()
{
	GET_CURRENT_OR_RETURN();
	
}

void Host::OnVMStarted()
{
	GET_CURRENT_OR_RETURN();
	
}

void Host::OnVMDestroyed()
{
	GET_CURRENT_OR_RETURN();
	
}

void Host::OnVMPaused()
{
	GET_CURRENT_OR_RETURN();
	
}

void Host::OnVMResumed()
{
	GET_CURRENT_OR_RETURN();
	
}

void Host::OnSaveStateLoading(const std::string_view& filename)
{
	GET_CURRENT_OR_RETURN();
	
}

void Host::OnSaveStateLoaded(const std::string_view& filename, bool was_successful)
{
	GET_CURRENT_OR_RETURN();
	
}

void Host::OnSaveStateSaved(const std::string_view& filename)
{
	GET_CURRENT_OR_RETURN();
	
}

void Host::OnGameChanged(const std::string& disc_path, const std::string& game_serial, const std::string& game_name, u32 game_crc)
{
	GET_CURRENT_OR_RETURN();
	
}

void Host::PumpMessagesOnCPUThread()
{
	GET_CURRENT_OR_RETURN();
}

void Host::InvalidateSaveStateCache()
{
	
}

void Host::RequestResizeHostDisplay(s32 width, s32 height)
{
	GET_CURRENT_OR_RETURN();
	
}

void Host::RunOnCPUThread(std::function<void()> function, bool block)
{
	
}

#pragma mark Host Display

HostDisplay* Host::AcquireHostDisplay(HostDisplay::RenderAPI api)
{
	GET_CURRENT_OR_RETURN(nullptr);

	return current->hostDisplay.get();
}

void Host::ReleaseHostDisplay()
{
	GET_CURRENT_OR_RETURN();
	
}

HostDisplay* Host::GetHostDisplay()
{
	GET_CURRENT_OR_RETURN(nullptr);
	
	[current.renderDelegate willRenderFrameOnAlternateThread];
	return current->hostDisplay.get();
}

bool Host::BeginPresentFrame(bool frame_skip)
{
	GET_CURRENT_OR_RETURN(false);
	
	return current->hostDisplay.get()->BeginPresent(frame_skip);
}

void Host::EndPresentFrame()
{
	GET_CURRENT_OR_RETURN();
	
	current->hostDisplay.get()->EndPresent();
}

void Host::ResizeHostDisplay(u32 new_window_width, u32 new_window_height, float new_window_scale)
{
	GET_CURRENT_OR_RETURN();
	
}

void Host::UpdateHostDisplay()
{
	GET_CURRENT_OR_RETURN();
	
}


#pragma mark -

const IConsoleWriter* PatchesCon = &ConsoleWriter_Null;

void LoadAllPatchesAndStuff(const Pcsx2Config& cfg)
{
	GET_CURRENT_OR_RETURN();
	// TODO: implement
}

std::optional<u32> InputManager::ConvertHostKeyboardStringToCode(const std::string_view& str)
{
	return std::nullopt;
}

std::optional<std::string> InputManager::ConvertHostKeyboardCodeToString(u32 code)
{
	return std::nullopt;
}

BEGIN_HOTKEY_LIST(g_host_hotkeys)
END_HOTKEY_LIST()
