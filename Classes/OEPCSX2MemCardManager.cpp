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

#include "PrecompiledHeader.h"
#include "Utilities/SafeArray.inl"
#include <wx/file.h>
#include <wx/dir.h>
#include <wx/stopwatch.h>

#include <chrono>

// IMPORTANT!  If this gets a macro redefinition error it means PluginCallbacks.h is included
// in a global-scope header, and that's a BAD THING.  Include it only into modules that need
// it, because some need to be able to alter its behavior using defines.  Like this:

struct Component_FileMcd;
#define PS2E_THISPTR Component_FileMcd*

#include "MemoryCardFile.h"
#include "MemoryCardFolder.h"

#include "System.h"
#include "AppConfig.h"

#include "svnrev.h"

#include "ConsoleLogger.h"

#include <wx/ffile.h>
#include <map>

static const int MCD_SIZE = 1024 * 8 * 16; // Legacy PSX card default size

static const int MC2_MBSIZE = 1024 * 528 * 2; // Size of a single megabyte of card data

// ECC code ported from mymc
// https://sourceforge.net/p/mymc-opl/code/ci/master/tree/ps2mc_ecc.py
// Public domain license

static u32 CalculateECC(u8* buf)
{
	const u8 parity_table[256] = {0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0,1,0,0,1,0,1,1,
	0,0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1,0,1,1,0,1,0,0,1,1,0,0,1,0,
	1,1,0,1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1,0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0,0,1,1,
	0,1,0,0,1,1,0,0,1,0,1,1,0,1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0,0,
	1,1,0,1,0,0,1,0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,
	0,1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1,0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0,1,0,0,1,0,
	1,1,0,0,1,1,0,1,0,0,1,1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1,0,1,1,0,1,0,0,1,1,0,0,
	1,0,1,1,0};

	const u8 column_parity_mask[256] = {0,7,22,17,37,34,51,52,52,51,34,37,17,22,
	7,0,67,68,85,82,102,97,112,119,119,112,97,102,82,85,68,67,82,85,68,67,119,112,
	97,102,102,97,112,119,67,68,85,82,17,22,7,0,52,51,34,37,37,34,51,52,0,7,22,17,
	97,102,119,112,68,67,82,85,85,82,67,68,112,119,102,97,34,37,52,51,7,0,17,22,
	22,17,0,7,51,52,37,34,51,52,37,34,22,17,0,7,7,0,17,22,34,37,52,51,112,119,102,
	97,85,82,67,68,68,67,82,85,97,102,119,112,112,119,102,97,85,82,67,68,68,67,82,
	85,97,102,119,112,51,52,37,34,22,17,0,7,7,0,17,22,34,37,52,51,34,37,52,51,7,0,
	17,22,22,17,0,7,51,52,37,34,97,102,119,112,68,67,82,85,85,82,67,68,112,119,102,
	97,17,22,7,0,52,51,34,37,37,34,51,52,0,7,22,17,82,85,68,67,119,112,97,102,102,
	97,112,119,67,68,85,82,67,68,85,82,102,97,112,119,119,112,97,102,82,85,68,67,
	0,7,22,17,37,34,51,52,52,51,34,37,17,22,7,0};

	u8 column_parity = 0x77;
	u8 line_parity_0 = 0x7F;
	u8 line_parity_1 = 0x7F;

	for (int i = 0; i < 128; i++)
	{
		u8 b = buf[i];
		column_parity ^= column_parity_mask[b];
		if (parity_table[b])
		{
			line_parity_0 ^= ~i;
			line_parity_1 ^= i;
		}
	}

	return column_parity | (line_parity_0 << 8) | (line_parity_1 << 16);
}

static bool ConvertNoECCtoRAW(wxString file_in, wxString file_out)
{
	bool result = false;
	wxFFile fin(file_in, "rb");

	if (fin.IsOpened())
	{
		wxFFile fout(file_out, "wb");

		if (fout.IsOpened())
		{
			u8 buffer[512];
			size_t size = fin.Length();

			for (size_t i = 0; i < (size / 512); i++)
			{
				fin.Read(buffer, 512);
				fout.Write(buffer, 512);

				for (int j = 0; j < 4; j++)
				{
					u32 checksum = CalculateECC(&buffer[j * 128]);
					fout.Write(&checksum, 3);
				}

				fout.Write("\0\0\0\0", 4);
			}

			result = true;
		}
	}

	return result;
}

static bool ConvertRAWtoNoECC(wxString file_in, wxString file_out)
{
	bool result = false;
	wxFFile fout(file_out, "wb");

	if (fout.IsOpened())
	{
		wxFFile fin(file_in, "rb");

		if (fin.IsOpened())
		{
			u8 buffer[512];
			size_t size = fin.Length();

			for (size_t i = 0; i < (size / 528); i++)
			{
				fin.Read(buffer, 512);
				fout.Write(buffer, 512);
				fin.Read(buffer, 16);
			}

			result = true;
		}
	}

	return result;
}

// --------------------------------------------------------------------------------------
//  FileMemoryCard
// --------------------------------------------------------------------------------------
// Provides thread-safe direct file IO mapping.
//
class FileMemoryCard
{
protected:
	wxFFile m_file[8];
	u8 m_effeffs[528 * 16];
	SafeArray<u8> m_currentdata;
	u64 m_chksum[8];
	bool m_ispsx[8];
	u32 m_chkaddr;

public:
	FileMemoryCard();
	virtual ~FileMemoryCard() = default;

	void Lock();
	void Unlock();

	void Open();
	void Close();

	s32 IsPresent(uint slot);
	void GetSizeInfo(uint slot, PS2E_McdSizeInfo& outways);
	bool IsPSX(uint slot);
	s32 Read(uint slot, u8* dest, u32 adr, int size);
	s32 Save(uint slot, const u8* src, u32 adr, int size);
	s32 EraseBlock(uint slot, u32 adr);
	u64 GetCRC(uint slot);

protected:
	bool Seek(wxFFile& f, u32 adr);
	bool Create(const wxString& mcdFile, uint sizeInMB);

	wxString GetDisabledMessage(uint slot) const
	{
		return wxsFormat(pxE(L"The PS2-slot %d has been automatically disabled.  You can correct the problem\nand re-enable it at any time using Config:Memory cards from the main menu."), slot //TODO: translate internal slot index to human-readable slot description
		);
	}
};

struct Component_FileMcd
{
	PS2E_ComponentAPI_Mcd api; // callbacks the plugin provides back to the emulator
	FileMemoryCard impl;       // class-based implementations we refer to when API is invoked
	FolderMemoryCardAggregator implFolder;

	Component_FileMcd();
};


// --------------------------------------------------------------------------------------
//  Library API Implementations
// --------------------------------------------------------------------------------------
static const char* PS2E_CALLBACK FileMcd_GetName()
{
	return "PlainJane Mcd";
}

static const PS2E_VersionInfo* PS2E_CALLBACK FileMcd_GetVersion(u32 component)
{
	static const PS2E_VersionInfo version = {0, 1, 0, SVN_REV};
	return &version;
}

static s32 PS2E_CALLBACK FileMcd_Test(u32 component, const PS2E_EmulatorInfo* xinfo)
{
	if (component != PS2E_TYPE_Mcd)
		return 0;

	// Check and make sure the user has a hard drive?
	// Probably not necessary :p
	return 1;
}

static PS2E_THISPTR PS2E_CALLBACK FileMcd_NewComponentInstance(u32 component)
{
	if (component != PS2E_TYPE_Mcd)
		return NULL;

	try
	{
		return new Component_FileMcd();
	}
	catch (std::bad_alloc&)
	{
		Console.Error("Allocation failed on Component_FileMcd! (out of memory?)");
	}
	return NULL;
}

static void PS2E_CALLBACK FileMcd_DeleteComponentInstance(PS2E_THISPTR instance)
{
	delete instance;
}

static void PS2E_CALLBACK FileMcd_SetSettingsFolder(const char* folder)
{
}

static void PS2E_CALLBACK FileMcd_SetLogFolder(const char* folder)
{
}

uint FileMcd_ConvertToSlot(uint port, uint slot)
{
	if (slot == 0)
		return port;
	if (port == 0)
		return slot + 1; // multitap 1
	return slot + 4;     // multitap 2
}

static void PS2E_CALLBACK FileMcd_EmuOpen(PS2E_THISPTR thisptr, const PS2E_SessionInfo* session)
{
	// detect inserted memory card types
	for (uint slot = 0; slot < 8; ++slot)
	{
		if (g_Conf->Mcd[slot].Enabled)
		{
			MemoryCardType type = MemoryCardType::MemoryCard_File; // default to file if we can't find anything at the path so it gets auto-generated

			const wxString path = g_Conf->FullpathToMcd(slot);
			if (wxFileExists(path))
			{
				type = MemoryCardType::MemoryCard_File;
			}
			else if (wxDirExists(path))
			{
				type = MemoryCardType::MemoryCard_Folder;
			}

			g_Conf->Mcd[slot].Type = type;
		}
	}

	thisptr->impl.Open();
	thisptr->implFolder.SetFiltering(g_Conf->EmuOptions.McdFolderAutoManage);
	thisptr->implFolder.Open();
}

static void PS2E_CALLBACK FileMcd_EmuClose(PS2E_THISPTR thisptr)
{
	thisptr->implFolder.Close();
	thisptr->impl.Close();
}

static s32 PS2E_CALLBACK FileMcd_IsPresent(PS2E_THISPTR thisptr, uint port, uint slot)
{
	const uint combinedSlot = FileMcd_ConvertToSlot(port, slot);
	switch (g_Conf->Mcd[combinedSlot].Type)
	{
		case MemoryCardType::MemoryCard_File:
			return thisptr->impl.IsPresent(combinedSlot);
		case MemoryCardType::MemoryCard_Folder:
			return thisptr->implFolder.IsPresent(combinedSlot);
		default:
			return false;
	}
}

static void PS2E_CALLBACK FileMcd_GetSizeInfo(PS2E_THISPTR thisptr, uint port, uint slot, PS2E_McdSizeInfo* outways)
{
	const uint combinedSlot = FileMcd_ConvertToSlot(port, slot);
	switch (g_Conf->Mcd[combinedSlot].Type)
	{
		case MemoryCardType::MemoryCard_File:
			thisptr->impl.GetSizeInfo(combinedSlot, *outways);
			break;
		case MemoryCardType::MemoryCard_Folder:
			thisptr->implFolder.GetSizeInfo(combinedSlot, *outways);
			break;
		default:
			return;
	}
}

static bool PS2E_CALLBACK FileMcd_IsPSX(PS2E_THISPTR thisptr, uint port, uint slot)
{
	const uint combinedSlot = FileMcd_ConvertToSlot(port, slot);
	switch (g_Conf->Mcd[combinedSlot].Type)
	{
		case MemoryCardType::MemoryCard_File:
			return thisptr->impl.IsPSX(combinedSlot);
		case MemoryCardType::MemoryCard_Folder:
			return thisptr->implFolder.IsPSX(combinedSlot);
		default:
			return false;
	}
}

static s32 PS2E_CALLBACK FileMcd_Read(PS2E_THISPTR thisptr, uint port, uint slot, u8* dest, u32 adr, int size)
{
	const uint combinedSlot = FileMcd_ConvertToSlot(port, slot);
	switch (g_Conf->Mcd[combinedSlot].Type)
	{
		case MemoryCardType::MemoryCard_File:
			return thisptr->impl.Read(combinedSlot, dest, adr, size);
		case MemoryCardType::MemoryCard_Folder:
			return thisptr->implFolder.Read(combinedSlot, dest, adr, size);
		default:
			return 0;
	}
}

static s32 PS2E_CALLBACK FileMcd_Save(PS2E_THISPTR thisptr, uint port, uint slot, const u8* src, u32 adr, int size)
{
	const uint combinedSlot = FileMcd_ConvertToSlot(port, slot);
	switch (g_Conf->Mcd[combinedSlot].Type)
	{
		case MemoryCardType::MemoryCard_File:
			return thisptr->impl.Save(combinedSlot, src, adr, size);
		case MemoryCardType::MemoryCard_Folder:
			return thisptr->implFolder.Save(combinedSlot, src, adr, size);
		default:
			return 0;
	}
}

