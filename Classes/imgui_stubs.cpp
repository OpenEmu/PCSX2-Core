// Copyright (c) 2024, OpenEmu Team
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

#include "SmallString.h"
#include "ImGui/ImGuiManager.h"
#include "ImGui/ImGuiOverlays.h"
#include "ImGui/FullscreenUI.h"

InputRecordingUI::InputRecordingData g_InputRecordingData;

void ImGuiManager::SetFontPath(std::string path)
{
	
}

bool ImGuiManager::Initialize()
{
	return true;
}

void ImGuiManager::Shutdown(bool clear_state)
{
	
}

float ImGuiManager::GetWindowWidth()
{
	return 640;
}

float ImGuiManager::GetWindowHeight()
{
	return 480;
}

void ImGuiManager::WindowResized()
{
	
}

void ImGuiManager::RequestScaleUpdate()
{
	
}

void ImGuiManager::NewFrame()
{
	
}

void ImGuiManager::RenderOSD()
{
	
}

float ImGuiManager::GetGlobalScale()
{
	return 1;
}

ImFont* ImGuiManager::GetStandardFont()
{
	return nullptr;
}

ImFont* ImGuiManager::GetFixedFont()
{
	return nullptr;
}

bool ImGuiManager::WantsTextInput()
{
	return false;
}

bool ImGuiManager::WantsMouseInput()
{
	return false;
}

void ImGuiManager::AddTextInput(std::string str)
{
	
}

void ImGuiManager::UpdateMousePosition(float x, float y)
{
	
}

bool ImGuiManager::ProcessGenericInputEvent(GenericInputBinding key, InputLayout layout, float value)
{
	return false;
}

void ImGuiManager::SetSoftwareCursor(u32 index, std::string image_path, float image_scale, u32 multiply_color)
{
	
}

bool ImGuiManager::HasSoftwareCursor(u32 index)
{
	return false;
}

void ImGuiManager::ClearSoftwareCursor(u32 index)
{
	
}

void ImGuiManager::SetSoftwareCursorPosition(u32 index, float pos_x, float pos_y)
{
	
}

void ImGuiManager::SkipFrame()
{
	
}

#pragma mark - FullscreenUI stubs

void FullscreenUI::GameChanged(std::string title, std::string path, std::string serial, u32 disc_crc, u32 crc)
{
	
}

void FullscreenUI::OnVMStarted()
{
	
}

void FullscreenUI::OnVMDestroyed()
{
	
}

void FullscreenUI::CheckForConfigChanges(const Pcsx2Config &old_config)
{
	
}

void FullscreenUI::Render()
{
	
}

void SaveStateSelectorUI::Clear()
{
	
}
