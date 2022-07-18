// Copyright (c) 2022, OpenEmu Team
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
//
// Code taken and adapted from PCSX2's AppCoreThread.cpp file.
//

#include "PrecompiledHeader.h"
#include "GameDatabase.h"

#include <string>
#include <sstream>
#include "fmt/core.h"

#include "common/FileSystem.h"
#include "common/StringUtil.h"
#include "common/Threading.h"

#include "ps2/BiosTools.h"
#include "GS.h"

#include "CDVD/CDVD.h"
#include "USB/USB.h"
#include "Elfheader.h"
#include "Patch.h"
#include "R5900Exceptions.h"
#include "Sio.h"


namespace GameInfo {
	static std::string gameName;
	static std::string gameSerial;
	static std::string gameCRC;
	static std::string gameVersion;
};

/// Load Game Settings found in database
/// (game fixes, round modes, clamp modes, etc...)
/// \return Returns number of gamefixes set
static int loadGameSettings(Pcsx2Config& dest, const GameDatabaseSchema::GameEntry& game)
{
	int gf = 0;

	if (game.eeRoundMode != GameDatabaseSchema::RoundMode::Undefined)
	{
		const SSE_RoundMode eeRM = (SSE_RoundMode)enum_cast(game.eeRoundMode);
		if (EnumIsValid(eeRM))
		{
			PatchesCon->WriteLn("(GameDB) Changing EE/FPU roundmode to %d [%s]", eeRM, EnumToString(eeRM));
			dest.Cpu.sseMXCSR.SetRoundMode(eeRM);
			gf++;
		}
	}

	if (game.vuRoundMode != GameDatabaseSchema::RoundMode::Undefined)
	{
		const SSE_RoundMode vuRM = (SSE_RoundMode)enum_cast(game.vuRoundMode);
		if (EnumIsValid(vuRM))
		{
			PatchesCon->WriteLn("(GameDB) Changing VU0/VU1 roundmode to %d [%s]", vuRM, EnumToString(vuRM));
			dest.Cpu.sseVUMXCSR.SetRoundMode(vuRM);
			gf++;
		}
	}

	if (game.eeClampMode != GameDatabaseSchema::ClampMode::Undefined)
	{
		const int clampMode = enum_cast(game.eeClampMode);
		PatchesCon->WriteLn("(GameDB) Changing EE/FPU clamp mode [mode=%d]", clampMode);
		dest.Cpu.Recompiler.fpuOverflow = (clampMode >= 1);
		dest.Cpu.Recompiler.fpuExtraOverflow = (clampMode >= 2);
		dest.Cpu.Recompiler.fpuFullMode = (clampMode >= 3);
		gf++;
	}

	if (game.vuClampMode != GameDatabaseSchema::ClampMode::Undefined)
	{
		const int clampMode = enum_cast(game.vuClampMode);
		PatchesCon->WriteLn("(GameDB) Changing VU0/VU1 clamp mode [mode=%d]", clampMode);
		dest.Cpu.Recompiler.vuOverflow = (clampMode >= 1);
		dest.Cpu.Recompiler.vuExtraOverflow = (clampMode >= 2);
		dest.Cpu.Recompiler.vuSignOverflow = (clampMode >= 3);
		gf++;
	}

	for (const auto& [id, mode] : game.speedHacks)
	{
		// Gamefixes are already guaranteed to be valid, any invalid ones are dropped
		// Legacy note - speedhacks are setup in the GameDB as integer values, but
		// are effectively booleans like the gamefixes
		dest.Speedhacks.Set(id, mode != 0);
		PatchesCon->WriteLn("(GameDB) Setting Speedhack '%s' to [mode=%d]", EnumToString(id), static_cast<int>(mode != 0));
		gf++;
	}

	for (const GamefixId id : game.gameFixes)
	{
		// Gamefixes are already guaranteed to be valid, any invalid ones are dropped
		// if the fix is present, it is said to be enabled
		dest.Gamefixes.Set(id, true);
		PatchesCon->WriteLn("(GameDB) Enabled Gamefix: %s", EnumToString(id));
		gf++;

		// The LUT is only used for 1 game so we allocate it only when the gamefix is enabled (save 4MB)
		if (id == Fix_GoemonTlbMiss && true)
			vtlb_Alloc_Ppmap();
	}

	return gf;
}

