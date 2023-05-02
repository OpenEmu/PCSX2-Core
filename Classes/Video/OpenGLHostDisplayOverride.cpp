/*  PCSX2 - PS2 Emulator for PCs
 *  Copyright (C) 2002-2021  PCSX2 Dev Team
 *
 *  PCSX2 is free software: you can redistribute it and/or modify it under the terms
 *  of the GNU Lesser General Public License as published by the Free Software Found-
 *  ation, either version 3 of the License, or (at your option) any later version.
 *
 *  PCSX2 is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 *  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 *  PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with PCSX2.
 *  If not, see <http://www.gnu.org/licenses/>.
 */

#include "PrecompiledHeader.h"
#include "Video/OEHostDisplay.h"

#include "common/Assertions.h"
#include "common/Console.h"
#include "common/ScopedGuard.h"
#include "common/StringUtil.h"
#include "common/GL/Program.h"
#include <array>
#include <tuple>

static int OE_FBO = 0;

#if 0
class OpenGLHostDisplayTexture : public HostDisplayTexture
{
public:
	OpenGLHostDisplayTexture(GLuint texture, u32 width, u32 height)
		: m_texture(texture)
		, m_width(width)
		, m_height(height)
	{
	}
	~OpenGLHostDisplayTexture() override = default;

	void* GetHandle() const override { return reinterpret_cast<void*>(static_cast<uintptr_t>(m_texture)); }
	u32 GetWidth() const override { return m_width; }
	u32 GetHeight() const override { return m_height; }

	GLuint GetGLID() const { return m_texture; }

private:
	GLuint m_texture;
	u32 m_width;
	u32 m_height;
};

OpenGLHostDisplay::OpenGLHostDisplay() = default;

OpenGLHostDisplay::~OpenGLHostDisplay()
{
	if (m_gl_context)
	{
		m_gl_context->DoneCurrent();
		m_gl_context.reset();
	}
}

RenderAPI OpenGLHostDisplay::GetRenderAPI() const
{
	return m_gl_context->IsGLES() ? RenderAPI::OpenGLES : RenderAPI::OpenGL;
}

void* OpenGLHostDisplay::GetDevice() const
{
	return nullptr;
}

void* OpenGLHostDisplay::GetContext() const
{
	return m_gl_context.get();
}

void* OpenGLHostDisplay::GetSurface() const
{
	return nullptr;
}

std::unique_ptr<HostDisplayTexture> OpenGLHostDisplay::CreateTexture(u32 width, u32 height, const void* data, u32 data_stride, bool dynamic /* = false */)
{
	// clear error
	glGetError();

	// don't worry, I'm planning on removing this eventually - we'll use GSTexture instead.
	glActiveTexture(GL_TEXTURE7);

	GLuint id;
	glGenTextures(1, &id);
	glBindTexture(GL_TEXTURE_2D, id);

	if (GLAD_GL_ARB_texture_storage || GLAD_GL_ES_VERSION_3_0)
	{
		glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, width, height);
		glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, data);
	}
	else
	{
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, data);
	}

	glActiveTexture(GL_TEXTURE0);

	GLenum error = glGetError();
	if (error != GL_NO_ERROR)
	{
		Console.Error("Failed to create texture: 0x%X", error);
		glDeleteTextures(1, &id);
		return nullptr;
	}

	return std::make_unique<OpenGLHostDisplayTexture>(id, width, height);
}

void OpenGLHostDisplay::UpdateTexture(HostDisplayTexture* texture, u32 x, u32 y, u32 width, u32 height, const void* texture_data, u32 texture_data_stride)
{
	glActiveTexture(GL_TEXTURE7);

	glPixelStorei(GL_UNPACK_ROW_LENGTH, texture_data_stride / sizeof(u32));

	glTexSubImage2D(GL_TEXTURE_2D, 0, x, y, width, height, GL_RGBA8, GL_UNSIGNED_BYTE, texture_data);

	glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);

	glActiveTexture(GL_TEXTURE0);
}

void OpenGLHostDisplay::SetVSync(VsyncMode mode)
{
	if (m_vsync_mode == mode || m_gl_context->GetWindowInfo().type == WindowInfo::Type::Surfaceless)
		return;

	// Window framebuffer has to be bound to call SetSwapInterval.
	GLint current_fbo = 0;
	glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &current_fbo);
	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);

	if (mode != VsyncMode::Adaptive || !m_gl_context->SetSwapInterval(-1))
		m_gl_context->SetSwapInterval(static_cast<s32>(mode != VsyncMode::Off));

	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, current_fbo);
	m_vsync_mode = mode;
}

const char* OpenGLHostDisplay::GetGLSLVersionString() const
{
	if (GetRenderAPI() == RenderAPI::OpenGLES)
	{
		if (GLAD_GL_ES_VERSION_3_0)
			return "#version 300 es";
		else
			return "#version 100";
	}
	else
	{
		if (GLAD_GL_VERSION_3_3)
			return "#version 330";
		else
			return "#version 130";
	}
}

