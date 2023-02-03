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
#include "Video/OEHostDisplay.h"
#include "Audio/OESndOut.h"
#include "Input/keymap.h"
#include "OEUpscalePatches.h"

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
#include "Elfheader.h"
#undef BOOL

#include <OpenGL/gl3.h>
#include <OpenGL/gl3ext.h>

class MetalHostDisplay  : public HostDisplay {};

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

alignas(16) static SysMtgsThread s_mtgs_thread;
PCSX2GameCore *_current;

@interface PCSX2GameCore ()

@end

@implementation PCSX2GameCore {
	@package
	bool hasInitialized;
	NSString* gamePath;
	NSString* stateToLoad;
	NSString* DiscID;
	NSString* DiscRegion;
	NSString* DiscSubRegion;
	
	std::unique_ptr<INISettingsInterface> s_base_settings_interface;
	std::unique_ptr<HostDisplay> hostDisplay;
	
	VMBootParameters params;
	
	//Multi-disc booting.
	NSUInteger _maxDiscs;
	NSMutableArray<NSString*> *_allCueSheetFiles;
	NSString *basePath;
	// Display modes.
	NSMutableDictionary <NSString *, id> *_displayModes;
	OEIntRect screenRect;
}

- (instancetype)init
{
	if (self = [super init]) {
		_current = self;
		VMManager::InitializeMemory();
		_maxDiscs = 0;
		_displayModes = [[NSMutableDictionary alloc] initWithDictionary:
						 @{OEPSCSX2InternalResolution: @1,
						   OEPSCSX2BlendingAccuracy: @1}];
		screenRect = OEIntRectMake(0, 0, 640 * 4, 448 * 4);
	}
	return self;
}

static NSString *binCueFix(NSString *path)
{
	if ([[path pathExtension] caseInsensitiveCompare:@"cue"] == NSOrderedSame) {
		// Assume the bin file is the same as the cue.
		return [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"bin"];
	}
	return path;
}

- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
	// PCSX2 can't handle cue files... but can read bin files
	if ([[path pathExtension] caseInsensitiveCompare:@"cue"] == NSOrderedSame) {
		// Assume the bin file is the same name as the cue.
		gamePath = [[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"bin"];
	} else if([path.pathExtension.lowercaseString isEqualToString:@"m3u"]) {
		basePath = path.stringByDeletingLastPathComponent;
		NSString *m3uString = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
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
				*error = [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadROMError userInfo:@{NSFilePathErrorKey: path}];
			}
			
			return false;
		} else {
			NSString *ToPassBack = [basePath stringByAppendingPathComponent:_allCueSheetFiles.firstObject];
			ToPassBack = [binCueFix(ToPassBack) stringByStandardizingPath];
			
			gamePath = ToPassBack;
		}
	} else {
		gamePath = [path copy];
	}
	
	//Lets get the Disc ID with some Magic out of PCSX2 CDVD :)
	VMManager::ChangeDisc(path.fileSystemRepresentation);
	wxString DiscName;
	GetPS2ElfName(DiscName);
	
	wxString fname = DiscName.AfterLast('\\').BeforeFirst('_');
	wxString fname2 = DiscName.AfterLast('_').BeforeFirst('.');
	wxString fname3 = DiscName.AfterLast('.').BeforeFirst(';');
	DiscName = fname + "-" + fname2 + fname3;
	
	DiscID = [NSString stringWithCString:DiscName.char_str() encoding:NSASCIIStringEncoding];
	DiscRegion = [[NSString stringWithCString:fname.char_str() encoding:NSASCIIStringEncoding] substringWithRange:NSMakeRange(2,1)];
	DiscSubRegion = [[NSString stringWithCString:fname.char_str() encoding:NSASCIIStringEncoding] substringWithRange:NSMakeRange(3,1)];
	
	return true;
}

