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
#include "Host.h"
#include "VMManager.h"
#include "Input/InputManager.h"
#include "pcsx2/INISettingsInterface.h"
#include "MTGS.h"
#include "common/SettingsWrapper.h"
#include "CDVD/CDVD.h"
#include "SPU2/defs.h"
//#include "SPU2/SndOut.h"
#include "SIO/Pad/Pad.h"
#include "SIO/Pad/PadBase.h"
#include "SIO/Pad/PadDualshock2.h"
#include "R3000A.h"
#include "MTVU.h"
#include "Elfheader.h"
#include "USB/deviceproxy.h"
#include "Error.h"
#include "Host/AudioStream.h"
#undef BOOL

#include <OpenGL/gl3.h>
#include <OpenGL/gl3ext.h>

static bool ExitRequested = false;
static bool WaitRequested = false;
static bool isExecuting = false;

bool renderswitch = false;

static NSString * const OEPSCSX2InternalResolution = @"OEPSCSX2InternalResolution";
static NSString * const OEPSCSX2BlendingAccuracy = @"OEPSCSX2BlendingAccuracy";

namespace GSDump
{
	bool isRunning = false;
}

PCSX2GameCore *_current;

@implementation PCSX2GameCore {
	@package
	bool hasInitialized;
	NSURL* gamePath;
	NSURL* stateToLoad;
	NSString* DiscID;
	NSString* DiscRegion;
	NSString* DiscSubRegion;
	
	std::unique_ptr<INISettingsInterface> s_base_settings_interface;
	
	VMBootParameters params;
	
	//Multi-disc booting.
	NSUInteger _maxDiscs;
	NSMutableArray<NSString*> *_allCueSheetFiles;
	NSURL *basePath;
	// Display modes.
	NSMutableDictionary <NSString *, id> *_displayModes;
	OEIntRect screenRect;
	WindowInfo windowInfo;
}

- (instancetype)init
{
	if (self = [super init]) {
		_current = self;
		_maxDiscs = 0;
		_displayModes = [[NSMutableDictionary alloc] initWithDictionary:
						 @{OEPSCSX2InternalResolution: @1,
						   OEPSCSX2BlendingAccuracy: @1}];
		screenRect = OEIntRectMake(0, 0, 640 * 4, 448 * 4);
	}
	return self;
}

static NSURL *binCueFix(NSURL *path)
{
	if ([[path pathExtension] caseInsensitiveCompare:@"cue"] == NSOrderedSame) {
		// Assume the bin file is the same as the cue.
		return [[path URLByDeletingPathExtension] URLByAppendingPathExtension:@"bin"];
	}
	return path;
}

- (BOOL)loadFileAtURL:(NSURL *)url error:(NSError **)error
{
#ifdef __aarch64__
	//PCSX2 isn't yet ready for ARM64. Warn our user.
	
	if (error) {
		*error = [NSError errorWithDomain: OEGameCoreErrorDomain
									 code: OEGameCoreCouldNotStartCoreError
								 userInfo: @{NSURLErrorKey: url,
											 NSLocalizedDescriptionKey: @"PCSX2 does not run natively on Apple Silicon.",
											 NSLocalizedRecoverySuggestionErrorKey: @"Relaunch OpenEmu under Rosetta 2 and try running the game again."}];
	}
	
	return NO;
#endif
	// PCSX2 can't handle cue files... but can read bin files
	if ([[url pathExtension] caseInsensitiveCompare:@"cue"] == NSOrderedSame) {
		// Assume the bin file is the same name as the cue.
		gamePath = [[url URLByDeletingPathExtension] URLByAppendingPathExtension:@"bin"];
	} else if([url.pathExtension.lowercaseString isEqualToString:@"m3u"]) {
		basePath = url.URLByDeletingLastPathComponent;
		NSString *m3uString = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
		NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@".*\\.cue|.*\\.ccd|.*\\.iso" options:NSRegularExpressionCaseInsensitive error:nil];
		NSUInteger numberOfMatches = [regex numberOfMatchesInString:m3uString options:0 range:NSMakeRange(0, m3uString.length)];
		
		NSLog(@"[PCSX2] Loaded m3u containing %lu cue sheets or ccd", numberOfMatches);
		
		_maxDiscs = numberOfMatches;
		
		// Keep track of cue sheets for use with SBI files
		[regex enumerateMatchesInString:m3uString options:0 range:NSMakeRange(0, m3uString.length) usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
			NSRange range = result.range;
			NSString *match = [m3uString substringWithRange:range];
			
			if([match containsString:@".cue"] || [match containsString:@".iso"]) {
				[_allCueSheetFiles addObject:[m3uString substringWithRange:range]];
			}
		}];
		
		if (_allCueSheetFiles.count <= 0) {
			if (error) {
				*error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:@{NSURLErrorKey: url}];
			}
			
			return false;
		} else {
			NSURL *ToPassBack = [basePath URLByAppendingPathComponent:_allCueSheetFiles.firstObject];
			ToPassBack = [binCueFix(ToPassBack) URLByStandardizingPath];
			
			gamePath = ToPassBack;
		}
	} else {
		gamePath = [url copy];
	}
	
	//Lets get the Disc ID with some Magic out of PCSX2 CDVD :)
	VMManager::ChangeDisc(CDVD_SourceType::Iso, url.fileSystemRepresentation);
	std::string DiscName;
	cdvdGetDiscInfo(nullptr, &DiscName, nullptr, nullptr, nullptr);
	
	//TODO: update!