std::string OpenGLHostDisplay::GetGLSLVersionHeader() const
{
	std::string header = GetGLSLVersionString();
	header += "\n\n";
	if (GetRenderAPI() == RenderAPI::OpenGLES)
	{
		header += "precision highp float;\n";
		header += "precision highp int;\n\n";
	}

	return header;
}

bool OpenGLHostDisplay::HasDevice() const
{
	return static_cast<bool>(m_gl_context);
}

bool OpenGLHostDisplay::HasSurface() const
{
	return m_window_info.type != WindowInfo::Type::Surfaceless;
}

bool OpenGLHostDisplay::CreateDevice(const WindowInfo& wi, VsyncMode vsync)
{
	m_gl_context = GL::Context::Create(wi);
	if (!m_gl_context)
	{
		Console.Error("Failed to create any GL context");
		m_gl_context.reset();
		return false;
	}
	
	OE_FBO = Host::PresentFrameBuffer();

	m_window_info = m_gl_context->GetWindowInfo();
	m_vsync_mode = vsync;
	return true;
}

bool OpenGLHostDisplay::SetupDevice()
{
	// We do use 8-bit formats, and higher alignment for 32-bit formats won't hurt anything.
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);

	SetSwapInterval();
	GL::Program::ResetLastProgram();
	return true;
}

void OpenGLHostDisplay::SetSwapInterval()
{
	const int interval = ((m_vsync_mode == VsyncMode::Adaptive) ? -1 : ((m_vsync_mode == VsyncMode::On) ? 1 : 0));
	m_gl_context->SetSwapInterval(interval);
}

bool OpenGLHostDisplay::MakeCurrent()
{
	if (!m_gl_context->MakeCurrent())
	{
		Console.Error("Failed to make GL context current");
		return false;
	}

	SetSwapInterval();
	return true;
}

bool OpenGLHostDisplay::DoneCurrent()
{
	return m_gl_context->DoneCurrent();
}

bool OpenGLHostDisplay::ChangeWindow(const WindowInfo& new_wi)
{
	pxAssert(m_gl_context);

	if (!m_gl_context->ChangeSurface(new_wi))
	{
		Console.Error("Failed to change surface");
		return false;
	}

	m_window_info = m_gl_context->GetWindowInfo();

	if (new_wi.type != WindowInfo::Type::Surfaceless)
	{
		// reset vsync rate, since it (usually) gets lost
		if (m_vsync_mode != VsyncMode::Adaptive || !m_gl_context->SetSwapInterval(-1))
			m_gl_context->SetSwapInterval(static_cast<s32>(m_vsync_mode != VsyncMode::Off));
	}

	return true;
}

void OpenGLHostDisplay::ResizeWindow(s32 new_window_width, s32 new_window_height, float new_window_scale)
{
	if (!m_gl_context)
		return;

	m_window_info.surface_scale = new_window_scale;
	if (m_window_info.surface_width == static_cast<u32>(new_window_width) &&
		m_window_info.surface_height == static_cast<u32>(new_window_height))
	{
		return;
	}

	m_gl_context->ResizeSurface(static_cast<u32>(new_window_width), static_cast<u32>(new_window_height));
	m_window_info = m_gl_context->GetWindowInfo();
}

bool OpenGLHostDisplay::SupportsFullscreen() const
{
	return false;
}

bool OpenGLHostDisplay::IsFullscreen()
{
	return false;
}

bool OpenGLHostDisplay::SetFullscreen(bool fullscreen, u32 width, u32 height, float refresh_rate)
{
	return false;
}

HostDisplay::AdapterAndModeList OpenGLHostDisplay::GetAdapterAndModeList()
{
	AdapterAndModeList aml;

	if (m_gl_context)
	{
		for (const GL::Context::FullscreenModeInfo& fmi : m_gl_context->EnumerateFullscreenModes())
			aml.fullscreen_modes.push_back(GetFullscreenModeString(fmi.width, fmi.height, fmi.refresh_rate));
	}

	return aml;
}

void OpenGLHostDisplay::DestroySurface()
{
	if (!m_gl_context)
		return;

	m_window_info = {};
	if (!m_gl_context->ChangeSurface(m_window_info))
		Console.Error("Failed to switch to surfaceless");
}

std::string OpenGLHostDisplay::GetDriverInfo() const
{
	const char* gl_vendor = reinterpret_cast<const char*>(glGetString(GL_VENDOR));
	const char* gl_renderer = reinterpret_cast<const char*>(glGetString(GL_RENDERER));
	const char* gl_version = reinterpret_cast<const char*>(glGetString(GL_VERSION));
	return StringUtil::StdStringFromFormat(
		"%s Context:\n%s\n%s %s", m_gl_context->IsGLES() ? "OpenGL ES" : "OpenGL", gl_version, gl_vendor, gl_renderer);
}

bool OpenGLHostDisplay::CreateImGuiContext()
{
	return true;
}

void OpenGLHostDisplay::DestroyImGuiContext()
{
}

bool OpenGLHostDisplay::UpdateImGuiFontTexture()
{
	return true;
}