static s32 PS2E_CALLBACK FileMcd_EraseBlock(PS2E_THISPTR thisptr, uint port, uint slot, u32 adr)
{
	const uint combinedSlot = FileMcd_ConvertToSlot(port, slot);
	switch (g_Conf->Mcd[combinedSlot].Type)
	{
		case MemoryCardType::MemoryCard_File:
			return thisptr->impl.EraseBlock(combinedSlot, adr);
		case MemoryCardType::MemoryCard_Folder:
			return thisptr->implFolder.EraseBlock(combinedSlot, adr);
		default:
			return 0;
	}
}

static u64 PS2E_CALLBACK FileMcd_GetCRC(PS2E_THISPTR thisptr, uint port, uint slot)
{
	const uint combinedSlot = FileMcd_ConvertToSlot(port, slot);
	switch (g_Conf->Mcd[combinedSlot].Type)
	{
		case MemoryCardType::MemoryCard_File:
			return thisptr->impl.GetCRC(combinedSlot);
		case MemoryCardType::MemoryCard_Folder:
			return thisptr->implFolder.GetCRC(combinedSlot);
		default:
			return 0;
	}
}

static void PS2E_CALLBACK FileMcd_NextFrame(PS2E_THISPTR thisptr, uint port, uint slot)
{
	const uint combinedSlot = FileMcd_ConvertToSlot(port, slot);
	switch (g_Conf->Mcd[combinedSlot].Type)
	{
		//case MemoryCardType::MemoryCard_File:
		//	thisptr->impl.NextFrame( combinedSlot );
		//	break;
		case MemoryCardType::MemoryCard_Folder:
			thisptr->implFolder.NextFrame(combinedSlot);
			break;
		default:
			return;
	}
}

static bool PS2E_CALLBACK FileMcd_ReIndex(PS2E_THISPTR thisptr, uint port, uint slot, const wxString& filter)
{
	const uint combinedSlot = FileMcd_ConvertToSlot(port, slot);
	switch (g_Conf->Mcd[combinedSlot].Type)
	{
		//case MemoryCardType::MemoryCard_File:
		//	return thisptr->impl.ReIndex( combinedSlot, filter );
		//	break;
		case MemoryCardType::MemoryCard_Folder:
			return thisptr->implFolder.ReIndex(combinedSlot, g_Conf->EmuOptions.McdFolderAutoManage, filter);
			break;
		default:
			return false;
	}
}

static const PS2E_LibraryAPI FileMcd_Library =
	{
		FileMcd_GetName,
		FileMcd_GetVersion,
		FileMcd_Test,
		FileMcd_NewComponentInstance,
		FileMcd_DeleteComponentInstance,
		FileMcd_SetSettingsFolder,
		FileMcd_SetLogFolder};

// If made into an external plugin, this function should be renamed to PS2E_InitAPI, so that
// PCSX2 can find the export in the expected location.
extern "C" const PS2E_LibraryAPI* FileMcd_InitAPI(const PS2E_EmulatorInfo* emuinfo)
{
	return &FileMcd_Library;
}

Component_FileMcd::Component_FileMcd()
{
	memzero(api);

	api.Base.EmuOpen = FileMcd_EmuOpen;
	api.Base.EmuClose = FileMcd_EmuClose;

	api.McdIsPresent = FileMcd_IsPresent;
	api.McdGetSizeInfo = FileMcd_GetSizeInfo;
	api.McdIsPSX = FileMcd_IsPSX;
	api.McdRead = FileMcd_Read;
	api.McdSave = FileMcd_Save;
	api.McdEraseBlock = FileMcd_EraseBlock;
	api.McdGetCRC = FileMcd_GetCRC;
	api.McdNextFrame = FileMcd_NextFrame;
	api.McdReIndex = FileMcd_ReIndex;
}

FileMemoryCard::FileMemoryCard()
{
	memset8<0xff>(m_effeffs);
	m_chkaddr = 0;
}

void FileMemoryCard::Open()
{
	for (int slot = 0; slot < 8; ++slot)
	{
		if (FileMcd_IsMultitapSlot(slot))
		{
			if (!EmuConfig.MultitapPort0_Enabled && (FileMcd_GetMtapPort(slot) == 0))
				continue;
			if (!EmuConfig.MultitapPort1_Enabled && (FileMcd_GetMtapPort(slot) == 1))
				continue;
		}

		wxFileName fname(g_Conf->FullpathToMcd(slot));
		wxString str(fname.GetFullPath());
		bool cont = false;

		if (fname.GetFullName().IsEmpty())
		{
			str = L"[empty filename]";
			cont = true;
		}

		if (!g_Conf->Mcd[slot].Enabled)
		{
			str = L"[disabled]";
			cont = true;
		}

		if (g_Conf->Mcd[slot].Type != MemoryCardType::MemoryCard_File)
		{
			str = L"[is not memcard file]";
			cont = true;
		}

		Console.WriteLn(cont ? Color_Gray : Color_Green, L"McdSlot %u [File]: " + str, slot);
		if (cont)
			continue;

		const wxULongLong fsz = fname.GetSize();
		if ((fsz == 0) || (fsz == wxInvalidSize))
		{
			// FIXME : Ideally this should prompt the user for the size of the
			// memory card file they would like to create, instead of trying to
			// create one automatically.

			if (!Create(str, 8))
			{
				Msgbox::Alert(
					wxsFormat(_("Could not create a memory card: \n\n%s\n\n"), str.c_str()) +
					GetDisabledMessage(slot));
			}
		}

		// [TODO] : Add memcard size detection and report it to the console log.
		//   (8MB, 256Mb, formatted, unformatted, etc ...)

		if (str.EndsWith(".bin"))
		{
			wxString newname = str + "x";
			if (!ConvertNoECCtoRAW(str, newname))
			{
				Console.Error(L"Could convert memory card: " + str);
				wxRemoveFile(newname);
				continue;
			}
			str = newname;
		}

		if (!m_file[slot].Open(str.c_str(), L"r+b"))
		{
			// Translation note: detailed description should mention that the memory card will be disabled
			// for the duration of this session.
			Msgbox::Alert(
				wxsFormat(_("Access denied to memory card: \n\n%s\n\n"), str.c_str()) +
				GetDisabledMessage(slot));
		}
		else // Load checksum
		{
			m_ispsx[slot] = m_file[slot].Length() == 0x20000;
			m_chkaddr = 0x210;

			if (!m_ispsx[slot] && !!m_file[slot].Seek(m_chkaddr))
				m_file[slot].Read(&m_chksum[slot], 8);
		}
	}
}

void FileMemoryCard::Close()
{
	for (int slot = 0; slot < 8; ++slot)
	{
		if (m_file[slot].IsOpened())
		{
			// Store checksum
			if (!m_ispsx[slot] && !!m_file[slot].Seek(m_chkaddr))
				m_file[slot].Write(&m_chksum[slot], 8);

			m_file[slot].Close();

			if (m_file[slot].GetName().EndsWith(".binx"))
			{
				wxString name = m_file[slot].GetName();
				wxString name_old = name.SubString(0, name.Last('.')) + "bin";
				if (ConvertRAWtoNoECC(name, name_old))
					wxRemoveFile(name);
			}
		}
	}
}

// Returns FALSE if the seek failed (is outside the bounds of the file).
bool FileMemoryCard::Seek(wxFFile& f, u32 adr)
{
	const u32 size = f.Length();

	// If anyone knows why this filesize logic is here (it appears to be related to legacy PSX
	// cards, perhaps hacked support for some special emulator-specific memcard formats that
	// had header info?), then please replace this comment with something useful.  Thanks!  -- air

	u32 offset = 0;

	if (size == MCD_SIZE + 64)
		offset = 64;
	else if (size == MCD_SIZE + 3904)
		offset = 3904;
	else
	{
		// perform sanity checks here?
	}

	return f.Seek(adr + offset);
}

// returns FALSE if an error occurred (either permission denied or disk full)
bool FileMemoryCard::Create(const wxString& mcdFile, uint sizeInMB)
{
	//int enc[16] = {0x77,0x7f,0x7f,0x77,0x7f,0x7f,0x77,0x7f,0x7f,0x77,0x7f,0x7f,0,0,0,0};

	Console.WriteLn(L"(FileMcd) Creating new %uMB memory card: " + mcdFile, sizeInMB);

	wxFFile fp(mcdFile, L"wb");
	if (!fp.IsOpened())
		return false;

	for (uint i = 0; i < (MC2_MBSIZE * sizeInMB) / sizeof(m_effeffs); i++)
	{
		if (fp.Write(m_effeffs, sizeof(m_effeffs)) == 0)
			return false;
	}
	return true;
}

s32 FileMemoryCard::IsPresent(uint slot)
{
	return m_file[slot].IsOpened();
}

void FileMemoryCard::GetSizeInfo(uint slot, PS2E_McdSizeInfo& outways)
{
	outways.SectorSize = 512;             // 0x0200
	outways.EraseBlockSizeInSectors = 16; // 0x0010
	outways.Xor = 18;                     // 0x12, XOR 02 00 00 10

	if (pxAssert(m_file[slot].IsOpened()))
		outways.McdSizeInSectors = m_file[slot].Length() / (outways.SectorSize + outways.EraseBlockSizeInSectors);
	else
		outways.McdSizeInSectors = 0x4000;

	u8* pdata = (u8*)&outways.McdSizeInSectors;
	outways.Xor ^= pdata[0] ^ pdata[1] ^ pdata[2] ^ pdata[3];
}

bool FileMemoryCard::IsPSX(uint slot)
{
	return m_ispsx[slot];
}

s32 FileMemoryCard::Read(uint slot, u8* dest, u32 adr, int size)
{
	wxFFile& mcfp(m_file[slot]);
	if (!mcfp.IsOpened())
	{
		DevCon.Error("(FileMcd) Ignoring attempted read from disabled slot.");
		memset(dest, 0, size);
		return 1;
	}
	if (!Seek(mcfp, adr))
		return 0;
	return mcfp.Read(dest, size) != 0;
}

uint FileMcd_GetMtapPort(uint slot)
{
	switch (slot)
	{
		case 0:
		case 2:
		case 3:
		case 4:
			return 0;
		case 1:
		case 5:
		case 6:
		case 7:
			return 1;

			jNO_DEFAULT
	}

	return 0; // technically unreachable.
}

s32 FileMemoryCard::Save(uint slot, const u8* src, u32 adr, int size)
{
	wxFFile& mcfp(m_file[slot]);

	if (!mcfp.IsOpened())
	{
		DevCon.Error("(FileMcd) Ignoring attempted save/write to disabled slot.");
		return 1;
	}

	if (m_ispsx[slot])
	{
		m_currentdata.MakeRoomFor(size);
		for (int i = 0; i < size; i++)
			m_currentdata[i] = src[i];
	}
	else
	{
		if (!Seek(mcfp, adr))
			return 0;
		m_currentdata.MakeRoomFor(size);
		mcfp.Read(m_currentdata.GetPtr(), size);


		for (int i = 0; i < size; i++)
		{
			if ((m_currentdata[i] & src[i]) != src[i])
				Console.Warning("(FileMcd) Warning: writing to uncleared data. (%d) [%08X]", slot, adr);
			m_currentdata[i] &= src[i];
		}

		// Checksumness
		{
			if (adr == m_chkaddr)
				Console.Warning("(FileMcd) Warning: checksum sector overwritten. (%d)", slot);

			u64* pdata = (u64*)&m_currentdata[0];
			u32 loops = size / 8;

			for (u32 i = 0; i < loops; i++)
				m_chksum[slot] ^= pdata[i];
		}
	}

	if (!Seek(mcfp, adr))
		return 0;

	int status = mcfp.Write(m_currentdata.GetPtr(), size);

	if (status)
	{
		static auto last = std::chrono::time_point<std::chrono::system_clock>();

		std::chrono::duration<float> elapsed = std::chrono::system_clock::now() - last;
		if (elapsed > std::chrono::seconds(5))
		{
			wxString name, ext;
			wxFileName::SplitPath(m_file[slot].GetName(), NULL, NULL, &name, &ext);
			OSDlog(Color_StrongYellow, false, "Memory Card %s written.", (const char*)(name + "." + ext).c_str());
			last = std::chrono::system_clock::now();
		}
		return 1;
	}

	return 0;
}

s32 FileMemoryCard::EraseBlock(uint slot, u32 adr)
{
	wxFFile& mcfp(m_file[slot]);

	if (!mcfp.IsOpened())
	{
		DevCon.Error("MemoryCard: Ignoring erase for disabled slot.");
		return 1;
	}

	if (!Seek(mcfp, adr))
		return 0;
	return mcfp.Write(m_effeffs, sizeof(m_effeffs)) != 0;
}

