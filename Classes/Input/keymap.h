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

#ifndef keymap_h
#define keymap_h

#include "SIO/Pad/PadDualshock2.h"

typedef struct
{
	PadDualshock2::Inputs ps2key;
}keymap;

keymap ps2keymap[25]={
	{PadDualshock2::PAD_UP},			//	OEPS2ButtonUp,
	{PadDualshock2::PAD_DOWN},			//	OEPS2ButtonDown,
	{PadDualshock2::PAD_LEFT},			//	OEPS2ButtonLeft,
	{PadDualshock2::PAD_RIGHT},			//	OEPS2ButtonRight,
	{PadDualshock2::PAD_TRIANGLE},		//	OEPS2ButtonTriangle,
	{PadDualshock2::PAD_CIRCLE},		//	OEPS2ButtonCircle,
	{PadDualshock2::PAD_CROSS},			//	OEPS2ButtonCross,
	{PadDualshock2::PAD_SQUARE},		//	OEPS2ButtonSquare,
	{PadDualshock2::PAD_L1},			//	OEPS2ButtonL1,
	{PadDualshock2::PAD_L2},			//	OEPS2ButtonL2,
	{PadDualshock2::PAD_L3},			//	OEPS2ButtonL3,
	{PadDualshock2::PAD_R1},			//	OEPS2ButtonR1,
	{PadDualshock2::PAD_R2},			//	OEPS2ButtonR2,
	{PadDualshock2::PAD_R3},			//	OEPS2ButtonR3,
	{PadDualshock2::PAD_START},			//	OEPS2ButtonStart,
	{PadDualshock2::PAD_SELECT},		//	OEPS2ButtonSelect,
	{PadDualshock2::PAD_ANALOG}, 		//  OEPS2ButtonAnalogMode,
	{PadDualshock2::PAD_L_UP},			//	OEPS2LeftAnalogUp,
	{PadDualshock2::PAD_L_DOWN},		//	OEPS2LeftAnalogDown,
	{PadDualshock2::PAD_L_LEFT},		//	OEPS2LeftAnalogLeft,
	{PadDualshock2::PAD_L_RIGHT},		//	OEPS2LeftAnalogRight,
	{PadDualshock2::PAD_R_UP},			//	OEPS2RightAnalogUp,
	{PadDualshock2::PAD_R_DOWN},		//	OEPS2RightAnalogDown,
	{PadDualshock2::PAD_R_LEFT},		//	OEPS2RightAnalogLeft,
	{PadDualshock2::PAD_R_RIGHT},		//	OEPS2RightAnalogRight
};
#endif /* keymap_h */