//	std::string fname = DiscName.AfterLast('\\').BeforeFirst('_');
//	std::string fname2 = DiscName.AfterLast('_').BeforeFirst('.');
//	std::string fname3 = DiscName.AfterLast('.').BeforeFirst(';');
//	DiscName = fname + "-" + fname2 + fname3;
	
	DiscID = [NSString stringWithCString:DiscName.c_str() encoding:NSASCIIStringEncoding];
//	DiscRegion = [[NSString stringWithCString:fname.c_str() encoding:NSASCIIStringEncoding] substringWithRange:NSMakeRange(2,1)];
//	DiscSubRegion = [[NSString stringWithCString:fname.c_str() encoding:NSASCIIStringEncoding] substringWithRange:NSMakeRange(3,1)];
	
	return true;
}

- (void)setupEmulation
{
	const std::string pcsx2ini([[self.supportDirectory URLByAppendingPathComponent:@"inis" isDirectory:YES] URLByAppendingPathComponent:@"PCSX2.ini" isDirectory:NO].fileSystemRepresentation);
	s_base_settings_interface = std::make_unique<INISettingsInterface>(std::move(pcsx2ini));
	Host::Internal::SetBaseSettingsLayer(s_base_settings_interface.get());
	
	SettingsInterface& si = *s_base_settings_interface.get();
	EmuConfig = Pcsx2Config();
	EmuFolders::SetDefaults(si);

	si.SetUIntValue("UI", "SettingsVersion", 1);

	{
		SettingsSaveWrapper wrapper(si);
		EmuConfig.LoadSave(wrapper);
	}

	NSURL *url = self.batterySavesDirectory;
	if (![[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:NULL]) {
		[[NSFileManager defaultManager] createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:NULL];
	}

	EmuFolders::MemoryCards = url.fileSystemRepresentation;
	EmuFolders::Bios = self.biosDirectory.fileSystemRepresentation;
	EmuFolders::AppRoot = [[NSBundle bundleForClass:[self class]] resourceURL].fileSystemRepresentation;
	EmuFolders::DataRoot = self.supportDirectory.fileSystemRepresentation;
	EmuFolders::Settings = [self.supportDirectory URLByAppendingPathComponent:@"inis" isDirectory:YES].fileSystemRepresentation;
	EmuFolders::Resources = [[NSBundle bundleForClass:[self class]] resourceURL].fileSystemRepresentation;
	EmuFolders::Cache = [self.supportDirectory URLByAppendingPathComponent:@"Cache" isDirectory:YES].fileSystemRepresentation;
	EmuFolders::Snapshots = [self.supportDirectory URLByAppendingPathComponent:@"snaps" isDirectory:YES].fileSystemRepresentation;
	EmuFolders::Savestates = [self.supportDirectory URLByAppendingPathComponent:@"sstates" isDirectory:YES].fileSystemRepresentation;
	EmuFolders::Logs = [self.supportDirectory URLByAppendingPathComponent:@"Logs" isDirectory:YES].fileSystemRepresentation;
	EmuFolders::Cheats = [self.supportDirectory URLByAppendingPathComponent:@"Cheats" isDirectory:YES].fileSystemRepresentation;
	EmuFolders::Patches = [self.supportDirectory URLByAppendingPathComponent:@"Patches" isDirectory:YES].fileSystemRepresentation;
	EmuFolders::Covers = [self.supportDirectory URLByAppendingPathComponent:@"Covers" isDirectory:YES].fileSystemRepresentation;
	EmuFolders::GameSettings = [self.supportDirectory URLByAppendingPathComponent:@"gamesettings" isDirectory:YES].fileSystemRepresentation;
	EmuFolders::EnsureFoldersExist();
	
	// Create a folder (if it doesn't exist) instead of letting PCSX2 create a small 8 MiB memory card.
	// This makes it easier for the user to have multiple saves without having to worry about space.
	// Also, PCSX2 automatically makes it so that games that can load saves from other games CAN see the extra saves.
	if (![[self.batterySavesDirectory URLByAppendingPathComponent:@"Memory folder 1.ps2"] checkResourceIsReachableAndReturnError:NULL]) {
		[[NSFileManager defaultManager] createDirectoryAtURL:[self.batterySavesDirectory URLByAppendingPathComponent:@"Memory folder 1.ps2"] withIntermediateDirectories:YES attributes:nil error:NULL];
	}
	if (![[self.batterySavesDirectory URLByAppendingPathComponent:@"Memory folder 2.ps2"] checkResourceIsReachableAndReturnError:NULL]) {
		[[NSFileManager defaultManager] createDirectoryAtURL:[self.batterySavesDirectory URLByAppendingPathComponent:@"Memory folder 2.ps2"] withIntermediateDirectories:YES attributes:nil error:NULL];
	}
	
	if ([DiscRegion isEqualToString:@"U"]) {
		// NTSC-US
		EmuConfig.BaseFilenames.Bios = "scph39001.bin";
	} else if ([DiscRegion isEqualToString:@"E"]) {
		// Pal Europe
		EmuConfig.BaseFilenames.Bios = "scph70004.bin";
	}  else {
		//It's one of the many Asia Pacfic NTCS-J Regions
		// look at Region/sub region to figure out further
		if ([DiscSubRegion isEqualToString:@"J"]) {
			//It's Japan
			EmuConfig.BaseFilenames.Bios = "scph10000.bin";
		} else {
			// Default to the US Bios for now
			EmuConfig.BaseFilenames.Bios = "scph39001.bin";
		}
	}
	
#ifdef DEBUG
	si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableEE", false);
#else
	si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableEE", true);
#endif
	si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableEECache", false);
	si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableIOP", true);
	si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU0", true);
	si.SetBoolValue("EmuCore/CPU/Recompiler", "EnableVU1", true);
	si.SetStringValue("SPU2/Output", "OutputModule", "nullout");
	si.SetBoolValue("EmuCore", "EnablePatches", true);
	si.SetBoolValue("EmuCore", "EnableCheats", false);
	si.SetBoolValue("EmuCore", "EnablePerGameSettings", true);
	//TODO: somehow work this into OpenEmu...
	si.SetBoolValue("EmuCore", "EnableWideScreenPatches", false);
	si.SetBoolValue("EmuCore", "HostFs", false);
	si.SetBoolValue("EmuCore/Speedhacks", "vuFlagHack", true);
	si.SetBoolValue("EmuCore/Speedhacks", "IntcStat", true);
	si.SetBoolValue("EmuCore/Speedhacks", "WaitLoop", true);
	si.SetIntValue("EmuCore/GS", "FramesToDraw", 2);
	si.SetIntValue("EmuCore/GS", "upscale_multiplier", 1);
	si.SetBoolValue("EmuCore/GS", "FrameLimitEnable", true);
	si.SetBoolValue("EmuCore/GS", "SyncToHostRefreshRate",false);
	si.SetBoolValue("EmuCore/GS", "UserHacks", false);
	si.SetStringValue("Pad2", "Type", "DualShock2");
	
	si.SetStringValue("MemoryCards", "Slot1_Filename", "Memory folder 1.ps2");
	si.SetBoolValue("MemoryCards", "Slot1_Enable", true);
	si.SetStringValue("MemoryCards", "Slot2_Filename", "Memory folder 2.ps2");
	si.SetBoolValue("MemoryCards", "Slot2_Enable", true);
	si.SetIntValue("SPU2/Output", "SynchMode", 2);
	si.SetIntValue("SPU2/Output", "Latency", 60);
	si.SetIntValue("SPU2/Output", "OutputLatency", 20);
	si.SetIntValue("SPU2/Mixing", "FinalVolume", 100);
}

- (void)resetEmulation
{
	VMManager::SetState(VMState::Resetting);
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
	
	params.filename = gamePath.fileSystemRepresentation;
	if ([stateToLoad.path length] > 0) {
		params.save_state = stateToLoad.fileSystemRepresentation;
		stateToLoad = nil;
	} else {
		params.save_state = "";
	}
	params.source_type = CDVD_SourceType::Iso;
	params.elf_override = "";
	params.fast_boot = true;
	params.fullscreen = false;
  
	if(!hasInitialized){
		VMManager::Internal::CPUThreadInitialize();
		
		VMManager::ApplySettings();
		
		// TODO: handle needing to validate hardcore mode.
		VMBootResult success = VMManager::Initialize(params);
		if (VMBootResult::StartupSuccess == success) {
			hasInitialized = true;
			VMManager::SetState(VMState::Running);

			[NSThread detachNewThreadSelector:@selector(runVMThread:) toTarget:self withObject:nil];
		}
	}
}

- (void)runVMThread:(id)unused
{
	const char *tmp;
	if (!VMManager::PerformEarlyHardwareChecks(&tmp)) {
		abort();
	}
	OESetThreadRealtime(1. / 50, .007, .03); // guessed from bsnes
		
	while(!ExitRequested)
	{
		switch (VMManager::GetState())
		{
			case VMState::Shutdown:
				continue;
				
			case VMState::Initializing:
				continue;

			case VMState::Paused:
				continue;

			case VMState::Running:
				if (!WaitRequested) {
					isExecuting = true;
					VMManager::Execute();
					isExecuting = false;
				}
				continue;

			case VMState::Resetting:
				VMManager::Reset();
				continue;

			case VMState::Stopping:
				VMManager::Shutdown(true);
				VMManager::Internal::CPUThreadShutdown();
		}
	}
}

- (void)stopEmulation
{
	ExitRequested = true;
	VMManager::SetState(VMState::Stopping);
	[super stopEmulation];
}

- (void)executeFrame
{
	
}

#pragma mark Video
- (OEIntSize)aspectSize
{
	//TODO: change based off of app/user availability.
	return (OEIntSize){ 4, 3 };
}

- (NSTimeInterval)frameInterval
{
	return 60;
}

- (GLenum)pixelType
{
	return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (GLenum)pixelFormat
{
	return GL_BGRA;
}

- (BOOL)tryToResizeVideoTo:(OEIntSize)size
{
	return YES;
}

- (OEGameCoreRendering)gameCoreRendering
{
	if (@available(macOS 10.15, *)) {
		return OEGameCoreRenderingMetal2;
	} else {
		return OEGameCoreRenderingOpenGL3;
	}
}

- (BOOL)hasAlternateRenderingThread
{
	return YES;
}

- (BOOL)needsDoubleBufferedFBO
{
	return NO;
}

- (OEIntRect)screenRect
{
	return screenRect;
}

- (OEIntSize)bufferSize
{
	return OEIntSizeMake(screenRect.size.width, screenRect.size.height);
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

/// The code currently assumes the controller is a PadDualshock2. This tests it and returns the actual object if it is, or `NULL` if it is not.
static PadDualshock2* getPadToDualShock(const NSUInteger player);
static PadDualshock2* getPadToDualShock(const NSUInteger player)
{
	auto pad = Pad::GetPad(player - 1);
	auto pad2 = dynamic_cast<PadDualshock2*>(pad);
	return pad2;
}

- (oneway void)didMovePS2JoystickDirection:(OEPS2Button)button withValue:(CGFloat)value forPlayer:(NSUInteger)player
{
	auto pad = getPadToDualShock(player);
	if (pad == nullptr) {
		// A setting is wrong...
		NSLog(@"Unknown controller on port %lu", (unsigned long)player);
		// Bailing out!
		return;
	}
	pad->Set(ps2keymap[button].ps2key, value);
}

- (oneway void)didPushPS2Button:(OEPS2Button)button forPlayer:(NSUInteger)player
{
	auto pad = getPadToDualShock(player);
	if (pad == nullptr) {
		// A setting is wrong...
		NSLog(@"Unknown controller on port %lu", (unsigned long)player);
		// Bailing out!
		return;
	}
	pad->Set(ps2keymap[button].ps2key, 1.0f);
}

- (oneway void)didReleasePS2Button:(OEPS2Button)button forPlayer:(NSUInteger)player {
	auto pad = getPadToDualShock(player);
	if (pad == nullptr) {
		// A setting is wrong...
		NSLog(@"Unknown controller on port %lu", (unsigned long)player);
		// Bailing out!
		return;
	}
	pad->Set(ps2keymap[button].ps2key, 0.0f);
}


#pragma mark Save States
- (void)loadStateFromFileAtURL:(NSURL *)fileURL completionHandler:(void (^)(BOOL, NSError *))block
{
	if (!VMManager::HasValidVM()) {
		stateToLoad = fileURL;
		// Assume we'll succeed
		block(true, nil);
		return;
	}
	
	WaitRequested = true;
	while(isExecuting)
		usleep(50);
	
	Error theError = Error();
	bool success = VMManager::LoadState(fileURL.fileSystemRepresentation, &theError);
	WaitRequested = false;

	block(success, success ? nil : [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat: @"PCSX2 Could not load the current state: %s", theError.GetDescription().c_str()], NSURLErrorKey: fileURL}]);
}

- (void)saveStateToFileAtURL:(NSURL *)fileURL completionHandler:(void (^)(BOOL, NSError *))block
{
	if (!VMManager::HasValidVM()) {
		// Not loaded. Then we fail?
		block(NO, [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotStartCoreError userInfo:@{NSLocalizedDescriptionKey: @"PCSX2 is not initialized, creating save state impossible.", NSURLErrorKey: fileURL}]);
		return;
	}
	//TODO: verify that this works...
	std::string hi = "";
	VMManager::SaveState(fileURL.fileSystemRepresentation, false, false, [&hi](const std::string& err){
		hi = err;
	});
	
	block(hi.empty(), hi.empty() ? nil : [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat: @"PCSX2 Could not save the current state: %s", hi.c_str()], NSURLErrorKey: fileURL}]);
	
}