u64 FileMemoryCard::GetCRC(uint slot)
{
	wxFFile& mcfp(m_file[slot]);
	if (!mcfp.IsOpened())
		return 0;

	u64 retval = 0;

	if (m_ispsx[slot])
	{
		if (!Seek(mcfp, 0))
			return 0;

		// Process the file in 4k chunks.  Speeds things up significantly.

		u64 buffer[528 * 8]; // use 528 (sector size), ensures even divisibility

		const uint filesize = mcfp.Length() / sizeof(buffer);
		for (uint i = filesize; i; --i)
		{
			mcfp.Read(&buffer, sizeof(buffer));
			for (uint t = 0; t < ArraySize(buffer); ++t)
				retval ^= buffer[t];
		}
	}
	else
	{
		retval = m_chksum[slot];
	}

	return retval;
}

extern bool RemoveDirectory( const wxString& dirname );

FolderMemoryCard::FolderMemoryCard() {
	m_slot = 0;
	m_isEnabled = false;
	m_performFileWrites = false;
	m_framesUntilFlush = 0;
	m_timeLastWritten = 0;
	m_filteringEnabled = false;
	m_filteringString = L"";
}

void FolderMemoryCard::InitializeInternalData() {
	memset( &m_superBlock, 0xFF, sizeof( m_superBlock ) );
	memset( &m_indirectFat, 0xFF, sizeof( m_indirectFat ) );
	memset( &m_fat, 0xFF, sizeof( m_fat ) );
	memset( &m_backupBlock1, 0xFF, sizeof( m_backupBlock1 ) );
	memset( &m_backupBlock2, 0xFF, sizeof( m_backupBlock2 ) );
	m_cache.clear();
	m_oldDataCache.clear();
	m_lastAccessedFile.CloseAll();
	m_fileMetadataQuickAccess.clear();
	m_timeLastWritten = 0;
	m_isEnabled = false;
	m_framesUntilFlush = 0;
	m_performFileWrites = true;
	m_filteringEnabled = false;
	m_filteringString = L"";
}

bool FolderMemoryCard::IsFormatted() const {
	// this should be a good enough arbitrary check, if someone can think of a case where this doesn't work feel free to change
	return m_superBlock.raw[0x16] == 0x6F;
}

void FolderMemoryCard::Open( const bool enableFiltering, const wxString& filter ) {
	Open( g_Conf->FullpathToMcd( m_slot ), g_Conf->Mcd[m_slot], 0, enableFiltering, filter, false );
}

void FolderMemoryCard::Open( const wxString& fullPath, const AppConfig::McdOptions& mcdOptions, const u32 sizeInClusters, const bool enableFiltering, const wxString& filter, bool simulateFileWrites ) {
	InitializeInternalData();
	m_performFileWrites = !simulateFileWrites;

	wxFileName configuredFileName( fullPath );
	m_folderName = wxFileName( configuredFileName.GetFullPath() + L"/" );
	wxString str( configuredFileName.GetFullPath() );
	bool disabled = false;

	if ( mcdOptions.Enabled && mcdOptions.Type == MemoryCardType::MemoryCard_Folder ) {
		if ( configuredFileName.GetFullName().IsEmpty() ) {
			str = L"[empty filename]";
			disabled = true;
		}
		if ( !disabled && configuredFileName.FileExists() ) {
			str = L"[is file, should be folder]";
			disabled = true;
		}

		// if nothing exists at a valid location, create a directory for the memory card
		if ( !disabled && m_performFileWrites && !m_folderName.DirExists() ) {
			if ( !m_folderName.Mkdir() ) {
				str = L"[couldn't create folder]";
				disabled = true;
			}
		}
	} else {
		// if the user has disabled this slot or is using a different memory card type, just return without a console log
		return;
	}

	Console.WriteLn( disabled ? Color_Gray : Color_Green, L"McdSlot %u: [Folder] " + str, m_slot );
	if ( disabled ) return;

	m_isEnabled = true;
	m_filteringEnabled = enableFiltering;
	m_filteringString = filter;
	LoadMemoryCardData( sizeInClusters, enableFiltering, filter );

	SetTimeLastWrittenToNow();
	m_framesUntilFlush = 0;
}

void FolderMemoryCard::Close( bool flush ) {
	if ( !m_isEnabled ) { return; }

	if ( flush ) {
		Flush();
	}

	m_cache.clear();
	m_oldDataCache.clear();
	m_lastAccessedFile.CloseAll();
	m_fileMetadataQuickAccess.clear();
}

bool FolderMemoryCard::ReIndex( bool enableFiltering, const wxString& filter ) {
	if ( !m_isEnabled ) { return false; }

	if ( m_filteringEnabled != enableFiltering || m_filteringString != filter ) {
		Close();
		Open( enableFiltering, filter );
		return true;
	}

	return false;
}

void FolderMemoryCard::LoadMemoryCardData( const u32 sizeInClusters, const bool enableFiltering, const wxString& filter ) {
	bool formatted = false;

	// read superblock if it exists
	wxFileName superBlockFileName( m_folderName.GetPath(), L"_pcsx2_superblock" );
	if ( superBlockFileName.FileExists() ) {
		wxFFile superBlockFile( superBlockFileName.GetFullPath().c_str(), L"rb" );
		if ( superBlockFile.IsOpened() && superBlockFile.Read( &m_superBlock.raw, sizeof( m_superBlock.raw ) ) >= sizeof( m_superBlock.data ) ) {
			formatted = IsFormatted();
		}
	}

	if ( sizeInClusters > 0 && sizeInClusters != GetSizeInClusters() ) {
		SetSizeInClusters( sizeInClusters );
		FlushBlock( 0 );
	}

	// if superblock was valid, load folders and files
	if ( formatted ) {
		if ( enableFiltering ) {
			Console.WriteLn( Color_Green, L"(FolderMcd) Indexing slot %u with filter \"%s\".", m_slot, WX_STR( filter ) );
		} else {
			Console.WriteLn( Color_Green, L"(FolderMcd) Indexing slot %u without filter.", m_slot );
		}

		CreateFat();
		CreateRootDir();
		MemoryCardFileEntry* const rootDirEntry = &m_fileEntryDict[m_superBlock.data.rootdir_cluster].entries[0];
		AddFolder( rootDirEntry, m_folderName.GetPath(), nullptr, enableFiltering, filter );
		
		#ifdef DEBUG_WRITE_FOLDER_CARD_IN_MEMORY_TO_FILE_ON_CHANGE
		WriteToFile( m_folderName.GetFullPath().RemoveLast() + L"-debug_" +  wxDateTime::Now().Format( L"%Y-%m-%d-%H-%M-%S" ) + L"_load.ps2" );
		#endif
	}
}

void FolderMemoryCard::CreateFat() {
	const u32 totalClusters = m_superBlock.data.clusters_per_card;
	const u32 clusterSize = m_superBlock.data.page_len * m_superBlock.data.pages_per_cluster;
	const u32 fatEntriesPerCluster = clusterSize / 4;
	const u32 countFatClusters = ( totalClusters % fatEntriesPerCluster ) != 0 ? ( totalClusters / fatEntriesPerCluster + 1 ) : ( totalClusters / fatEntriesPerCluster );
	const u32 countDataClusters = m_superBlock.data.alloc_end;

	// create indirect FAT
	for ( unsigned int i = 0; i < countFatClusters; ++i ) {
		m_indirectFat.data[0][i] = GetFreeSystemCluster();
	}

	// fill FAT with default values
	for ( unsigned int i = 0; i < countDataClusters; ++i ) {
		m_fat.data[0][0][i] = 0x7FFFFFFFu;
	}
}

void FolderMemoryCard::CreateRootDir() {
	MemoryCardFileEntryCluster* const rootCluster = &m_fileEntryDict[m_superBlock.data.rootdir_cluster];
	memset( &rootCluster->entries[0].entry.raw[0], 0x00, sizeof( rootCluster->entries[0].entry.raw ) );
	rootCluster->entries[0].entry.data.mode = MemoryCardFileEntry::Mode_Read | MemoryCardFileEntry::Mode_Write | MemoryCardFileEntry::Mode_Execute
											| MemoryCardFileEntry::Mode_Directory | MemoryCardFileEntry::Mode_Unknown0x0400 | MemoryCardFileEntry::Mode_Used;
	rootCluster->entries[0].entry.data.length = 2;
	rootCluster->entries[0].entry.data.name[0] = '.';

	memset( &rootCluster->entries[1].entry.raw[0], 0x00, sizeof( rootCluster->entries[1].entry.raw ) );
	rootCluster->entries[1].entry.data.mode = MemoryCardFileEntry::Mode_Write | MemoryCardFileEntry::Mode_Execute | MemoryCardFileEntry::Mode_Directory
											| MemoryCardFileEntry::Mode_Unknown0x0400 | MemoryCardFileEntry::Mode_Unknown0x2000 | MemoryCardFileEntry::Mode_Used;
	rootCluster->entries[1].entry.data.name[0] = '.';
	rootCluster->entries[1].entry.data.name[1] = '.';

	// mark root dir cluster as used
	m_fat.data[0][0][m_superBlock.data.rootdir_cluster] = LastDataCluster | DataClusterInUseMask;
}

u32 FolderMemoryCard::GetFreeSystemCluster() const {
	// first block is reserved for superblock
	u32 highestUsedCluster = ( m_superBlock.data.pages_per_block / m_superBlock.data.pages_per_cluster ) - 1;

	// can't use any of the indirect fat clusters
	for ( int i = 0; i < IndirectFatClusterCount; ++i ) {
		highestUsedCluster = std::max( highestUsedCluster, m_superBlock.data.ifc_list[i] );
	}

	// or fat clusters
	for ( int i = 0; i < IndirectFatClusterCount; ++i ) {
		for ( int j = 0; j < ClusterSize / 4; ++j ) {
			if ( m_indirectFat.data[i][j] != IndirectFatUnused ) {
				highestUsedCluster = std::max( highestUsedCluster, m_indirectFat.data[i][j] );
			}
		}
	}

	return highestUsedCluster + 1;
}

u32 FolderMemoryCard::GetAmountDataClusters() const {
	// BIOS reports different cluster values than what the memory card actually has, match that when adding files
	//  8mb card -> BIOS:  7999 clusters / Superblock:  8135 clusters
	// 16mb card -> BIOS: 15999 clusters / Superblock: 16295 clusters
	// 32mb card -> BIOS: 31999 clusters / Superblock: 32615 clusters
	// 64mb card -> BIOS: 64999 clusters / Superblock: 65255 clusters
	return ( m_superBlock.data.alloc_end / 1000 ) * 1000 - 1;
}

u32 FolderMemoryCard::GetFreeDataCluster() const {
	const u32 countDataClusters = GetAmountDataClusters();

	for ( unsigned int i = 0; i < countDataClusters; ++i ) {
		const u32 cluster = m_fat.data[0][0][i];

		if ( ( cluster & DataClusterInUseMask ) == 0 ) {
			return i;
		}
	}

	return 0xFFFFFFFFu;
}

u32 FolderMemoryCard::GetAmountFreeDataClusters() const {
	const u32 countDataClusters = GetAmountDataClusters();
	u32 countFreeDataClusters = 0;

	for ( unsigned int i = 0; i < countDataClusters; ++i ) {
		const u32 cluster = m_fat.data[0][0][i];

		if ( ( cluster & DataClusterInUseMask ) == 0 ) {
			++countFreeDataClusters;
		}
	}

	return countFreeDataClusters;
}

u32 FolderMemoryCard::GetLastClusterOfData( const u32 cluster ) const {
	u32 entryCluster;
	u32 nextCluster = cluster;
	do {
		entryCluster = nextCluster;
		nextCluster = m_fat.data[0][0][entryCluster] & NextDataClusterMask;
	} while ( nextCluster != LastDataCluster );
	return entryCluster;
}

MemoryCardFileEntry* FolderMemoryCard::AppendFileEntryToDir( const MemoryCardFileEntry* const dirEntry ) {
	u32 entryCluster = GetLastClusterOfData( dirEntry->entry.data.cluster );

	MemoryCardFileEntry* newFileEntry;
	if ( dirEntry->entry.data.length % 2 == 0 ) {
		// need new cluster
		u32 newCluster = GetFreeDataCluster();
		if ( newCluster == 0xFFFFFFFFu ) { return nullptr; }
		m_fat.data[0][0][entryCluster] = newCluster | DataClusterInUseMask;
		m_fat.data[0][0][newCluster] = LastDataCluster | DataClusterInUseMask;
		newFileEntry = &m_fileEntryDict[newCluster].entries[0];
	} else {
		// can use last page of existing clusters
		newFileEntry = &m_fileEntryDict[entryCluster].entries[1];
	}

	return newFileEntry;
}

