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

#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <string.h>
#include <stdarg.h>

#include "Utilities/pxStreams.h"
#include "PAD.h"
#include "state_management.h"

#include <unistd.h>

const u32 revision = 3;
const u32 build = 0; // increase that with each version
#define PAD_SAVE_STATE_VERSION ((revision << 8) | (build << 0))

PADconf g_conf;
keyEvent event;

static keyEvent s_event;
std::string s_padstrLogPath("logs/");

FILE* padLog = NULL;

KeyStatus g_key_status;

MtQueue<keyEvent> g_ev_fifo;

s32 PADinit()
{
//	initLogging();

	PADLoadConfig();

	Pad::reset_all();

	query.reset();

	for (int port = 0; port < 2; port++)
		slots[port] = 0;

	return 0;
}

void PADshutdown()
{
//	CloseLogging();
}

s32 PADopen(void* pDsp)
{
	memset(&event, 0, sizeof(event));
	g_key_status.Init();

	g_ev_fifo.reset();

#if defined(__unix__) || defined(__APPLE__)
	GamePad::EnumerateGamePads(s_vgamePad);
#endif
	return _PADopen(pDsp);
}

void PADsetLogDir(const char* dir)
{
	// Get the path to the log directory.
	s_padstrLogPath = (dir == NULL) ? "logs/" : dir;

	// Reload the log file after updated the path
//	CloseLogging();
	initLogging();
}

void PADclose()
{
	_PADclose();
}

s32 PADsetSlot(u8 port, u8 slot)
{
	port--;
	slot--;
	if (port > 1 || slot > 3)
	{
		return 0;
	}
	// Even if no pad there, record the slot, as it is the active slot regardless.
	slots[port] = slot;

	return 1;
}

s32 PADfreeze(int mode, freezeData* data)
{
	if (!data)
		return -1;

	if (mode == FREEZE_SIZE)
	{
		data->size = sizeof(PadPluginFreezeData);
	}
	else if (mode == FREEZE_LOAD)
	{
		PadPluginFreezeData* pdata = (PadPluginFreezeData*)(data->data);

		Pad::stop_vibrate_all();

		if (data->size != sizeof(PadPluginFreezeData) || pdata->version != PAD_SAVE_STATE_VERSION ||
			strncmp(pdata->format, "LinPad", sizeof(pdata->format)))
			return 0;

		query = pdata->query;
		if (pdata->query.slot < 4)
		{
			query = pdata->query;
		}

		// Tales of the Abyss - pad fix
		// - restore data for both ports
		for (int port = 0; port < 2; port++)
		{
			for (int slot = 0; slot < 4; slot++)
			{
				u8 mode = pdata->padData[port][slot].mode;

				if (mode != MODE_DIGITAL && mode != MODE_ANALOG && mode != MODE_DS2_NATIVE)
				{
					break;
				}

				memcpy(&pads[port][slot], &pdata->padData[port][slot], sizeof(PadFreezeData));
			}

			if (pdata->slot[port] < 4)
				slots[port] = pdata->slot[port];
		}
	}
	else if (mode == FREEZE_SAVE)
	{
		if (data->size != sizeof(PadPluginFreezeData))
			return 0;

		PadPluginFreezeData* pdata = (PadPluginFreezeData*)(data->data);

		// Tales of the Abyss - pad fix
		// - PCSX2 only saves port0 (save #1), then port1 (save #2)

		memset(pdata, 0, data->size);
		strncpy(pdata->format, "LinPad", sizeof(pdata->format));
		pdata->version = PAD_SAVE_STATE_VERSION;
		pdata->query = query;

		for (int port = 0; port < 2; port++)
		{
			for (int slot = 0; slot < 4; slot++)
			{
				pdata->padData[port][slot] = pads[port][slot];
			}

			pdata->slot[port] = slots[port];
		}
	}
	else
	{
		return -1;
	}

	return 0;
}

u8 PADstartPoll(int pad)
{
	return pad_start_poll(pad);
}

u8 PADpoll(u8 value)
{
	return pad_poll(value);
}

// PADkeyEvent is called every vsync (return NULL if no event)
keyEvent* PADkeyEvent()
{
#ifdef SDL_BUILD
	// Take the opportunity to handle hot plugging here
	SDL_Event events;
	while (SDL_PollEvent(&events))
	{
		switch (events.type)
		{
			case SDL_CONTROLLERDEVICEADDED:
			case SDL_CONTROLLERDEVICEREMOVED:
				GamePad::EnumerateGamePads(s_vgamePad);
				break;
			default:
				break;
		}
	}
#endif
#ifdef __unix__
	if (g_ev_fifo.size() == 0)
	{
		// PAD_LOG("No events in queue, returning empty event\n");
		s_event = event;
		event.evt = 0;
		event.key = 0;
		return &s_event;
	}
	s_event = g_ev_fifo.dequeue();

	AnalyzeKeyEvent(s_event);
	// PAD_LOG("Returning Event. Event Type: %d, Key: %d\n", s_event.evt, s_event.key);
	return &s_event;
#else // MacOS
	s_event = event;
	event.evt = 0;
	event.key = 0;
	return &s_event;
#endif
}

#if defined(__unix__)
void PADWriteEvent(keyEvent& evt)
{
	// if (evt.evt != 6) { // Skip mouse move events for logging
	//     PAD_LOG("Pushing Event. Event Type: %d, Key: %d\n", evt.evt, evt.key);
	// }
	g_ev_fifo.push(evt);
}
#endif

void PADDoFreezeOut(void* dest)
{
	freezeData fP = {0, (s8*)dest};
	if (PADfreeze(FREEZE_SIZE, &fP) != 0)
		return;
	if (!fP.size)
		return;

	Console.Indent().WriteLn("Saving PAD");

	if (PADfreeze(FREEZE_SAVE, &fP) != 0)
		throw std::runtime_error(" * PAD: Error saving state!\n");
}


void PADDoFreezeIn(pxInputStream& infp)
{
	freezeData fP = {0, nullptr};
	if (PADfreeze(FREEZE_SIZE, &fP) != 0)
		fP.size = 0;

	Console.Indent().WriteLn("Loading PAD");

	if (!infp.IsOk() || !infp.Length())
	{
		// no state data to read, but PAD expects some state data?
		// Issue a warning to console...
		if (fP.size != 0)
			Console.Indent().Warning("Warning: No data for PAD found. Status may be unpredictable.");

		return;

		// Note: Size mismatch check could also be done here on loading, but
		// some plugins may have built-in version support for non-native formats or
		// older versions of a different size... or could give different sizes depending
		// on the status of the plugin when loading, so let's ignore it.
	}

	ScopedAlloc<s8> data(fP.size);
	fP.data = data.GetPtr();

	infp.Read(fP.data, fP.size);
	if (PADfreeze(FREEZE_LOAD, &fP) != 0)
		throw std::runtime_error(" * PAD: Error loading state!\n");
}

void _PADclose()
{
	s_vgamePad.clear();
}

s32 _PADopen(void* pDsp)
{
#ifndef __APPLE__
	GSdsp = *(Display**)pDsp;
	GSwin = (Window) * (((u32*)pDsp) + 1);
#endif

	return 0;
}

void PADconfigure()
{
	// Do nothing
}