#pragma mark - Discs

- (NSUInteger)discCount
{
	return _maxDiscs ? _maxDiscs : 1;
}

- (void)setDisc:(NSUInteger)discNumber
{
	NSURL *ToPassBack = [basePath URLByAppendingPathComponent:_allCueSheetFiles[discNumber - 1]];
	ToPassBack = [binCueFix(ToPassBack) URLByStandardizingPath];
	
	gamePath = ToPassBack;

	VMManager::ChangeDisc(CDVD_SourceType::Iso, gamePath.fileSystemRepresentation);
}

#pragma mark - Display Options

- (NSDictionary<NSString *,id> *)displayModeInfo
{
	return [_displayModes copy];
}

- (void)setDisplayModeInfo:(NSDictionary<NSString *, id> *)displayModeInfo
{
	const struct {
		NSString *const key;
		Class valueClass;
		id defaultValue;
	} defaultValues[] = {
		{ OEPSCSX2InternalResolution,	[NSNumber class], @1  },
		{ OEPSCSX2BlendingAccuracy,		[NSNumber class], @1  },
	};
	/* validate the defaults to avoid crashes caused by users playing
	 * around where they shouldn't */
	_displayModes = [[NSMutableDictionary alloc] init];
	const int n = sizeof(defaultValues)/sizeof(defaultValues[0]);
	for (int i=0; i<n; i++) {
		id thisPref = displayModeInfo[defaultValues[i].key];
		if ([thisPref isKindOfClass:defaultValues[i].valueClass]) {
			_displayModes[defaultValues[i].key] = thisPref;
		} else {
			_displayModes[defaultValues[i].key] = defaultValues[i].defaultValue;
		}
	}
}