bool FilterMatches( const wxString& fileName, const wxString& filter ) {
	size_t start = 0;
	size_t len = filter.Len();
	while ( start < len ) {
		size_t end = filter.find( '/', start );
		if ( end == wxString::npos ) {
			end = len;
		}

		wxString singleFilter = filter.Mid( start, end - start );
		if ( fileName.Contains( singleFilter ) ) {
			return true;
		}

		start = end + 1;
	}

	return false;
}

bool FolderMemoryCard::AddFolder( MemoryCardFileEntry* const dirEntry, const wxString& dirPath, MemoryCardFileMetadataReference* parent, const bool enableFiltering, const wxString& filter ) {
	wxDir dir( dirPath );
	if ( dir.IsOpened() ) {
		wxString fileName;
		bool hasNext;

		wxString localFilter;
		if ( enableFiltering ) {
			bool hasFilter = !filter.IsEmpty();
			if ( hasFilter ) {
				localFilter = L"DATA-SYSTEM/BWNETCNF/" + filter;
			} else {
				localFilter = L"DATA-SYSTEM/BWNETCNF";
			}
		}

		int entryNumber = 2; // include . and ..
		hasNext = dir.GetFirst( &fileName );
		while ( hasNext ) {
			if ( fileName.StartsWith( L"_pcsx2_" ) ) {
				hasNext = dir.GetNext( &fileName );
				continue;
			}

			wxFileName fileInfo( dirPath, fileName );
			bool isFile = wxFile::Exists( fileInfo.GetFullPath() );

			if ( isFile ) {
				// don't load files in the root dir if we're filtering; no official software stores files there
				if ( enableFiltering && parent == nullptr ) {
					hasNext = dir.GetNext( &fileName );
					continue;
				}
				if ( AddFile( dirEntry, dirPath, fileName, parent ) ) {
					++entryNumber;
				}
			} else {
				// if possible filter added directories by game serial
				// this has the effective result of only files relevant to the current game being loaded into the memory card
				// which means every game essentially sees the memory card as if no other files exist
				if ( enableFiltering && !FilterMatches( fileName, localFilter ) ) {
					hasNext = dir.GetNext( &fileName );
					continue;
				}

				// make sure we have enough space on the memcard for the directory
				const u32 newNeededClusters = CalculateRequiredClustersOfDirectory( dirPath + L"/" + fileName ) + ( ( dirEntry->entry.data.length % 2 ) == 0 ? 1 : 0 );
				if ( newNeededClusters > GetAmountFreeDataClusters() ) {
					Console.Warning( GetCardFullMessage( fileName ) );
					hasNext = dir.GetNext( &fileName );
					continue;
				}

				// is a subdirectory
				wxDateTime creationTime, modificationTime;
				fileInfo.AppendDir( fileInfo.GetFullName() );
				fileInfo.SetName( L"" );
				fileInfo.ClearExt();
				fileInfo.GetTimes( NULL, &modificationTime, &creationTime );

				// add entry for subdir in parent dir
				MemoryCardFileEntry* newDirEntry = AppendFileEntryToDir( dirEntry );
				dirEntry->entry.data.length++;

				// set metadata
				wxFileName metaFileName( dirPath, L"_pcsx2_meta_directory" );
				metaFileName.AppendDir( fileName );
				wxFFile metaFile;
				if ( metaFileName.FileExists() && metaFile.Open( metaFileName.GetFullPath(), L"rb" ) ) {
					size_t bytesRead = metaFile.Read( &newDirEntry->entry.raw, sizeof( newDirEntry->entry.raw ) );
					metaFile.Close();
					if ( bytesRead < 0x60 ) {
						strcpy( (char*)&newDirEntry->entry.data.name[0], fileName.mbc_str() );
					}
				} else {
					newDirEntry->entry.data.mode = MemoryCardFileEntry::DefaultDirMode;
					newDirEntry->entry.data.timeCreated = MemoryCardFileEntryDateTime::FromWxDateTime( creationTime );
					newDirEntry->entry.data.timeModified = MemoryCardFileEntryDateTime::FromWxDateTime( modificationTime );
					strcpy( (char*)&newDirEntry->entry.data.name[0], fileName.mbc_str() );
				}

				// create new cluster for . and .. entries
				newDirEntry->entry.data.length = 2;
				u32 newCluster = GetFreeDataCluster();
				m_fat.data[0][0][newCluster] = LastDataCluster | DataClusterInUseMask;
				newDirEntry->entry.data.cluster = newCluster;

				MemoryCardFileEntryCluster* const subDirCluster = &m_fileEntryDict[newCluster];
				memset( &subDirCluster->entries[0].entry.raw[0], 0x00, sizeof( subDirCluster->entries[0].entry.raw ) );
				subDirCluster->entries[0].entry.data.mode = MemoryCardFileEntry::DefaultDirMode;
				subDirCluster->entries[0].entry.data.dirEntry = entryNumber;
				subDirCluster->entries[0].entry.data.name[0] = '.';

				memset( &subDirCluster->entries[1].entry.raw[0], 0x00, sizeof( subDirCluster->entries[1].entry.raw ) );
				subDirCluster->entries[1].entry.data.mode = MemoryCardFileEntry::DefaultDirMode;
				subDirCluster->entries[1].entry.data.name[0] = '.';
				subDirCluster->entries[1].entry.data.name[1] = '.';

				MemoryCardFileMetadataReference* dirRef = AddDirEntryToMetadataQuickAccess( newDirEntry, parent );

				++entryNumber;

				// and add all files in subdir
				AddFolder( newDirEntry, fileInfo.GetFullPath(), dirRef );
			}

			hasNext = dir.GetNext( &fileName );
		}

		return true;
	}

	return false;
}

bool FolderMemoryCard::AddFile( MemoryCardFileEntry* const dirEntry, const wxString& dirPath, const wxString& fileName, MemoryCardFileMetadataReference* parent ) {
	wxFileName relativeFilePath( dirPath, fileName );
	relativeFilePath.MakeRelativeTo( m_folderName.GetPath() );

	wxFileName fileInfo( dirPath, fileName );
	wxFFile file( fileInfo.GetFullPath(), L"rb" );
	if ( file.IsOpened() ) {
		// make sure we have enough space on the memcard to hold the data
		const u32 clusterSize = m_superBlock.data.pages_per_cluster * m_superBlock.data.page_len;
		const u32 filesize = file.Length();
		const u32 countClusters = ( filesize % clusterSize ) != 0 ? ( filesize / clusterSize + 1 ) : ( filesize / clusterSize );
		const u32 newNeededClusters = ( dirEntry->entry.data.length % 2 ) == 0 ? countClusters + 1 : countClusters;
		if ( newNeededClusters > GetAmountFreeDataClusters() ) {
			Console.Warning( GetCardFullMessage( relativeFilePath.GetFullPath() ) );
			file.Close();
			return false;
		}

		MemoryCardFileEntry* newFileEntry = AppendFileEntryToDir( dirEntry );
		wxDateTime creationTime, modificationTime;
		fileInfo.GetTimes( NULL, &modificationTime, &creationTime );

		// set file entry metadata
		memset( &newFileEntry->entry.raw[0], 0x00, sizeof( newFileEntry->entry.raw ) );

		wxFileName metaFileName( dirPath, fileName );
		metaFileName.AppendDir( L"_pcsx2_meta" );
		wxFFile metaFile;
		if ( metaFileName.FileExists() && metaFile.Open( metaFileName.GetFullPath(), L"rb" ) ) {
			size_t bytesRead = metaFile.Read( &newFileEntry->entry.raw, sizeof( newFileEntry->entry.raw ) );
			metaFile.Close();
			if ( bytesRead < 0x60 ) {
				strcpy( (char*)&newFileEntry->entry.data.name[0], fileName.mbc_str() );
			}
		} else {
			newFileEntry->entry.data.mode = MemoryCardFileEntry::DefaultFileMode;
			newFileEntry->entry.data.timeCreated = MemoryCardFileEntryDateTime::FromWxDateTime( creationTime );
			newFileEntry->entry.data.timeModified = MemoryCardFileEntryDateTime::FromWxDateTime( modificationTime );
			strcpy( (char*)&newFileEntry->entry.data.name[0], fileName.mbc_str() );
		}

		newFileEntry->entry.data.length = filesize;
		if ( filesize != 0 ) {
			u32 fileDataStartingCluster = GetFreeDataCluster();
			newFileEntry->entry.data.cluster = fileDataStartingCluster;

			// mark the appropriate amount of clusters as used
			u32 dataCluster = fileDataStartingCluster;
			m_fat.data[0][0][dataCluster] = LastDataCluster | DataClusterInUseMask;
			for ( unsigned int i = 0; i < countClusters - 1; ++i ) {
				u32 newCluster = GetFreeDataCluster();
				m_fat.data[0][0][dataCluster] = newCluster | DataClusterInUseMask;
				m_fat.data[0][0][newCluster] = LastDataCluster | DataClusterInUseMask;
				dataCluster = newCluster;
			}
		} else {
			newFileEntry->entry.data.cluster = MemoryCardFileEntry::EmptyFileCluster;
		}

		file.Close();

		MemoryCardFileMetadataReference* fileRef = AddFileEntryToMetadataQuickAccess( newFileEntry, parent );
		if ( fileRef != nullptr ) {
			// acquire a handle on the file so nothing else can change the file contents while the memory card is open
			m_lastAccessedFile.ReOpen( m_folderName, fileRef );
		}

		// and finally, increase file count in the directory entry
		dirEntry->entry.data.length++;

		return true;
	} else {
		Console.WriteLn( L"(FolderMcd) Could not open file: %s", WX_STR( relativeFilePath.GetFullPath() ) );
		return false;
	}
}

u32 FolderMemoryCard::CalculateRequiredClustersOfDirectory( const wxString& dirPath ) const {
	const u32 clusterSize = m_superBlock.data.pages_per_cluster * m_superBlock.data.page_len;
	u32 requiredFileEntryPages = 2;
	u32 requiredClusters = 0;

	wxDir dir( dirPath );
	wxString fileName;
	bool hasNext = dir.GetFirst( &fileName );
	while ( hasNext ) {
		if ( fileName.StartsWith( L"_pcsx2_" ) ) {
			hasNext = dir.GetNext( &fileName );
			continue;
		}

		++requiredFileEntryPages;
		wxFileName file( dirPath, fileName );
		wxString path = file.GetFullPath();
		bool isFile = wxFile::Exists( path );

		if ( isFile ) {
			const u32 filesize = file.GetSize().GetValue();
			const u32 countClusters = ( filesize % clusterSize ) != 0 ? ( filesize / clusterSize + 1 ) : ( filesize / clusterSize );
			requiredClusters += countClusters;
		} else {
			requiredClusters += CalculateRequiredClustersOfDirectory( path );
		}

		hasNext = dir.GetNext( &fileName );
	}

	return requiredClusters + requiredFileEntryPages / 2 + ( requiredFileEntryPages % 2 == 0 ? 0 : 1 );
}

MemoryCardFileMetadataReference* FolderMemoryCard::AddDirEntryToMetadataQuickAccess( MemoryCardFileEntry* const entry, MemoryCardFileMetadataReference* const parent ) {
	MemoryCardFileMetadataReference* ref = &m_fileMetadataQuickAccess[entry->entry.data.cluster];
	ref->parent = parent;
	ref->entry = entry;
	ref->consecutiveCluster = 0xFFFFFFFFu;
	return ref;
}

MemoryCardFileMetadataReference* FolderMemoryCard::AddFileEntryToMetadataQuickAccess( MemoryCardFileEntry* const entry, MemoryCardFileMetadataReference* const parent ) {
	const u32 firstFileCluster = entry->entry.data.cluster;
	u32 fileCluster = firstFileCluster;

	// zero-length files have no file clusters
	if ( fileCluster == 0xFFFFFFFFu ) {
		return nullptr;
	}

	u32 clusterNumber = 0;
	do {
		MemoryCardFileMetadataReference* ref = &m_fileMetadataQuickAccess[fileCluster & NextDataClusterMask];
		ref->parent = parent;
		ref->entry = entry;
		ref->consecutiveCluster = clusterNumber;
		++clusterNumber;
	} while ( ( fileCluster = m_fat.data[0][0][fileCluster & NextDataClusterMask]) != ( LastDataCluster | DataClusterInUseMask ) );

	return &m_fileMetadataQuickAccess[firstFileCluster & NextDataClusterMask];
}