- (void)setupEmulation
{
	const std::string pcsx2ini(Path::CombineStdString([self.supportDirectoryPath stringByAppendingPathComponent:@"inis"].fileSystemRepresentation, "PCSX2.ini"));
	s_base_settings_interface = std::make_unique<INISettingsInterface>(std::move(pcsx2ini));
	Host::Internal::SetBaseSettingsLayer(s_base_settings_interface.get());
	
	EmuConfig = Pcsx2Config();
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
	EmuFolders::Settings = [self.supportDirectoryPath stringByAppendingPathComponent:@"inis"].fileSystemRepresentation;
	EmuFolders::Resources = [[NSBundle bundleForClass:[self class]] resourceURL].fileSystemRepresentation;
	EmuFolders::Cache = [self.supportDirectoryPath stringByAppendingPathComponent:@"Cache"].fileSystemRepresentation;
	EmuFolders::Snapshots = [self.supportDirectoryPath stringByAppendingPathComponent:@"snaps"].fileSystemRepresentation;
	EmuFolders::Savestates = [self.supportDirectoryPath stringByAppendingPathComponent:@"sstates"].fileSystemRepresentation;
	EmuFolders::Logs = [self.supportDirectoryPath stringByAppendingPathComponent:@"Logs"].fileSystemRepresentation;
	EmuFolders::Cheats = [self.supportDirectoryPath stringByAppendingPathComponent:@"Cheats"].fileSystemRepresentation;
	EmuFolders::CheatsWS = [self.supportDirectoryPath stringByAppendingPathComponent:@"cheats_ws"].fileSystemRepresentation;
	EmuFolders::Covers = [self.supportDirectoryPath stringByAppendingPathComponent:@"Covers"].fileSystemRepresentation;
	EmuFolders::GameSettings = [self.supportDirectoryPath stringByAppendingPathComponent:@"gamesettings"].fileSystemRepresentation;
	EmuFolders::EnsureFoldersExist();
	
	EmuConfig.Mcd[0].Enabled = true;
	EmuConfig.Mcd[0].Type = MemoryCardType::Folder;
	EmuConfig.Mcd[0].Filename = "Memory folder 1.ps2";

	EmuConfig.Mcd[1].Enabled = true;
	EmuConfig.Mcd[1].Type = MemoryCardType::Folder;
	EmuConfig.Mcd[1].Filename = "Memory folder 2.ps2";
	
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
	si.SetStringValue("EmuCore/SPU2", "OutputModule", "NullOut");
	si.SetBoolValue("", "EnableGameFixes", true);
	si.SetBoolValue("EmuCore", "EnablePatches", true);
	si.SetBoolValue("EmuCore", "EnableCheats", false);
	si.SetBoolValue("EmuCore", "EnablePerGameSettings", true);
	si.SetBoolValue("EmuCore", "HostFs", false);
	si.SetBoolValue("EmuCore/Speedhacks", "vuFlagHack", true);
	si.SetBoolValue("EmuCore/Speedhacks", "IntcStat", true);
	si.SetBoolValue("EmuCore/Speedhacks", "WaitLoop", true);
	si.SetIntValue("EmuCore/GS", "FramesToDraw", 2);
	si.SetIntValue("EmuCore/GS", "upscale_multiplier", 1);
	si.SetBoolValue("EmuCore/GS", "FrameLimitEnable", true);
	si.SetBoolValue("EmuCore/GS", "SyncToHostRefreshRate",false);
	si.SetBoolValue("EmuCore/GS", "UserHacks", true);
	
	[self ApplyUpscalePatches];

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
		if (self.gameCoreRendering == OEGameCoreRenderingOpenGL3Video)
			hostDisplay = HostDisplay::CreateDisplayForAPI(OpenGLHostDisplay::RenderAPI::OpenGL);
		else if (self.gameCoreRendering == OEGameCoreRenderingMetal2Video)
			hostDisplay = HostDisplay::CreateDisplayForAPI(MetalHostDisplay::RenderAPI::Metal);
			
		WindowInfo wi;
			wi.type = WindowInfo::Type::MacOS;
			wi.surface_width = screenRect.size.width ;
			wi.surface_height = screenRect.size.height ;
		hostDisplay->CreateRenderDevice(wi,
				Host::GetStringSettingValue("EmuCore/GS", "Adapter", ""),
				VsyncMode::Adaptive,
				Host::GetBoolSettingValue("EmuCore/GS", "ThreadedPresentation", false),
				Host::GetBoolSettingValue("EmuCore/GS", "UseDebugDevice", false));
			
		
		if(VMManager::Initialize(params)){
			hasInitialized = true;
			VMManager::SetState(VMState::Running);
			if ([stateToLoad length] > 0)
				VMManager::LoadState(stateToLoad.fileSystemRepresentation);

			[NSThread detachNewThreadSelector:@selector(runVMThread) toTarget:self withObject:nil];
		}
	}
}