- (NSArray <NSDictionary <NSString *, id> *> *)displayModes
{
#define OptionWithValue(n, k, v) \
@{ \
	OEGameCoreDisplayModeNameKey : n, \
	OEGameCoreDisplayModePrefKeyNameKey : k, \
	OEGameCoreDisplayModeStateKey : @([_displayModes[k] isEqual:@(v)]), \
	OEGameCoreDisplayModePrefValueNameKey : @(v) }
#define OptionToggleable(n, k) \
	OEDisplayMode_OptionToggleableWithState(n, k, _displayModes[k])

	return @[
		OEDisplayMode_Submenu(@"Internal Resolution",
							  @[OptionWithValue(@"1x (default)", OEPSCSX2InternalResolution, 1),
								OptionWithValue(@"2x (~720p)", OEPSCSX2InternalResolution, 2),
								OptionWithValue(@"3x (~1080p)", OEPSCSX2InternalResolution, 3),
								OptionWithValue(@"4x (~1440p 2k)", OEPSCSX2InternalResolution, 4),
								OptionWithValue(@"5x (~1620p)", OEPSCSX2InternalResolution, 5),
								OptionWithValue(@"6x (~2160p 4k)", OEPSCSX2InternalResolution, 6),
								OptionWithValue(@"7x (~2520p)", OEPSCSX2InternalResolution, 7),
								OptionWithValue(@"8x (~2880p)", OEPSCSX2InternalResolution, 8)]),
		OEDisplayMode_Submenu(@"Blending Accuracy",
							  @[OptionWithValue(@"Minimum (Fastest)", OEPSCSX2BlendingAccuracy, 0),
								OptionWithValue(@"Basic (Recommended)", OEPSCSX2BlendingAccuracy, 1),
								OptionWithValue(@"Medium", OEPSCSX2BlendingAccuracy, 2),
								OptionWithValue(@"High", OEPSCSX2BlendingAccuracy, 3),
								OptionWithValue(@"Full (Very Slow)", OEPSCSX2BlendingAccuracy, 4),
								OptionWithValue(@"Ultra (Ultra Slow, or M1)", OEPSCSX2BlendingAccuracy, 5)]),
	];
	
#undef OptionWithValue
#undef OptionToggleable
}