s32 FolderMemoryCard::IsPresent() const {
	return m_isEnabled;
}

void FolderMemoryCard::GetSizeInfo( PS2E_McdSizeInfo& outways ) const {
	outways.SectorSize = PageSize;
	outways.EraseBlockSizeInSectors = BlockSize / PageSize;
	outways.McdSizeInSectors = GetSizeInClusters() * 2;

	u8 *pdata = (u8*)&outways.McdSizeInSectors;
	outways.Xor = 18;
	outways.Xor ^= pdata[0] ^ pdata[1] ^ pdata[2] ^ pdata[3];
}

bool FolderMemoryCard::IsPSX() const {
	return false;
}

u8* FolderMemoryCard::GetSystemBlockPointer( const u32 adr ) {
	const u32 block = adr / BlockSizeRaw;
	const u32 page = adr / PageSizeRaw;
	const u32 offset = adr % PageSizeRaw;
	const u32 cluster = adr / ClusterSizeRaw;

	const u32 startDataCluster = m_superBlock.data.alloc_offset;
	const u32 endDataCluster = startDataCluster + m_superBlock.data.alloc_end;
	if ( cluster >= startDataCluster && cluster < endDataCluster ) {
		// trying to access a file entry?
		const u32 fatCluster = cluster - m_superBlock.data.alloc_offset;
		// if this cluster is unused according to FAT, we can assume we won't find anything
		if ( ( m_fat.data[0][0][fatCluster] & DataClusterInUseMask ) == 0 ) {
			return nullptr;
		}
		return GetFileEntryPointer( fatCluster, page % 2, offset );
	}

	if ( block == 0 ) {
		return &m_superBlock.raw[page * PageSize + offset];
	} else if ( block == m_superBlock.data.backup_block1 ) {
		return &m_backupBlock1[( page % 16 ) * PageSize + offset];
	} else if ( block == m_superBlock.data.backup_block2 ) {
		return &m_backupBlock2.raw[( page % 16 ) * PageSize + offset];
	} else {
		// trying to access indirect FAT?
		for ( int i = 0; i < IndirectFatClusterCount; ++i ) {
			if ( cluster == m_superBlock.data.ifc_list[i] ) {
				return &m_indirectFat.raw[i][( page % 2 ) * PageSize + offset];
			}
		}
		// trying to access FAT?
		for ( int i = 0; i < IndirectFatClusterCount; ++i ) {
			for ( int j = 0; j < ClusterSize / 4; ++j ) {
				const u32 fatCluster = m_indirectFat.data[i][j];
				if ( fatCluster != IndirectFatUnused && fatCluster == cluster ) {
					return &m_fat.raw[i][j][( page % 2 ) * PageSize + offset];
				}
			}
		}
	}

	return nullptr;
}

u8* FolderMemoryCard::GetFileEntryPointer( const u32 searchCluster, const u32 entryNumber, const u32 offset ) {
	const u32 fileCount = m_fileEntryDict[m_superBlock.data.rootdir_cluster].entries[0].entry.data.length;
	MemoryCardFileEntryCluster* ptr = GetFileEntryCluster( m_superBlock.data.rootdir_cluster, searchCluster, fileCount );
	if ( ptr != nullptr ) {
		return &ptr->entries[entryNumber].entry.raw[offset];
	}

	return nullptr;
}

MemoryCardFileEntryCluster* FolderMemoryCard::GetFileEntryCluster( const u32 currentCluster, const u32 searchCluster, const u32 fileCount ) {
	// we found the correct cluster, return pointer to it
	if ( currentCluster == searchCluster ) {
		return &m_fileEntryDict[currentCluster];
	}

	// check other clusters of this directory
	const u32 nextCluster = m_fat.data[0][0][currentCluster] & NextDataClusterMask;
	if ( nextCluster != LastDataCluster ) {
		MemoryCardFileEntryCluster* ptr = GetFileEntryCluster( nextCluster, searchCluster, fileCount - 2 );
		if ( ptr != nullptr ) { return ptr; }
	}

	// check subdirectories
	auto it = m_fileEntryDict.find( currentCluster );
	if ( it != m_fileEntryDict.end() ) {
		const u32 filesInThisCluster = std::min( fileCount, 2u );
		for ( unsigned int i = 0; i < filesInThisCluster; ++i ) {
			const MemoryCardFileEntry* const entry = &it->second.entries[i];
			if ( entry->IsValid() && entry->IsUsed() && entry->IsDir() && !entry->IsDotDir() ) {
				const u32 newFileCount = entry->entry.data.length;
				MemoryCardFileEntryCluster* ptr = GetFileEntryCluster( entry->entry.data.cluster, searchCluster, newFileCount );
				if ( ptr != nullptr ) { return ptr; }
			}
		}
	}

	return nullptr;
}

// This method is actually unused since the introduction of m_fileMetadataQuickAccess.
// I'll leave it here anyway though to show how you traverse the file system.
MemoryCardFileEntry* FolderMemoryCard::GetFileEntryFromFileDataCluster( const u32 currentCluster, const u32 searchCluster, wxFileName* fileName, const size_t originalDirCount, u32* outClusterNumber ) {
	// check both entries of the current cluster if they're the file we're searching for, and if yes return it
	for ( int i = 0; i < 2; ++i ) {
		MemoryCardFileEntry* const entry = &m_fileEntryDict[currentCluster].entries[i];
		if ( entry->IsValid() && entry->IsUsed() && entry->IsFile() ) {
			u32 fileCluster = entry->entry.data.cluster;
			u32 clusterNumber = 0;
			do {
				if ( fileCluster == searchCluster ) {
					fileName->SetName( wxString::FromAscii( (const char*)entry->entry.data.name ) );
					*outClusterNumber = clusterNumber;
					return entry;
				}
				++clusterNumber;
			} while ( ( fileCluster = m_fat.data[0][0][fileCluster] & NextDataClusterMask ) != LastDataCluster );
		}
	}

	// check other clusters of this directory
	// this can probably be solved more efficiently by looping through nextClusters instead of recursively calling
	const u32 nextCluster = m_fat.data[0][0][currentCluster] & NextDataClusterMask;
	if ( nextCluster != LastDataCluster ) {
		MemoryCardFileEntry* ptr = GetFileEntryFromFileDataCluster( nextCluster, searchCluster, fileName, originalDirCount, outClusterNumber );
		if ( ptr != nullptr ) { return ptr; }
	}

	// check subdirectories
	for ( int i = 0; i < 2; ++i ) {
		MemoryCardFileEntry* const entry = &m_fileEntryDict[currentCluster].entries[i];
		if ( entry->IsValid() && entry->IsUsed() && entry->IsDir() && !entry->IsDotDir() ) {
			MemoryCardFileEntry* ptr = GetFileEntryFromFileDataCluster( entry->entry.data.cluster, searchCluster, fileName, originalDirCount, outClusterNumber );
			if ( ptr != nullptr ) {
				fileName->InsertDir( originalDirCount, wxString::FromAscii( (const char*)entry->entry.data.name ) );
				return ptr;
			}
		}
	}

	return nullptr;
}

bool FolderMemoryCard::ReadFromFile( u8 *dest, u32 adr, u32 dataLength ) {
	const u32 page = adr / PageSizeRaw;
	const u32 offset = adr % PageSizeRaw;
	const u32 cluster = adr / ClusterSizeRaw;
	const u32 fatCluster = cluster - m_superBlock.data.alloc_offset;

	// if the cluster is unused according to FAT, just return
	if ( ( m_fat.data[0][0][fatCluster] & DataClusterInUseMask ) == 0 ) {
		return false;
	}

	// figure out which file to read from
	auto it = m_fileMetadataQuickAccess.find( fatCluster );
	if ( it != m_fileMetadataQuickAccess.end() ) {
		const u32 clusterNumber = it->second.consecutiveCluster;
		wxFFile* file = m_lastAccessedFile.ReOpen( m_folderName, &it->second );
		if ( file->IsOpened() ) {
			const u32 clusterOffset = ( page % 2 ) * PageSize + offset;
			const u32 fileOffset = clusterNumber * ClusterSize + clusterOffset;

			if ( fileOffset != file->Tell() ) {
				file->Seek( fileOffset );
			}
			size_t bytesRead = file->Read( dest, dataLength );

			// if more bytes were requested than actually exist, fill the rest with 0xFF
			if ( bytesRead < dataLength ) {
				memset( &dest[bytesRead], 0xFF, dataLength - bytesRead );
			}

			return bytesRead > 0;
		}
	}

	return false;
}

s32 FolderMemoryCard::Read( u8 *dest, u32 adr, int size ) {
	//const u32 block = adr / BlockSizeRaw;
	const u32 page = adr / PageSizeRaw;
	const u32 offset = adr % PageSizeRaw;
	//const u32 cluster = adr / ClusterSizeRaw;
	const u32 end = offset + size;

	if ( end > PageSizeRaw ) {
		// is trying to read more than one page at a time
		// do this recursively so that each function call only has to care about one page
		const u32 toNextPage = PageSizeRaw - offset;
		Read( dest + toNextPage, adr + toNextPage, size - toNextPage );
		size = toNextPage;
	}

	if ( offset < PageSize ) {
		// is trying to read (part of) an actual data block
		const u32 dataLength = std::min( (u32)size, (u32)( PageSize - offset ) );

		// if we have a cache for this page, just load from that
		auto it = m_cache.find( page );
		if ( it != m_cache.end() ) {
			memcpy( dest, &it->second.raw[offset], dataLength );
		} else {
			ReadDataWithoutCache( dest, adr, dataLength );
		}
	}

	if ( end > PageSize ) {
		// is trying to (partially) read the ECC
		const u32 eccOffset = PageSize - offset;
		const u32 eccLength = std::min( (u32)( size - offset ), (u32)EccSize );
		const u32 adrStart = page * PageSizeRaw;

		u8 data[PageSize];
		Read( data, adrStart, PageSize );

		u8 ecc[EccSize];
		memset( ecc, 0xFF, EccSize );

		for ( int i = 0; i < PageSize / 0x80; ++i ) {
			FolderMemoryCard::CalculateECC( ecc + ( i * 3 ), &data[i * 0x80] );
		}

		memcpy( dest + eccOffset, ecc, eccLength );
	}

	SetTimeLastReadToNow();

	// return 0 on fail, 1 on success?
	return 1;
}

void FolderMemoryCard::ReadDataWithoutCache( u8* const dest, const u32 adr, const u32 dataLength ) {
	u8* src = GetSystemBlockPointer( adr );
	if ( src != nullptr ) {
		memcpy( dest, src, dataLength );
	} else {
		if ( !ReadFromFile( dest, adr, dataLength ) ) {
			memset( dest, 0xFF, dataLength );
		}
	}
}

s32 FolderMemoryCard::Save( const u8 *src, u32 adr, int size ) {
	//const u32 block = adr / BlockSizeRaw;
	//const u32 cluster = adr / ClusterSizeRaw;
	const u32 page = adr / PageSizeRaw;
	const u32 offset = adr % PageSizeRaw;
	const u32 end = offset + size;

	if ( end > PageSizeRaw ) {
		// is trying to store more than one page at a time
		// do this recursively so that each function call only has to care about one page
		const u32 toNextPage = PageSizeRaw - offset;
		Save( src + toNextPage, adr + toNextPage, size - toNextPage );
		size = toNextPage;
	}

	if ( offset < PageSize ) {
		// is trying to store (part of) an actual data block
		const u32 dataLength = std::min( (u32)size, PageSize - offset );

		// if cache page has not yet been touched, fill it with the data from our memory card
		auto it = m_cache.find( page );
		MemoryCardPage* cachePage;
		if ( it == m_cache.end() ) {
			cachePage = &m_cache[page];
			const u32 adrLoad = page * PageSizeRaw;
			ReadDataWithoutCache( &cachePage->raw[0], adrLoad, PageSize );
			memcpy( &m_oldDataCache[page].raw[0], &cachePage->raw[0], PageSize );
		} else {
			cachePage = &it->second;
		}

		// then just write to the cache
		memcpy( &cachePage->raw[offset], src, dataLength );

		SetTimeLastWrittenToNow();
	}

	return 1;
}

