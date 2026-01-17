
// Stubs for achievements. Obj-C++ for when OpenEmu adds support.

#include "SmallString.h"
#include "Achievements.h"

static std::recursive_mutex s_achievements_mutex;

bool Achievements::IsUsingRAIntegration()
{
  return false;
}

void Achievements::IdleUpdate()
{
	
}

bool Achievements::Initialize()
{
	return false;
}

void Achievements::FrameUpdate() {
	
}

bool Achievements::HasRichPresence()
{
	return false;
}

static std::string blank = "";
const std::string& Achievements::GetRichPresenceString()
{
	return blank;
}

void Achievements::GameChanged(u32 disc_crc, u32 crc)
{
	
}

void Achievements::ResetClient()
{
	
}

void Achievements::OnVMPaused(bool paused)
{
	
}

void Achievements::UpdateSettings(const Pcsx2Config::AchievementsOptions &old_config)
{
	
}

bool Achievements::ResetHardcoreMode(bool is_booting)
{
	return false;
}

bool Achievements::ConfirmSystemReset()
{
	return false;
}

void Achievements::DisableHardcoreMode()
{
	
}

bool Achievements::IsHardcoreModeActive()
{
	return false;
}

bool Achievements::IsActive()
{
	return false;
}

bool Achievements::Shutdown(bool allow_cancel)
{
	return true;
}

bool Achievements::HasActiveGame()
{
	return false;
}

const std::string& Achievements::GetGameIconURL()
{
	return blank;
}

bool Achievements::HasAchievementsOrLeaderboards()
{
	return false;
}

std::unique_lock<std::recursive_mutex> Achievements::GetLock()
{
	return std::unique_lock(s_achievements_mutex);
}