- (void)changeDisplayWithMode:(NSString *)displayMode
{
	NSString *key;
	id currentVal;
	OEDisplayModeListGetPrefKeyValueFromModeName(self.displayModes, displayMode, &key, &currentVal);
	if (key == nil) {
		return;
	}
	_displayModes[key] = currentVal;

	if ([key isEqualToString:OEPSCSX2InternalResolution]) {
		s_base_settings_interface->SetIntValue("EmuCore/GS", "upscale_multiplier", [currentVal intValue]);
		VMManager::RequestDisplaySize([currentVal floatValue]);
	} else if ([key isEqualToString:OEPSCSX2BlendingAccuracy]) {
		s_base_settings_interface->SetIntValue("EmuCore/GS", "accurate_blending_unit", [currentVal intValue]);
	}
	
	VMManager::ApplySettings();
}

@end

#pragma mark - Host Namespace

std::string Host::TranslatePluralToString(const char* context, const char* msg, const char* disambiguation, int count)
{
	TinyString count_str = TinyString::from_format("{}", count);

	std::string ret(msg);
	for (;;)
	{
		std::string::size_type pos = ret.find("%n");
		if (pos == std::string::npos)
			break;

		ret.replace(pos, pos + 2, count_str.view());
	}

	return ret;
}

std::unique_ptr<ProgressCallback> Host::CreateHostProgressCallback()
{
	return nil;
}