void FolderMemoryCard::NextFrame() {
	if ( m_framesUntilFlush > 0 && --m_framesUntilFlush == 0 ) {
		Flush();
	}
}

void FolderMemoryCard::Flush() {
	if ( m_cache.empty() ) { return; }

	#ifdef DEBUG_WRITE_FOLDER_CARD_IN_MEMORY_TO_FILE_ON_CHANGE
	WriteToFile( m_folderName.GetFullPath().RemoveLast() + L"-debug_" + wxDateTime::Now().Format( L"%Y-%m-%d-%H-%M-%S" ) + L"_pre-flush.ps2" );
	#endif

	Console.WriteLn( L"(FolderMcd) Writing data for slot %u to file system...", m_slot );
	const u64 timeFlushStart = wxGetLocalTimeMillis().GetValue();

	// Keep a copy of the old file entries so we can figure out which files and directories, if any, have been deleted from the memory card.
	std::vector<MemoryCardFileEntryTreeNode> oldFileEntryTree;
	if ( IsFormatted() ) {
		CopyEntryDictIntoTree( &oldFileEntryTree, m_superBlock.data.rootdir_cluster, m_fileEntryDict[m_superBlock.data.rootdir_cluster].entries[0].entry.data.length );
	}

	// first write the superblock if necessary
	FlushSuperBlock();
	if ( !IsFormatted() ) { return; }

	// check if we were interrupted in the middle of a save operation, if yes abort
	FlushBlock( m_superBlock.data.backup_block1 );
	FlushBlock( m_superBlock.data.backup_block2 );
	if ( m_backupBlock2.programmedBlock != 0xFFFFFFFFu ) {
		Console.Warning( L"(FolderMcd) Aborting flush of slot %u, emulation was interrupted during save process!", m_slot );
		return;
	}

	const u32 clusterCount = GetSizeInClusters();
	const u32 pageCount = clusterCount * 2;

	// then write the indirect FAT
	for ( int i = 0; i < IndirectFatClusterCount; ++i ) {
		const u32 cluster = m_superBlock.data.ifc_list[i];
		if ( cluster > 0 && cluster < clusterCount ) {
			FlushCluster( cluster );
		}
	}

	// and the FAT
	for ( int i = 0; i < IndirectFatClusterCount; ++i ) {
		for ( int j = 0; j < ClusterSize / 4; ++j ) {
			const u32 cluster = m_indirectFat.data[i][j];
			if ( cluster > 0 && cluster < clusterCount ) {
				FlushCluster( cluster );
			}
		}
	}

	// then all directory and file entries
	FlushFileEntries();

	// Now we have the new file system, compare it to the old one and "delete" any files that were in it before but aren't anymore.
	FlushDeletedFilesAndRemoveUnchangedDataFromCache( oldFileEntryTree );

	// and finally, flush everything that hasn't been flushed yet
	for ( uint i = 0; i < pageCount; ++i ) {
		FlushPage( i );
	}

	m_lastAccessedFile.FlushAll();
	m_lastAccessedFile.ClearMetadataWriteState();
	m_oldDataCache.clear();

	const u64 timeFlushEnd = wxGetLocalTimeMillis().GetValue();
	Console.WriteLn( L"(FolderMcd) Done! Took %u ms.", timeFlushEnd - timeFlushStart );

	#ifdef DEBUG_WRITE_FOLDER_CARD_IN_MEMORY_TO_FILE_ON_CHANGE
	WriteToFile( m_folderName.GetFullPath().RemoveLast() + L"-debug_" + wxDateTime::Now().Format( L"%Y-%m-%d-%H-%M-%S" ) + L"_post-flush.ps2" );
	#endif
}

bool FolderMemoryCard::FlushPage( const u32 page ) {
	auto it = m_cache.find( page );
	if ( it != m_cache.end() ) {
		WriteWithoutCache( &it->second.raw[0], page * PageSizeRaw, PageSize );
		m_cache.erase( it );
		return true;
	}
	return false;
}

bool FolderMemoryCard::FlushCluster( const u32 cluster ) {
	const u32 page = cluster * 2;
	bool flushed = false;
	if ( FlushPage( page ) ) { flushed = true; }
	if ( FlushPage( page + 1 ) ) { flushed = true; }
	return flushed;
}

bool FolderMemoryCard::FlushBlock( const u32 block ) {
	const u32 page = block * 16;
	bool flushed = false;
	for ( int i = 0; i < 16; ++i ) {
		if ( FlushPage( page + i ) ) { flushed = true; }
	}
	return flushed;
}

void FolderMemoryCard::FlushSuperBlock() {
	if ( FlushBlock( 0 ) && m_performFileWrites ) {
		wxFileName superBlockFileName( m_folderName.GetPath(), L"_pcsx2_superblock" );
		wxFFile superBlockFile( superBlockFileName.GetFullPath().c_str(), L"wb" );
		if ( superBlockFile.IsOpened() ) {
			superBlockFile.Write( &m_superBlock.raw, sizeof( m_superBlock.raw ) );
		}
	}
}

void FolderMemoryCard::FlushFileEntries() {
	// Flush all file entry data from the cache into m_fileEntryDict.
	const u32 rootDirCluster = m_superBlock.data.rootdir_cluster;
	FlushCluster( rootDirCluster + m_superBlock.data.alloc_offset );
	MemoryCardFileEntryCluster* rootEntries = &m_fileEntryDict[rootDirCluster];
	if ( rootEntries->entries[0].IsValid() && rootEntries->entries[0].IsUsed() ) {
		FlushFileEntries( rootDirCluster, rootEntries->entries[0].entry.data.length );
	}
}

void FolderMemoryCard::FlushFileEntries( const u32 dirCluster, const u32 remainingFiles, const wxString& dirPath, MemoryCardFileMetadataReference* parent ) {
	// flush the current cluster
	FlushCluster( dirCluster + m_superBlock.data.alloc_offset );

	// if either of the current entries is a subdir, flush that too
	MemoryCardFileEntryCluster* entries = &m_fileEntryDict[dirCluster];
	const u32 filesInThisCluster = std::min( remainingFiles, 2u );
	for ( unsigned int i = 0; i < filesInThisCluster; ++i ) {
		MemoryCardFileEntry* entry = &entries->entries[i];
		if ( entry->IsValid() && entry->IsUsed() && entry->IsDir() ) {
			if ( !entry->IsDotDir() ) {
				char cleanName[sizeof( entry->entry.data.name )];
				memcpy( cleanName, (const char*)entry->entry.data.name, sizeof( cleanName ) );
				bool filenameCleaned = FileAccessHelper::CleanMemcardFilename( cleanName );
				const wxString subDirName = wxString::FromAscii( (const char*)cleanName );
				const wxString subDirPath = dirPath + L"/" + subDirName;

				if ( m_performFileWrites ) {
					// if this directory has nonstandard metadata, write that to the file system
					wxFileName metaFileName( m_folderName.GetFullPath() + subDirPath + L"/_pcsx2_meta_directory" );
					if ( filenameCleaned || entry->entry.data.mode != MemoryCardFileEntry::DefaultDirMode || entry->entry.data.attr != 0 ) {
						if ( !metaFileName.DirExists() ) {
							metaFileName.Mkdir();
						}
						wxFFile metaFile( metaFileName.GetFullPath(), L"wb" );
						if ( metaFile.IsOpened() ) {
							metaFile.Write( entry->entry.raw, sizeof( entry->entry.raw ) );
							metaFile.Close();
						}
					} else {
						// if metadata is standard make sure to remove a possibly existing metadata file
						if ( metaFileName.FileExists() ) {
							wxRemoveFile( metaFileName.GetFullPath() );
						}
					}
				}

				MemoryCardFileMetadataReference* dirRef = AddDirEntryToMetadataQuickAccess( entry, parent );

				FlushFileEntries( entry->entry.data.cluster, entry->entry.data.length, subDirPath, dirRef );
			}
		} else if ( entry->IsValid() && entry->IsUsed() && entry->IsFile() ) {
			AddFileEntryToMetadataQuickAccess( entry, parent );
			if ( entry->entry.data.length == 0 ) {
				// empty files need to be explicitly created, as there will be no data cluster referencing it later
				char cleanName[sizeof( entry->entry.data.name )];
				memcpy( cleanName, (const char*)entry->entry.data.name, sizeof( cleanName ) );
				FileAccessHelper::CleanMemcardFilename( cleanName );
				const wxString filePath = dirPath + L"/" + wxString::FromAscii( (const char*)cleanName );

				if ( m_performFileWrites ) {
					wxFileName fn( m_folderName.GetFullPath() + filePath );
					if ( !fn.FileExists() ) {
						if ( !fn.DirExists() ) {
							fn.Mkdir( 0777, wxPATH_MKDIR_FULL );
						}
						wxFFile createEmptyFile( fn.GetFullPath(), L"wb" );
						createEmptyFile.Close();
					}
				}
			}
		}
	}

	// continue to the next cluster of this directory
	const u32 nextCluster = m_fat.data[0][0][dirCluster];
	if ( nextCluster != ( LastDataCluster | DataClusterInUseMask ) ) {
		FlushFileEntries( nextCluster & NextDataClusterMask, remainingFiles - 2, dirPath, parent );
	}
}

void FolderMemoryCard::FlushDeletedFilesAndRemoveUnchangedDataFromCache( const std::vector<MemoryCardFileEntryTreeNode>& oldFileEntries ) {
	const u32 newRootDirCluster = m_superBlock.data.rootdir_cluster;
	const u32 newFileCount = m_fileEntryDict[newRootDirCluster].entries[0].entry.data.length;
	wxString path = L"";
	FlushDeletedFilesAndRemoveUnchangedDataFromCache( oldFileEntries, newRootDirCluster, newFileCount, path );
}

void FolderMemoryCard::FlushDeletedFilesAndRemoveUnchangedDataFromCache( const std::vector<MemoryCardFileEntryTreeNode>& oldFileEntries, const u32 newCluster, const u32 newFileCount, const wxString& dirPath ) {
	// go through all file entires of the current directory of the old data
	for ( auto it = oldFileEntries.cbegin(); it != oldFileEntries.cend(); ++it ) {
		const MemoryCardFileEntry* entry = &it->entry;
		if ( entry->IsValid() && entry->IsUsed() && !entry->IsDotDir() ) {
			// check if an equivalent entry exists in m_fileEntryDict
			const MemoryCardFileEntry* newEntry = FindEquivalent( entry, newCluster, newFileCount );
			if ( newEntry == nullptr ) {
				// file/dir doesn't exist anymore, remove!
				char cleanName[sizeof( entry->entry.data.name )];
				memcpy( cleanName, (const char*)entry->entry.data.name, sizeof( cleanName ) );
				FileAccessHelper::CleanMemcardFilename( cleanName );
				const wxString fileName = wxString::FromAscii( cleanName );
				const wxString filePath = m_folderName.GetFullPath() + dirPath + L"/" + fileName;
				m_lastAccessedFile.CloseMatching( filePath );
				const wxString newFilePath = m_folderName.GetFullPath() + dirPath + L"/_pcsx2_deleted_" + fileName;
				if ( wxFileName::DirExists( newFilePath ) ) {
					// wxRenameFile doesn't overwrite directories, so we have to remove the old one first
					RemoveDirectory( newFilePath );
				}
				wxRenameFile( filePath, newFilePath );
			} else if ( entry->IsDir() ) {
				// still exists and is a directory, recursive call for subdir
				char cleanName[sizeof( entry->entry.data.name )];
				memcpy( cleanName, (const char*)entry->entry.data.name, sizeof( cleanName ) );
				FileAccessHelper::CleanMemcardFilename( cleanName );
				const wxString subDirName = wxString::FromAscii( cleanName );
				const wxString subDirPath = dirPath + L"/" + subDirName;
				FlushDeletedFilesAndRemoveUnchangedDataFromCache( it->subdir, newEntry->entry.data.cluster, newEntry->entry.data.length, subDirPath );
			} else if ( entry->IsFile() ) {
				// still exists and is a file, see if we can remove unchanged data from m_cache
				RemoveUnchangedDataFromCache( entry, newEntry );
			}
		}
	}
}

