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
	block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreDoesNotSupportSaveStatesError userInfo:nil]);
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreDoesNotSupportSaveStatesError userInfo:nil]);
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
	params.source_type = CDVD_SourceType::NoDisc ;
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
		[[NSBundle bundleForClass:[PCSX2GameCore class]] URLForResource:baseName withExtension:baseExt subdirectory:upperName];
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

std::optional<std::string> Host::ReadResourceFileToString(const char* filename)
{
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
		[[NSBundle bundleForClass:[PCSX2GameCore class]] URLForResource:baseName withExtension:baseExt subdirectory:upperName];
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
	GET_CURRENT_OR_RETURN();
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

const IConsoleWriter* PatchesCon = &ConsoleWriter_Null;

void LoadAllPatchesAndStuff(const Pcsx2Config& cfg)
{
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
