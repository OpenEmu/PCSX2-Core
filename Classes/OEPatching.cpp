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

#include <wx/stdpaths.h>
#include <wx/wfstream.h>
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
	static wxString gameName;
	static wxString gameSerial;
	static wxString gameCRC;
	static wxString gameVersion;
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
		PatchesCon->WriteLn(L"(GameDB) Changing EE/FPU clamp mode [mode=%d]", clampMode);
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

#define _UNKNOWN_GAME_KEY (L"_UNKNOWN_GAME_KEY")
/// Used to track the current game serial/id, and used to disable verbose logging of
/// applied patches if the game info hasn't changed.  (avoids spam when suspending/resuming
/// or using TAB or other things), but gets verbose again when booting (even if the same game).
/// File scope since it gets reset externally when rebooting
static wxString curGameKey = _UNKNOWN_GAME_KEY;

static Threading::Mutex mtx__ApplySettings;
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
	Threading::ScopedLock lock(mtx__ApplySettings);
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

	wxString gamePatch;
	wxString gameFixes;
	wxString gameCheats;
	wxString gameWsHacks;

	wxString gameCompat;
	wxString gameMemCardFilter;

	// The CRC can be known before the game actually starts (at the bios), so when
	// we have the CRC but we're still at the bios and the settings are changed
	// (e.g. the user presses TAB to speed up emulation), we don't want to apply the
	// settings as if the game is already running (title, loadeding patches, etc).
	bool ingame = (ElfCRC && (g_GameLoading || g_GameStarted));
	if (ingame)
		GameInfo::gameCRC.Printf(L"%8.8x", ElfCRC);
	else
		GameInfo::gameCRC = L""; // Needs to be reset when rebooting otherwise previously loaded patches may load

	if (ingame && !DiscSerial.IsEmpty())
		GameInfo::gameSerial = DiscSerial;

	const wxString newGameKey(ingame ? SysGetDiscID() : SysGetBiosDiscID());
//	const bool verbose(newGameKey != curGameKey && ingame);
	//Console.WriteLn(L"------> patches verbose: %d   prev: '%s'   new: '%s'", (int)verbose, WX_STR(curGameKey), WX_STR(newGameKey));

	curGameKey = newGameKey;

	ForgetLoadedPatches();

	if (!curGameKey.IsEmpty()) {
		auto game = GameDatabase::findGame(std::string(curGameKey.ToUTF8()));
		if (game) {
			GameInfo::gameName = StringUtil::UTF8StringToWxString(StringUtil::StdStringFromFormat("%s (%s)", game->name.c_str(), game->region.c_str()));
			gameCompat.Printf(" [Status = %s]", game->compatAsString());
			gameMemCardFilter = StringUtil::UTF8StringToWxString(game->memcardFiltersAsString());

			if (fixup.EnablePatches) {
				if (int patches = LoadPatchesFromGamesDB(GameInfo::gameCRC.ToStdString(), *game))
				{
					gamePatch.Printf(L" [%d Patches]", patches);
					PatchesCon->WriteLn(Color_Green, "(GameDB) Patches Loaded: %d", patches);
				}
				if (int fixes = loadGameSettings(fixup, *game))
					gameFixes.Printf(L" [%d Fixes]", fixes);
			}
		}
		else
		{
			// Set correct title for loading standalone/homebrew ELFs
			GameInfo::gameName = LastELF.AfterLast('\\');
		}
	}

	if (!gameMemCardFilter.IsEmpty())
		sioSetGameSerial(gameMemCardFilter);
	else
		sioSetGameSerial(curGameKey);

	if (GameInfo::gameName.IsEmpty() && GameInfo::gameSerial.IsEmpty() && GameInfo::gameCRC.IsEmpty())
	{
		// if all these conditions are met, it should mean that we're currently running BIOS code.
		// Chances are the BiosChecksum value is still zero or out of date, however -- because
		// the BIos isn't loaded until after initial calls to ApplySettings.

		GameInfo::gameName = L"Booting PS2 BIOS... ";
	}

	//Till the end of this function, entry CRC will be 00000000
	if (!GameInfo::gameCRC.Length())
	{
		Console.WriteLn(Color_Gray, "Patches: No CRC found, using 00000000 instead.");
		GameInfo::gameCRC = L"00000000";
	}

	// regular cheat patches
//	if (fixup.EnableCheats)
//		gameCheats.Printf(L" [%d Cheats]", LoadPatchesFromDir(GameInfo::gameCRC, EmuFolders::Cheats, L"Cheats"));

	// wide screen patches
	if (fixup.EnableWideScreenPatches)
	{
		if (int numberLoadedWideScreenPatches = LoadPatchesFromDir(GameInfo::gameCRC, EmuFolders::CheatsWS, L"Widescreen hacks"))
		{
			gameWsHacks.Printf(L" [%d widescreen hacks]", numberLoadedWideScreenPatches);
			Console.WriteLn(Color_Gray, "Found widescreen patches in the cheats_ws folder --> skipping cheats_ws.zip");
		}
		else
		{
			// No ws cheat files found at the cheats_ws folder, try the ws cheats zip file.
			const wxString cheats_ws_archive(Path::Combine(EmuFolders::Resources, wxFileName(L"cheats_ws.zip")));
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