static std::string string_format(const std::string fmt, ...) {
	int size = ((int)fmt.size()) * 2 + 50;   // Use a rubric appropriate for your code
	std::string str;
	va_list ap;
	while (1) {     // Maximum two passes on a POSIX system...
		str.resize(size);
		va_start(ap, fmt);
		int n = vsnprintf((char *)str.data(), size, fmt.c_str(), ap);
		va_end(ap);
		if (n > -1 && n < size) {  // Everything worked
			str.resize(n);
			return str;
		}
		if (n > -1)  // Needed size returned
			size = n + 1;   // For null char
		else
			size *= 2;      // Guess at a larger size (OS specific)
	}
	return str;
}


#define _UNKNOWN_GAME_KEY ("_UNKNOWN_GAME_KEY")
/// Used to track the current game serial/id, and used to disable verbose logging of
/// applied patches if the game info hasn't changed.  (avoids spam when suspending/resuming
/// or using TAB or other things), but gets verbose again when booting (even if the same game).
/// File scope since it gets reset externally when rebooting
static std::string curGameKey = _UNKNOWN_GAME_KEY;

static std::mutex mtx__ApplySettings;
/// fixup = src + command line overrides + game overrides (according to elfCRC).
///
/// While at it, also [re]loads the relevant patches (but doesn't apply them),
/// updates the console title, and, for good measures, does some (static) sio stuff.
/// Oh, and updates curGameKey. I think that's it.
/// It doesn't require that the emulation is paused, and console writes/title should
/// be thread safe, but it's best if things don't move around much while it runs.
/// TODO: Trim this down so only OpenEmu-needed patches are loaded.
static void _ApplySettings(const Pcsx2Config& src, Pcsx2Config& fixup)
{
	std::scoped_lock lock(mtx__ApplySettings);
	// 'fixup' is the EmuConfig we're going to upload to the emulator, which very well may
	// differ from the user-configured EmuConfig settings.  So we make a copy here and then
	// we apply the commandline overrides and database gamefixes, and then upload 'fixup'
	// to the global EmuConfig.
	//
	// Note: It's important that we apply the commandline overrides *before* database fixes.
	// The database takes precedence (if enabled).

	fixup.CopyConfig(src);

	//Disable speed hacks as they might result in bad game quality
//	if (!g_Conf->EnableSpeedHacks)
		fixup.Speedhacks.DisableAll();

	// ...but enable game fixes which might allow games to run.
//	if (!g_Conf->EnableGameFixes)
//		fixup.Gamefixes.DisableAll();

	std::string gamePatch;
	std::string gameFixes;
	std::string gameCheats;
	std::string gameWsHacks;

	std::string gameCompat;
	std::string gameMemCardFilter;

	// The CRC can be known before the game actually starts (at the bios), so when
	// we have the CRC but we're still at the bios and the settings are changed
	// (e.g. the user presses TAB to speed up emulation), we don't want to apply the
	// settings as if the game is already running (title, loadeding patches, etc).
	bool ingame = (ElfCRC && (g_GameLoading || g_GameStarted));
	if (ingame)
		GameInfo::gameCRC = string_format("%8.8x", ElfCRC);
	else
		GameInfo::gameCRC = ""; // Needs to be reset when rebooting otherwise previously loaded patches may load

	if (ingame && !DiscSerial.empty())
		GameInfo::gameSerial = DiscSerial;

	const std::string newGameKey(ingame ? SysGetDiscID() : SysGetBiosDiscID());
//	const bool verbose(newGameKey != curGameKey && ingame);
	//Console.WriteLn(L"------> patches verbose: %d   prev: '%s'   new: '%s'", (int)verbose, WX_STR(curGameKey), WX_STR(newGameKey));

	curGameKey = newGameKey;

	ForgetLoadedPatches();

	if (!curGameKey.empty()) {
		auto game = GameDatabase::findGame(std::string(curGameKey));
		if (game) {
			GameInfo::gameName =  string_format("%s (%s)", game->name.c_str(), game->region.c_str());
			gameCompat = string_format(" [Status = %s]", game->compatAsString());
			gameMemCardFilter = game->memcardFiltersAsString();

			if (fixup.EnablePatches) {
				if (int patches = LoadPatchesFromGamesDB(GameInfo::gameCRC, *game))
				{
					gamePatch += string_format(" [%d Patches]", patches);
					PatchesCon->WriteLn(Color_Green, "(GameDB) Patches Loaded: %d", patches);
				}
				if (int fixes = loadGameSettings(fixup, *game))
					gameFixes += string_format(" [%d Fixes]", fixes);
			}
		}
		else
		{
			// Set correct title for loading standalone/homebrew ELFs
			GameInfo::gameName = LastELF.AfterLast('\\');
		}
	}

	if (!gameMemCardFilter.empty())
		sioSetGameSerial(gameMemCardFilter);
	else
		sioSetGameSerial(curGameKey);

	if (GameInfo::gameName.empty() && GameInfo::gameSerial.empty() && GameInfo::gameCRC.empty())
	{
		// if all these conditions are met, it should mean that we're currently running BIOS code.
		// Chances are the BiosChecksum value is still zero or out of date, however -- because
		// the BIos isn't loaded until after initial calls to ApplySettings.

		GameInfo::gameName = "Booting PS2 BIOS... ";
	}

	//Till the end of this function, entry CRC will be 00000000
	if (!GameInfo::gameCRC.Length())
	{
		Console.WriteLn(Color_Gray, "Patches: No CRC found, using 00000000 instead.");
		GameInfo::gameCRC = "00000000";
	}

	// regular cheat patches
//	if (fixup.EnableCheats)
//		gameCheats.Printf(L" [%d Cheats]", LoadPatchesFromDir(GameInfo::gameCRC, EmuFolders::Cheats, L"Cheats"));

	// wide screen patches
	if (fixup.EnableWideScreenPatches)
	{
		if (int numberLoadedWideScreenPatches = LoadPatchesFromDir(GameInfo::gameCRC, EmuFolders::CheatsWS, "Widescreen hacks"))
		{
			gameWsHacks.Printf(" [%d widescreen hacks]", numberLoadedWideScreenPatches);
			Console.WriteLn(Color_Gray, "Found widescreen patches in the cheats_ws folder --> skipping cheats_ws.zip");
		}
		else
		{
			// No ws cheat files found at the cheats_ws folder, try the ws cheats zip file.
			const std::string cheats_ws_archive(Path::Combine(EmuFolders::Resources, wxFileName(L"cheats_ws.zip")));
			if (wxFile::Exists(cheats_ws_archive))
			{
				wxFFileInputStream* strm = new wxFFileInputStream(cheats_ws_archive);
				int numberDbfCheatsLoaded = LoadPatchesFromZip(GameInfo::gameCRC, cheats_ws_archive, strm);
				PatchesCon->WriteLn(Color_Green, "(Wide Screen Cheats DB) Patches Loaded: %d", numberDbfCheatsLoaded);
				gameWsHacks.Printf(L" [%d widescreen hacks]", numberDbfCheatsLoaded);
			}
		}
	}
	
	gsUpdateFrequency(fixup);
}

void LoadAllPatchesAndStuff(const Pcsx2Config& cfg)
{
	Pcsx2Config dummy;
	_ApplySettings(cfg, dummy);
}