- (void)runVMThread
{
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

			case VMState::Stopping:
				VMManager::Reset();
				continue;;
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
	//FIXME: return OEGameCoreRenderingMetal1Video;
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


#pragma mark Save States
- (void)loadStateFromFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	if (!VMManager::HasValidVM()){
		stateToLoad = fileName;
		return;
	}
	
	WaitRequested = true;
	while(isExecuting)
		usleep(50);
	
	bool success = VMManager::LoadState(fileName.fileSystemRepresentation);
	WaitRequested = false;

	block(success, success ? nil : [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotLoadStateError userInfo:@{NSLocalizedDescriptionKey: @"PCSX2 Could not load the current state.", NSFilePathErrorKey: fileName}]);
}

- (void)saveStateToFileAtPath:(NSString *)fileName completionHandler:(void (^)(BOOL, NSError *))block
{
	if (!VMManager::HasValidVM())
		return;
	bool success = 	VMManager::SaveState(fileName.fileSystemRepresentation);
	
	block(success, success ? nil : [NSError errorWithDomain:OEGameCoreErrorDomain code:OEGameCoreCouldNotSaveStateError userInfo:@{NSLocalizedDescriptionKey: @"PCSX2 Could not save the current state.", NSFilePathErrorKey: fileName}]);
	
}

#pragma mark - Discs

- (NSUInteger)discCount
{
	return _maxDiscs ? _maxDiscs : 1;
}

- (void)setDisc:(NSUInteger)discNumber
{
	NSString *ToPassBack = [basePath stringByAppendingPathComponent:_allCueSheetFiles[discNumber - 1]];
	ToPassBack = [binCueFix(ToPassBack) stringByStandardizingPath];
	
	gamePath = ToPassBack;

	VMManager::ChangeDisc(gamePath.fileSystemRepresentation);
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
		[self ApplyUpscalePatches];
	} else if ([key isEqualToString:OEPSCSX2BlendingAccuracy]) {
		s_base_settings_interface->SetIntValue("EmuCore/GS", "accurate_blending_unit", [currentVal intValue]);
	}
	
	VMManager::ApplySettings();
}

- (void) ApplyUpscalePatches
{
	if([wildArmsGames containsObject:DiscID])
		s_base_settings_interface->SetBoolValue("EmuCore/GS", "UserHacks_WildHack", true);
	
	if([alignSpriteGames containsObject:DiscID]  && s_base_settings_interface->GetIntValue("EmuCore/GS", "upscale_multiplier") > 1)
		s_base_settings_interface->SetBoolValue("EmuCore/GS", "UserHacks_AlignSpriteX", true);
	else
		s_base_settings_interface->SetBoolValue("EmuCore/GS", "UserHacks_AlignSpriteX", false);
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
	
	s16 stereo[] = {Left, Right};
	[[current audioBufferAtIndex:0] write:stereo maxLength:sizeof(stereo)];
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
	GET_CURRENT_OR_RETURN(nullptr);
	
	[current.renderDelegate willRenderFrameOnAlternateThread];
	return current->hostDisplay.get();
}

void Host::ReleaseHostDisplay()
{
	GET_CURRENT_OR_RETURN();
	if(current->hostDisplay.get()){
		current->hostDisplay->DestroyRenderDevice();
		current->hostDisplay.reset();
	}
}

HostDisplay* Host::GetHostDisplay()
{
	GET_CURRENT_OR_RETURN(nullptr);
	
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

int Host::PresentFrameBuffer()
{
	GET_CURRENT_OR_RETURN(0);
	
	return [[current.renderDelegate presentationFramebuffer] intValue];
}

void Host::ResizeHostDisplay(u32 new_window_width, u32 new_window_height, float new_window_scale)
{
	
	//Once We have METAL,  we may be able to scale the frontend canvas
	
//	GET_CURRENT_OR_RETURN();
//
//	WindowInfo wi;
//		wi.type = WindowInfo::Type::MacOS;
//		wi.surface_width = new_window_width;
//		wi.surface_height = new_window_height;
//	current->hostDisplay.get()->ChangeRenderWindow(wi);
//	current->screenRect = OEIntRectMake(0, 0 , new_window_width, new_window_height);
	 
}

void Host::UpdateHostDisplay()
{
}

#pragma mark -

const IConsoleWriter* PatchesCon = &ConsoleWriter_Null;

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