void Host::WriteToSoundBuffer(s16 Left, s16 Right)
{
	GET_CURRENT_OR_RETURN();
	
	s16 stereo[] = {Left, Right};
	[[current audioBufferAtIndex:0] write:stereo maxLength:sizeof(stereo)];
}

void Host::WriteToSoundBuffer(StereoOut32 snd)
{
	//TODO: better truncation!
	Host::WriteToSoundBuffer(snd.Left, snd.Right);
}

void Host::OnPerformanceMetricsUpdated()
{
}

std::optional<WindowInfo> Host::GetTopLevelWindowInfo()
{
	GET_CURRENT_OR_RETURN(std::nullopt);

	return current->windowInfo;
}

void Host::SetMouseMode(bool relative_mode, bool hide_cursor)
{
}

#pragma mark Host Logging

void Host::AddOSDMessage(std::string message, float duration)
{
}

void Host::AddKeyedOSDMessage(std::string key, std::string message, float duration)
{
}

void Host::RemoveKeyedOSDMessage(std::string key)
{
}

void Host::ClearOSDMessages()
{
}

void Host::ReportErrorAsync(const std::string_view title, const std::string_view message)
{
}

void Host::AddIconOSDMessage(std::string key, const char* icon, const std::string_view message, float duration /* = 2.0f */)
{
	// Stub, do nothing.
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

void Host::OnSaveStateLoading(const std::string_view filename)
{
}

void Host::OnSaveStateLoaded(const std::string_view filename, bool was_successful)
{
}

void Host::OnSaveStateSaved(const std::string_view filename)
{
}

void Host::OnGameChanged(const std::string& title, const std::string& elf_override, const std::string& disc_path,
						 const std::string& disc_serial, u32 disc_crc, u32 current_crc)
{
}

void Host::PumpMessagesOnCPUThread()
{
}

void Host::RequestResizeHostDisplay(s32 width, s32 height)
{
}

void Host::RunOnCPUThread(std::function<void()> function, bool block)
{
	//TODO: put this in the right thread...
	function();
}

void Host::RequestVMShutdown(bool allow_confirm, bool allow_save_state, bool default_save_state)
{
}

#pragma mark Host Display

void Host::BeginPresentFrame()
{
	
}

std::optional<WindowInfo> Host::AcquireRenderWindow(bool recreate_window)
{
	GET_CURRENT_OR_RETURN(std::nullopt);

	WindowInfo wi;
		wi.type = WindowInfo::Type::MacOS;
		wi.surface_width = current->screenRect.size.width;
		wi.surface_height = current->screenRect.size.height;
	
	current->windowInfo = wi;
	
	return current->windowInfo;
}

void Host::ReleaseRenderWindow()
{
	
}
void Host::CancelGameListRefresh()
{
	
}

#pragma mark Host Settings

void Host::LoadSettings(SettingsInterface& si, std::unique_lock<std::mutex>& lock)
{
//	CommonHost::LoadSettings(si, lock);
}

void Host::CheckForSettingsChanges(const Pcsx2Config& old_config)
{
//	CommonHost::CheckForSettingsChanges(old_config);
}

s32 Host::Internal::GetTranslatedStringImpl(const std::string_view context, const std::string_view msg, char* tbuf, size_t tbuf_space)
{
	if (msg.size() > tbuf_space) {
		return -1;
	} else if (msg.empty()) {
		return 0;
	}

	std::memcpy(tbuf, msg.data(), msg.size());
	return static_cast<s32>(msg.size());
}

#pragma mark -

std::optional<u32> InputManager::ConvertHostKeyboardStringToCode(const std::string_view str)
{
	return std::nullopt;
}

std::optional<std::string> InputManager::ConvertHostKeyboardCodeToString(u32 code)
{
	return std::nullopt;
}

void InputManager::SetPadVibrationIntensity(u32 pad_index, float large_or_single_motor_intensity, float small_motor_intensity)
{
	// TODO: add vibration support to OpenEmu
}

void InputManager::ReloadBindings(SettingsInterface& si, SettingsInterface& binding_si, SettingsInterface& hotkey_binding_si, bool is_binding_profile, bool is_hotkey_profile)
{
	
}

void InputManager::PauseVibration()
{
	
}

void InputManager::ReloadSources(SettingsInterface &si, std::unique_lock<std::mutex> &settings_lock)
{
	
}

void InputManager::PollSources()
{
	
}

void InputManager::CloseSources()
{
	
}

std::pair<float, float> InputManager::GetPointerAbsolutePosition(u32 index)
{
	return {0, 0};
}

RegisterDevice* RegisterDevice::registerDevice = nullptr;
void RegisterDevice::Register()
{
	
}

void RegisterDevice::Unregister()
{
	
}

#pragma mark -

std::unique_ptr<AudioStream> AudioStream::CreateSDLAudioStream(u32 sample_rate, const AudioStreamParameters& parameters, bool stretch_enabled, Error* error)
{
	Error::SetString(error, "Invalid OpenEmu configuration set!");
	return nullptr;
}


void VMManager::Internal::ResetVMHotkeyState()
{
	
}

BEGIN_HOTKEY_LIST(g_host_hotkeys)
END_HOTKEY_LIST()

BEGIN_HOTKEY_LIST(g_common_hotkeys)
END_HOTKEY_LIST()
