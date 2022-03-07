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

#ifndef OEUpscalePatches_h
#define OEUpscalePatches_h

/// These games require the Wild ARms Hack to display intro and text correctly (intro at all internal resolution, text above 1x internal resolution)
static NSSet *wildArmsGames = [NSSet setWithObjects:
	@"SCAJ-20123",	@"SCAJ-30002",	@"SCPS-15023",	@"SCPS-15024",	@"SCPS-15091",
	@"SCPS-15092",	@"SCPS-15118",	@"SCPS-17002",	@"SCPS-19205",	@"SCPS-19251",
	@"SCPS-19253",	@"SCPS-19313",	@"SCPS-19322",	@"SCPS-19323",	@"SCPS-55006",
	@"SCUS-97203",	@"SCUS-97224",	@"SLES-51307",	@"SLES-54239",	@"SLES-54972",
	@"SLUS-20937",	@"SLUS-21292",	@"SLUS-21615",  nil ];

/// These games require the align sprites hack to remove vertical bars at internal resolutions above 1x
static NSSet *alignSpriteGames = [NSSet setWithObjects:
	//Tekken
	@"SCKA-20039",	@"SCAJ-20116" ,	@"SCAJ-20125",	@"SCAJ-20126",	@"SCAJ-20199",
	@"SCED-50041",	@"SCES-50001",	@"SCES-50878",	@"SCES-53202",	@"SCKA-20049",
	@"SCKA-20081",	@"SCPS-55017",	@"SCPS-56002",	@"SCPS-56006",	@"SLPS-20015",
	@"SLPS-25100",	@"SLPS-25422",	@"SLPS-25510",	@"SLPS-73104",	@"SLPS-73209",
	@"SLPS-73223",	@"SLUS-20001",	@"SLUS-20328",	@"SLUS-21059",	@"SLUS-21160",
	@"SLUS-28012",	@"SLUS-29034",
	//Soul Calibur
	@"SCAJ-20023",	@"SLUS-29058",	@"SCAJ-20159",	@"SCES-53312",	@"SCKA-20016",
	@"SCKA-20059",	@"SLED-51901",	@"SLES-51799",	@"SLPM-61133",	@"SLPS-25230",
	@"SLPS-25577",	@"SLUS-20643",	@"SLUS-21216",  @"SLUS-20643BD",
	//Namco
	@"SCAJ-20130",	@"SCAJ-20131",	@"SLES-53957",	@"SLPS-25500",	@"SLPS-25505",
	@"SLPS-25590",	@"SLPS-73243",	@"SLUS-20273",	@"SLUS-21164",	@"SLUS-29071",
	@"SLUS-29134",	@"SLUS-29174",	@"SLUS-29175",  @"SLUS-20937",  nil ];

#endif /* OEUpscalePatches_h */