void FolderMemoryCard::RemoveUnchangedDataFromCache( const MemoryCardFileEntry* const oldEntry, const MemoryCardFileEntry* const newEntry ) {
	// Disclaimer: Technically, to actually prove that file data has not changed and still belongs to the same file, we'd need to keep a copy
	// of the old FAT cluster chain and compare that as well, and only acknowledge the file as unchanged if none of those have changed. However,
	// the chain of events that leads to a file having the exact same file contents as a deleted old file while also being placed in the same
	// data clusters as the deleted file AND matching this condition here, in a quick enough succession that no flush has occurred yet since the
	// deletion of that old file is incredibly unlikely, so I'm not sure if it's actually worth coding for.
	if ( oldEntry->entry.data.timeModified != newEntry->entry.data.timeModified || oldEntry->entry.data.timeCreated != newEntry->entry.data.timeCreated
	  || oldEntry->entry.data.length != newEntry->entry.data.length || oldEntry->entry.data.cluster != newEntry->entry.data.cluster ) {
		return;
	}

	u32 cluster = newEntry->entry.data.cluster & NextDataClusterMask;
	const u32 alloc_offset = m_superBlock.data.alloc_offset;
	while ( cluster != LastDataCluster ) {
		for ( int i = 0; i < 2; ++i ) {
			const u32 page = ( cluster + alloc_offset ) * 2 + i;
			auto newIt = m_cache.find( page );
			if ( newIt == m_cache.end() ) { continue; }
			auto oldIt = m_oldDataCache.find( page );
			if ( oldIt == m_oldDataCache.end() ) { continue; }

			if ( memcmp( &oldIt->second.raw[0], &newIt->second.raw[0], PageSize ) == 0 ) {
				m_cache.erase( newIt );
			}
		}

		cluster = m_fat.data[0][0][cluster] & NextDataClusterMask;
	}
}

s32 FolderMemoryCard::WriteWithoutCache( const u8 *src, u32 adr, int size ) {
	//const u32 block = adr / BlockSizeRaw;
	//const u32 cluster = adr / ClusterSizeRaw;
	//const u32 page = adr / PageSizeRaw;
	const u32 offset = adr % PageSizeRaw;
	const u32 end = offset + size;

	if ( end > PageSizeRaw ) {
		// is trying to store more than one page at a time
		// do this recursively so that each function call only has to care about one page
		const u32 toNextPage = PageSizeRaw - offset;
		Save( src + toNextPage, adr + toNextPage, size - toNextPage );
		size = toNextPage;
	}

	if ( offset < PageSize ) {
		// is trying to store (part of) an actual data block
		const u32 dataLength = std::min( (u32)size, PageSize - offset );

		u8* dest = GetSystemBlockPointer( adr );
		if ( dest != nullptr ) {
			memcpy( dest, src, dataLength );
		} else {
			WriteToFile( src, adr, dataLength );
		}
	}

	if ( end > PageSize ) {
		// is trying to store ECC
		// simply ignore this, is automatically generated when reading
	}

	// return 0 on fail, 1 on success?
	return 1;
}

bool FolderMemoryCard::WriteToFile( const u8* src, u32 adr, u32 dataLength ) {
	const u32 cluster = adr / ClusterSizeRaw;
	const u32 page = adr / PageSizeRaw;
	const u32 offset = adr % PageSizeRaw;
	const u32 fatCluster = cluster - m_superBlock.data.alloc_offset;

	// if the cluster is unused according to FAT, just skip all this, we're not gonna find anything anyway
	if ( ( m_fat.data[0][0][fatCluster] & DataClusterInUseMask ) == 0 ) {
		return false;
	}

	// figure out which file to write to
	auto it = m_fileMetadataQuickAccess.find( fatCluster );
	if ( it != m_fileMetadataQuickAccess.end() ) {
		const MemoryCardFileEntry* const entry = it->second.entry;
		const u32 clusterNumber = it->second.consecutiveCluster;
		
		if ( m_performFileWrites ) {
			wxFFile* file = m_lastAccessedFile.ReOpen( m_folderName, &it->second, true );
			if ( file->IsOpened() ) {
				const u32 clusterOffset = ( page % 2 ) * PageSize + offset;
				const u32 fileSize = entry->entry.data.length;
				const u32 fileOffsetStart = std::min( clusterNumber * ClusterSize + clusterOffset, fileSize );
				const u32 fileOffsetEnd = std::min( fileOffsetStart + dataLength, fileSize );
				const u32 bytesToWrite = fileOffsetEnd - fileOffsetStart;

				wxFileOffset actualFileSize = file->Length();
				if ( actualFileSize < fileOffsetStart ) {
					file->Seek( actualFileSize );
					const u32 diff = fileOffsetStart - actualFileSize;
					u8 temp = 0xFF;
					for ( u32 i = 0; i < diff; ++i ) {
						file->Write( &temp, 1 );
					}
				}

				const wxFileOffset fileOffset = file->Tell();
				if ( fileOffset != fileOffsetStart ) {
					file->Seek( fileOffsetStart );
				}
				if ( bytesToWrite > 0 ) {
					file->Write( src, bytesToWrite );
				}
			} else {
				return false;
			}
		}

		return true;
	}

	return false;
}

void FolderMemoryCard::CopyEntryDictIntoTree( std::vector<MemoryCardFileEntryTreeNode>* fileEntryTree, const u32 cluster, const u32 fileCount ) {
	const MemoryCardFileEntryCluster* entryCluster = &m_fileEntryDict[cluster];
	u32 fileCluster = cluster;

	for ( size_t i = 0; i < fileCount; ++i ) {
		const MemoryCardFileEntry* entry = &entryCluster->entries[i % 2];

		if ( entry->IsValid() && entry->IsUsed() ) {
			fileEntryTree->emplace_back( *entry );

			if ( entry->IsDir() && !entry->IsDotDir() ) {
				MemoryCardFileEntryTreeNode* treeEntry = &fileEntryTree->back();
				CopyEntryDictIntoTree( &treeEntry->subdir, entry->entry.data.cluster, entry->entry.data.length );
			}
		}

		if ( i % 2 == 1 ) {
			fileCluster = m_fat.data[0][0][fileCluster] & 0x7FFFFFFFu;
			if ( fileCluster == 0x7FFFFFFFu ) { return; }
			entryCluster = &m_fileEntryDict[fileCluster];
		}
	}
}

const MemoryCardFileEntry* FolderMemoryCard::FindEquivalent( const MemoryCardFileEntry* searchEntry, const u32 cluster, const u32 fileCount ) {
	const MemoryCardFileEntryCluster* entryCluster = &m_fileEntryDict[cluster];
	u32 fileCluster = cluster;

	for ( size_t i = 0; i < fileCount; ++i ) {
		const MemoryCardFileEntry* entry = &entryCluster->entries[i % 2];

		if ( entry->IsValid() && entry->IsUsed() ) {
			if ( entry->IsFile() == searchEntry->IsFile() && entry->IsDir() == searchEntry->IsDir()
			  && strncmp( (const char*)searchEntry->entry.data.name, (const char*)entry->entry.data.name, sizeof( entry->entry.data.name ) ) == 0 ) {
				return entry;
			}
		}

		if ( i % 2 == 1 ) {
			fileCluster = m_fat.data[0][0][fileCluster] & 0x7FFFFFFFu;
			if ( fileCluster == 0x7FFFFFFFu ) { return nullptr; }
			entryCluster = &m_fileEntryDict[fileCluster];
		}
	}

	return nullptr;
}

s32 FolderMemoryCard::EraseBlock( u32 adr ) {
	const u32 block = adr / BlockSizeRaw;

	u8 eraseData[PageSize];
	memset( eraseData, 0xFF, PageSize );
	for ( int page = 0; page < 16; ++page ) {
		const u32 adr = block * BlockSizeRaw + page * PageSizeRaw;
		Save( eraseData, adr, PageSize );
	}

	// return 0 on fail, 1 on success?
	return 1;
}

u64 FolderMemoryCard::GetCRC() const {
	// Since this is just used as integrity check for savestate loading,
	// give a timestamp of the last time the memory card was written to
	return m_timeLastWritten;
}

void FolderMemoryCard::SetSlot( uint slot ) {
	pxAssert( slot < 8 );
	m_slot = slot;
}

u32 FolderMemoryCard::GetSizeInClusters() const {
	const u32 clusters = m_superBlock.data.clusters_per_card;
	if ( clusters > 0 && clusters < 0xFFFFFFFFu ) {
		return clusters;
	} else {
		return TotalClusters;
	}
}

void FolderMemoryCard::SetSizeInClusters( u32 clusters ) {
	superBlockUnion newSuperBlock;
	memcpy( &newSuperBlock.raw[0], &m_superBlock.raw[0], sizeof( newSuperBlock.raw ) );

	newSuperBlock.data.clusters_per_card = clusters;
	
	const u32 alloc_offset = clusters / 0x100 + 9;
	newSuperBlock.data.alloc_offset = alloc_offset;
	newSuperBlock.data.alloc_end = clusters - 0x10 - alloc_offset;

	const u32 blocks = clusters / 8;
	newSuperBlock.data.backup_block1 = blocks - 1;
	newSuperBlock.data.backup_block2 = blocks - 2;

	for ( size_t i = 0; i < sizeof( newSuperBlock.raw ) / PageSize; ++i ) {
		Save( &newSuperBlock.raw[i * PageSize], i * PageSizeRaw, PageSize );
	}
}

void FolderMemoryCard::SetSizeInMB( u32 megaBytes ) {
	SetSizeInClusters( ( megaBytes * 1024 * 1024 ) / ClusterSize );
}

void FolderMemoryCard::SetTimeLastReadToNow() {
	m_framesUntilFlush = FramesAfterWriteUntilFlush;
}

void FolderMemoryCard::SetTimeLastWrittenToNow() {
	m_timeLastWritten = wxGetLocalTimeMillis().GetValue();
	m_framesUntilFlush = FramesAfterWriteUntilFlush;
}

// from http://www.oocities.org/siliconvalley/station/8269/sma02/sma02.html#ECC
void FolderMemoryCard::CalculateECC( u8* ecc, const u8* data ) {
	static const u8 Table[] = {
		0x00, 0x87, 0x96, 0x11, 0xa5, 0x22, 0x33, 0xb4, 0xb4, 0x33, 0x22, 0xa5, 0x11, 0x96, 0x87, 0x00,
		0xc3, 0x44, 0x55, 0xd2, 0x66, 0xe1, 0xf0, 0x77, 0x77, 0xf0, 0xe1, 0x66, 0xd2, 0x55, 0x44, 0xc3,
		0xd2, 0x55, 0x44, 0xc3, 0x77, 0xf0, 0xe1, 0x66, 0x66, 0xe1, 0xf0, 0x77, 0xc3, 0x44, 0x55, 0xd2,
		0x11, 0x96, 0x87, 0x00, 0xb4, 0x33, 0x22, 0xa5, 0xa5, 0x22, 0x33, 0xb4, 0x00, 0x87, 0x96, 0x11,
		0xe1, 0x66, 0x77, 0xf0, 0x44, 0xc3, 0xd2, 0x55, 0x55, 0xd2, 0xc3, 0x44, 0xf0, 0x77, 0x66, 0xe1,
		0x22, 0xa5, 0xb4, 0x33, 0x87, 0x00, 0x11, 0x96, 0x96, 0x11, 0x00, 0x87, 0x33, 0xb4, 0xa5, 0x22,
		0x33, 0xb4, 0xa5, 0x22, 0x96, 0x11, 0x00, 0x87, 0x87, 0x00, 0x11, 0x96, 0x22, 0xa5, 0xb4, 0x33,
		0xf0, 0x77, 0x66, 0xe1, 0x55, 0xd2, 0xc3, 0x44, 0x44, 0xc3, 0xd2, 0x55, 0xe1, 0x66, 0x77, 0xf0,
		0xf0, 0x77, 0x66, 0xe1, 0x55, 0xd2, 0xc3, 0x44, 0x44, 0xc3, 0xd2, 0x55, 0xe1, 0x66, 0x77, 0xf0,
		0x33, 0xb4, 0xa5, 0x22, 0x96, 0x11, 0x00, 0x87, 0x87, 0x00, 0x11, 0x96, 0x22, 0xa5, 0xb4, 0x33,
		0x22, 0xa5, 0xb4, 0x33, 0x87, 0x00, 0x11, 0x96, 0x96, 0x11, 0x00, 0x87, 0x33, 0xb4, 0xa5, 0x22,
		0xe1, 0x66, 0x77, 0xf0, 0x44, 0xc3, 0xd2, 0x55, 0x55, 0xd2, 0xc3, 0x44, 0xf0, 0x77, 0x66, 0xe1,
		0x11, 0x96, 0x87, 0x00, 0xb4, 0x33, 0x22, 0xa5, 0xa5, 0x22, 0x33, 0xb4, 0x00, 0x87, 0x96, 0x11,
		0xd2, 0x55, 0x44, 0xc3, 0x77, 0xf0, 0xe1, 0x66, 0x66, 0xe1, 0xf0, 0x77, 0xc3, 0x44, 0x55, 0xd2,
		0xc3, 0x44, 0x55, 0xd2, 0x66, 0xe1, 0xf0, 0x77, 0x77, 0xf0, 0xe1, 0x66, 0xd2, 0x55, 0x44, 0xc3,
		0x00, 0x87, 0x96, 0x11, 0xa5, 0x22, 0x33, 0xb4, 0xb4, 0x33, 0x22, 0xa5, 0x11, 0x96, 0x87, 0x00
	};

	int i, c;

	ecc[0] = ecc[1] = ecc[2] = 0;

	for ( i = 0; i < 0x80; i++ ) {
		c = Table[data[i]];

		ecc[0] ^= c;
		if ( c & 0x80 ) {
			ecc[1] ^= ~i;
			ecc[2] ^= i;
		}
	}
	ecc[0] = ~ecc[0];
	ecc[0] &= 0x77;

	ecc[1] = ~ecc[1];
	ecc[1] &= 0x7f;

	ecc[2] = ~ecc[2];
	ecc[2] &= 0x7f;

	return;
}

