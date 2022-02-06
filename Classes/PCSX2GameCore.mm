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
#include "../pcsx2/pcsx2/GS.h"
#include "../pcsx2/pcsx2/Host.h"
#include "../pcsx2/pcsx2/HostDisplay.h"
#include "../pcsx2/pcsx2/VMManager.h"
#include "../pcsx2/pcsx2/Frontend/InputManager.h"
#include "../pcsx2/pcsx2/CDVD/CDVDaccess.h"
#include "../pcsx2/pcsx2/SPU2/Global.h"
#include "../pcsx2/pcsx2/SPU2/SndOut.h"
#include "MTVU.h"
#undef BOOL

bool renderswitch = false;

namespace GSDump
{
	bool isRunning = false;
}

alignas(16) static SysMtgsThread s_mtgs_thread;
static __weak PCSX2GameCore *_current;

@implementation PCSX2GameCore {
	
}

- (instancetype)init
{
	if (self = [super init]) {
		VMManager::InitializeMemory();
	}
	return self;
}

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
	bool success = VMManager::ChangeDisc(path.fileSystemRepresentation);
	if (!success && error) {
		*error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:nil];
	}
	return success;
}

- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	bool success = VMManager::LoadState(fileName.fileSystemRepresentation);
	block(success, success ? nil : [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:nil]);
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	bool success = VMManager::SaveState(fileName.fileSystemRepresentation);
	block(success, success ? nil : [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:nil]);
}

- (void)setupEmulation
{
	NSString *path = self.batterySavesDirectoryPath;
	if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:NULL]) {
		[[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
	}

	EmuFolders::MemoryCards = path.fileSystemRepresentation;
	EmuFolders::Bios = self.biosDirectoryPath.fileSystemRepresentation;
	EmuFolders::AppRoot = [[NSBundle bundleForClass:[self class]] resourceURL].fileSystemRepresentation;
	
	EmuConfig.Mcd[0].Enabled = true;
	EmuConfig.Mcd[0].Type = MemoryCardType::Folder;
	EmuConfig.Mcd[0].Filename = "Memory folder 1";

	EmuConfig.Mcd[1].Enabled = true;
	EmuConfig.Mcd[1].Type = MemoryCardType::Folder;
	EmuConfig.Mcd[1].Filename = "Memory folder 2";
}

- (void)resetEmulation
{
	VMManager::Reset();
}

- (void)startEmulation
{
	[super startEmulation];
	VMBootParameters params;
	params.source = "";
	params.save_state = "";
	params.source_type = CDVD_SourceType::NoDisc;
	params.elf_override = "";
	params.fast_boot = true;
	params.fullscreen = false;
	params.batch_mode = std::nullopt;
	VMManager::Initialize(params);
}

- (void)stopEmulation
{
	VMManager::Shutdown();
	[super stopEmulation];
}

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
	VMManager::Execute();
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
	
	return nil;
}

void Host::ReleaseHostDisplay()
{
	GET_CURRENT_OR_RETURN();
	
}

HostDisplay* Host::GetHostDisplay()
{
	GET_CURRENT_OR_RETURN(nullptr);
	
	return nil;
}

bool Host::BeginPresentFrame(bool frame_skip)
{
	GET_CURRENT_OR_RETURN(false);
	
	return false;
}

void Host::EndPresentFrame()
{
	GET_CURRENT_OR_RETURN();
	
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