HostDisplay::PresentResult OpenGLHostDisplay::BeginPresent(bool frame_skip)
{
	if (frame_skip || m_window_info.type == WindowInfo::Type::Surfaceless)
	{
		return PresentResult::FrameSkipped;
	}

	glDisable(GL_SCISSOR_TEST);
	glBindFramebuffer(GL_DRAW_FRAMEBUFFER, OE_FBO);
	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	glViewport(0, 0, m_window_info.surface_width, m_window_info.surface_height);

	return PresentResult::OK;
}

void OpenGLHostDisplay::EndPresent()
{
	glDisable(GL_SCISSOR_TEST);
	glDisable(GL_STENCIL_TEST);

	GL::Program::ResetLastProgram();

	if (m_gpu_timing_enabled)
		PopTimestampQuery();

	m_gl_context->SwapBuffers();

	if (m_gpu_timing_enabled)
		KickTimestampQuery();
}

void OpenGLHostDisplay::CreateTimestampQueries()
{
	const bool gles = m_gl_context->IsGLES();
	const auto GenQueries = gles ? glGenQueriesEXT : glGenQueries;

	GenQueries(static_cast<u32>(m_timestamp_queries.size()), m_timestamp_queries.data());
	KickTimestampQuery();
}

void OpenGLHostDisplay::DestroyTimestampQueries()
{
	if (m_timestamp_queries[0] == 0)
		return;

	const bool gles = m_gl_context->IsGLES();
	const auto DeleteQueries = gles ? glDeleteQueriesEXT : glDeleteQueries;

	if (m_timestamp_query_started)
	{
		const auto EndQuery = gles ? glEndQueryEXT : glEndQuery;
		EndQuery(GL_TIME_ELAPSED);
	}

	DeleteQueries(static_cast<u32>(m_timestamp_queries.size()), m_timestamp_queries.data());
	m_timestamp_queries.fill(0);
	m_read_timestamp_query = 0;
	m_write_timestamp_query = 0;
	m_waiting_timestamp_queries = 0;
	m_timestamp_query_started = false;
}

void OpenGLHostDisplay::PopTimestampQuery()
{
	const bool gles = m_gl_context->IsGLES();

	if (gles)
	{
		GLint disjoint = 0;
		glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
		if (disjoint)
		{
			DevCon.WriteLn("GPU timing disjoint, resetting.");
			if (m_timestamp_query_started)
				glEndQueryEXT(GL_TIME_ELAPSED);

			m_read_timestamp_query = 0;
			m_write_timestamp_query = 0;
			m_waiting_timestamp_queries = 0;
			m_timestamp_query_started = false;
		}
	}

	while (m_waiting_timestamp_queries > 0)
	{
		const auto GetQueryObjectiv = gles ? glGetQueryObjectivEXT : glGetQueryObjectiv;
		const auto GetQueryObjectui64v = gles ? glGetQueryObjectui64vEXT : glGetQueryObjectui64v;

		GLint available = 0;
		GetQueryObjectiv(m_timestamp_queries[m_read_timestamp_query], GL_QUERY_RESULT_AVAILABLE, &available);

		if (!available)
			break;

		u64 result = 0;
		GetQueryObjectui64v(m_timestamp_queries[m_read_timestamp_query], GL_QUERY_RESULT, &result);
		m_accumulated_gpu_time += static_cast<float>(static_cast<double>(result) / 1000000.0);
		m_read_timestamp_query = (m_read_timestamp_query + 1) % NUM_TIMESTAMP_QUERIES;
		m_waiting_timestamp_queries--;
	}

	if (m_timestamp_query_started)
	{
		const auto EndQuery = gles ? glEndQueryEXT : glEndQuery;
		EndQuery(GL_TIME_ELAPSED);

		m_write_timestamp_query = (m_write_timestamp_query + 1) % NUM_TIMESTAMP_QUERIES;
		m_timestamp_query_started = false;
		m_waiting_timestamp_queries++;
	}
}

void OpenGLHostDisplay::KickTimestampQuery()
{
	if (m_timestamp_query_started || m_waiting_timestamp_queries == NUM_TIMESTAMP_QUERIES)
		return;

	const bool gles = m_gl_context->IsGLES();
	const auto BeginQuery = gles ? glBeginQueryEXT : glBeginQuery;

	BeginQuery(GL_TIME_ELAPSED, m_timestamp_queries[m_write_timestamp_query]);
	m_timestamp_query_started = true;
}

bool OpenGLHostDisplay::SetGPUTimingEnabled(bool enabled)
{
	if (m_gpu_timing_enabled == enabled)
		return true;

	if (enabled && m_gl_context->IsGLES() && !GLAD_GL_EXT_disjoint_timer_query)
		return false;

	m_gpu_timing_enabled = enabled;
	if (m_gpu_timing_enabled)
		CreateTimestampQueries();
	else
		DestroyTimestampQueries();

	return true;
}

float OpenGLHostDisplay::GetAndResetAccumulatedGPUTime()
{
	const float value = m_accumulated_gpu_time;
	m_accumulated_gpu_time = 0.0f;
	return value;
}

#endif