void FolderMemoryCard::WriteToFile( const wxString& filename ) {
	wxFFile targetFile( filename, L"wb" );

	u8 buffer[FolderMemoryCard::PageSizeRaw];
	u32 adr = 0;
	while ( adr < GetSizeInClusters() * FolderMemoryCard::ClusterSizeRaw ) {
		Read( buffer, adr, FolderMemoryCard::PageSizeRaw );
		targetFile.Write( buffer, FolderMemoryCard::PageSizeRaw );
		adr += FolderMemoryCard::PageSizeRaw;
	}

	targetFile.Close();
}


FileAccessHelper::FileAccessHelper() {
	m_files.clear();
	m_lastWrittenFileRef = nullptr;
}

FileAccessHelper::~FileAccessHelper() {
	m_lastWrittenFileRef = nullptr;
	this->CloseAll();
}

wxFFile* FileAccessHelper::Open( const wxFileName& folderName, MemoryCardFileMetadataReference* fileRef, bool writeMetadata ) {
	wxFileName fn( folderName );
	bool cleanedFilename = fileRef->GetPath( &fn );
	wxString filename( fn.GetFullPath() );

	if ( !fn.FileExists() ) {
		if ( !fn.DirExists() ) {
			fn.Mkdir( 0777, wxPATH_MKDIR_FULL );
		}
		wxFFile createEmptyFile( filename, L"wb" );
		createEmptyFile.Close();
	}

	const MemoryCardFileEntry* const entry = fileRef->entry;
	wxFFile* file = new wxFFile( filename, L"r+b" );

	std::string internalPath;
	fileRef->GetInternalPath( &internalPath );
	MemoryCardFileHandleStructure handleStruct;
	handleStruct.fileHandle = file;
	handleStruct.fileRef = fileRef;
	m_files.emplace( internalPath, handleStruct );

	if ( writeMetadata ) {
		fn.AppendDir( L"_pcsx2_meta" );
		const bool metadataIsNonstandard = cleanedFilename || entry->entry.data.mode != MemoryCardFileEntry::DefaultFileMode || entry->entry.data.attr != 0;
		WriteMetadata( metadataIsNonstandard, fn, entry );
	}

	return file;
}

void FileAccessHelper::WriteMetadata( const wxFileName& folderName, MemoryCardFileMetadataReference* fileRef ) {
	wxFileName fn( folderName );
	bool cleanedFilename = fileRef->GetPath( &fn );
	fn.AppendDir( L"_pcsx2_meta" );

	const MemoryCardFileEntry* const entry = fileRef->entry;
	const bool metadataIsNonstandard = cleanedFilename || entry->entry.data.mode != MemoryCardFileEntry::DefaultFileMode || entry->entry.data.attr != 0;

	WriteMetadata( metadataIsNonstandard, fn, entry );
}

void FileAccessHelper::WriteMetadata( bool metadataIsNonstandard, wxFileName& metadataFilename, const MemoryCardFileEntry* const entry ) {
	if ( metadataIsNonstandard ) {
		// write metadata of file if it's nonstandard
		if ( !metadataFilename.DirExists() ) {
			metadataFilename.Mkdir();
		}
		wxFFile metaFile( metadataFilename.GetFullPath(), L"wb" );
		if ( metaFile.IsOpened() ) {
			metaFile.Write( entry->entry.raw, sizeof( entry->entry.raw ) );
			metaFile.Close();
		}
	} else {
		// if metadata is standard remove metadata file if it exists
		if ( metadataFilename.FileExists() ) {
			wxRemoveFile( metadataFilename.GetFullPath() );

			// and remove the metadata dir if it's now empty
			wxDir metaDir( metadataFilename.GetPath() );
			if ( metaDir.IsOpened() && !metaDir.HasFiles() ) {
				wxRmdir( metadataFilename.GetPath() );
			}
		}
	}
}

wxFFile* FileAccessHelper::ReOpen( const wxFileName& folderName, MemoryCardFileMetadataReference* fileRef, bool writeMetadata ) {
	std::string internalPath;
	fileRef->GetInternalPath( &internalPath );
	auto it = m_files.find( internalPath );
	if ( it != m_files.end() ) {
		// we already have a handle to this file

		// if the caller wants to write metadata and we haven't done this recently, do so and remember that we did
		if ( writeMetadata ) {
			if ( m_lastWrittenFileRef != fileRef ) {
				WriteMetadata( folderName, fileRef );
				m_lastWrittenFileRef = fileRef;
			}
		} else {
			if ( m_lastWrittenFileRef != nullptr ) {
				m_lastWrittenFileRef = nullptr;
			}
		}

		// update the fileRef in the map since it might have been modified or deleted
		it->second.fileRef = fileRef;

		return it->second.fileHandle;
	} else {
		return this->Open( folderName, fileRef, writeMetadata );
	}
}

void FileAccessHelper::CloseFileHandle( wxFFile* file, const MemoryCardFileEntry* entry ) {
	file->Close();

	if ( entry != nullptr ) {
		wxFileName fn( file->GetName() );
		wxDateTime modified = entry->entry.data.timeModified.ToWxDateTime();
		wxDateTime created = entry->entry.data.timeCreated.ToWxDateTime();
		fn.SetTimes( nullptr, &modified, &created );
	}

	delete file;
}

void FileAccessHelper::CloseMatching( const wxString& path ) {
	wxFileName fn( path );
	fn.Normalize();
	wxString pathNormalized = fn.GetFullPath();
	for ( auto it = m_files.begin(); it != m_files.end(); ) {
		wxString openPath = it->second.fileHandle->GetName();
		if ( openPath.StartsWith( pathNormalized ) ) {
			CloseFileHandle( it->second.fileHandle, it->second.fileRef->entry );
			it = m_files.erase( it );
		} else {
			++it;
		}
	}
}

void FileAccessHelper::CloseAll() {
	for ( auto it = m_files.begin(); it != m_files.end(); ++it ) {
		CloseFileHandle( it->second.fileHandle, it->second.fileRef->entry );
	}
	m_files.clear();
}

void FileAccessHelper::FlushAll() {
	for ( auto it = m_files.begin(); it != m_files.end(); ++it ) {
		it->second.fileHandle->Flush();
	}
}

void FileAccessHelper::ClearMetadataWriteState() {
	m_lastWrittenFileRef = nullptr;
}

bool FileAccessHelper::CleanMemcardFilename( char* name ) {
	// invalid characters for filenames in the PS2 file system: { '/', '?', '*' }
	// the following characters are valid in a PS2 memcard file system but invalid in Windows
	// there's less restrictions on Linux but by cleaning them always we keep the folders cross-compatible
	const char illegalChars[] = { '\\', '%', ':', '|', '"', '<', '>' };
	bool cleaned = false;

	const size_t filenameLength = strlen( name );
	for ( size_t i = 0; i < sizeof( illegalChars ); ++i ) {
		for ( size_t j = 0; j < filenameLength; ++j ) {
			if ( name[j] == illegalChars[i] ) {
				name[j] = '_';
				cleaned = true;
			}
		}
	}

	cleaned = CleanMemcardFilenameEndDotOrSpace( name, filenameLength ) || cleaned;

	return cleaned;
}

bool FileAccessHelper::CleanMemcardFilenameEndDotOrSpace( char* name, size_t length ) {
	// Windows truncates dots and spaces at the end of filenames, so make sure that doesn't happen
	bool cleaned = false;
	for ( size_t j = length; j > 0; --j ) {
		switch ( name[j - 1] ) {
		case ' ':
		case '.':
			name[j - 1] = '_';
			cleaned = true;
			break;
		default:
			return cleaned;
		}
	}

	return cleaned;
}

bool MemoryCardFileMetadataReference::GetPath( wxFileName* fileName ) const {
	bool parentCleaned = false;
	if ( parent ) {
		parentCleaned = parent->GetPath( fileName );
	}

	char cleanName[sizeof( entry->entry.data.name )];
	memcpy( cleanName, (const char*)entry->entry.data.name, sizeof( cleanName ) );
	bool localCleaned = FileAccessHelper::CleanMemcardFilename( cleanName );

	if ( entry->IsDir() ) {
		fileName->AppendDir( wxString::FromAscii( cleanName ) );
	} else if ( entry->IsFile() ) {
		fileName->SetName( wxString::FromAscii( cleanName ) );
	}

	return parentCleaned || localCleaned;
}

void MemoryCardFileMetadataReference::GetInternalPath( std::string* fileName ) const {
	if ( parent ) {
		parent->GetInternalPath( fileName );
	}

	fileName->append( (const char*)entry->entry.data.name );

	if ( entry->IsDir() ) {
		fileName->append( "/" );
	}
}

FolderMemoryCardAggregator::FolderMemoryCardAggregator() {
	for ( uint i = 0; i < TotalCardSlots; ++i ) {
		m_cards[i].SetSlot( i );
	}
}

void FolderMemoryCardAggregator::Open() {
	for ( int i = 0; i < TotalCardSlots; ++i ) {
		m_cards[i].Open( m_enableFiltering, m_lastKnownFilter );
	}
}

void FolderMemoryCardAggregator::Close() {
	for ( int i = 0; i < TotalCardSlots; ++i ) {
		m_cards[i].Close();
	}
}

void FolderMemoryCardAggregator::SetFiltering( const bool enableFiltering ) {
	m_enableFiltering = enableFiltering;
}

s32 FolderMemoryCardAggregator::IsPresent( uint slot ) {
	return m_cards[slot].IsPresent();
}

void FolderMemoryCardAggregator::GetSizeInfo( uint slot, PS2E_McdSizeInfo& outways ) {
	m_cards[slot].GetSizeInfo( outways );
}

bool FolderMemoryCardAggregator::IsPSX( uint slot ) {
	return m_cards[slot].IsPSX();
}

s32 FolderMemoryCardAggregator::Read( uint slot, u8 *dest, u32 adr, int size ) {
	return m_cards[slot].Read( dest, adr, size );
}

s32 FolderMemoryCardAggregator::Save( uint slot, const u8 *src, u32 adr, int size ) {
	return m_cards[slot].Save( src, adr, size );
}

s32 FolderMemoryCardAggregator::EraseBlock( uint slot, u32 adr ) {
	return m_cards[slot].EraseBlock( adr );
}

u64 FolderMemoryCardAggregator::GetCRC( uint slot ) {
	return m_cards[slot].GetCRC();
}

void FolderMemoryCardAggregator::NextFrame( uint slot ) {
	m_cards[slot].NextFrame();
}

bool FolderMemoryCardAggregator::ReIndex( uint slot, const bool enableFiltering, const wxString& filter ) {
	if ( m_cards[slot].ReIndex( enableFiltering, filter ) ) {
		SetFiltering( enableFiltering );
		m_lastKnownFilter = filter;
		return true;
	}

	return false;
}

bool FileMcd_IsMultitapSlot(uint slot)
{
	return (slot > 1);
}
