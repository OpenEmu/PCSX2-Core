/*  PCSX2 - PS2 Emulator for PCs
 *  Copyright (C) 2002-2022 PCSX2 Dev Team
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

#include "PCSX2GameCore.h"
#include "PrecompiledHeader.h"
#include "MetalHostDisplay.h"
#include "GS/Renderers/Metal/GSMetalCPPAccessible.h"
#include "GS/Renderers/Metal/GSDeviceMTL.h"

#ifdef __APPLE__

class MetalHostDisplayTexture final : public HostDisplayTexture
{
	MRCOwned<id<MTLTexture>> m_tex;
	
	u32 m_width, m_height;
public:
	MetalHostDisplayTexture(MRCOwned<id<MTLTexture>> tex, u32 width, u32 height)
		: m_tex(std::move(tex))
		, m_width(width)
		, m_height(height)
	{
	}

	void* GetHandle() const override { return (__bridge void*)m_tex; };
	u32 GetWidth()  const override { return m_width; }
	u32 GetHeight() const override { return m_height; }
};

HostDisplay* MakeMetalHostDisplay()
{
	return new MetalHostDisplay();
}

MetalHostDisplay::MetalHostDisplay()
{
}

MetalHostDisplay::~MetalHostDisplay()
{
	MetalHostDisplay::DestroySurface();
	m_queue = nullptr;
	m_dev.Reset();
}

HostDisplay::AdapterAndModeList GetMetalAdapterAndModeList()
{ @autoreleasepool {
	HostDisplay::AdapterAndModeList list;
	auto devs = MRCTransfer(MTLCopyAllDevices());
	for (id<MTLDevice> dev in devs.Get())
		list.adapter_names.push_back([[dev name] UTF8String]);
	return list;
}}

template <typename Fn>
static void OnMainThread(Fn&& fn)
{
	if ([NSThread isMainThread])
		fn();
	else
		dispatch_sync(dispatch_get_main_queue(), fn);
}

RenderAPI MetalHostDisplay::GetRenderAPI() const
{
	return RenderAPI::Metal;
}

void* MetalHostDisplay::GetDevice()  const { return const_cast<void*>(static_cast<const void*>(&m_dev)); }
void* MetalHostDisplay::GetContext() const { return (__bridge void*)m_queue; }
void* MetalHostDisplay::GetSurface() const { return (__bridge void*)m_layer; }
bool MetalHostDisplay::HasDevice()   const { return m_dev.IsOk(); }
bool MetalHostDisplay::HasSurface()  const { return static_cast<bool>(m_layer);}

void MetalHostDisplay::AttachSurfaceOnMainThread()
{
}

void MetalHostDisplay::DetachSurfaceOnMainThread()
{
}

bool MetalHostDisplay::CreateDevice(const WindowInfo& wi, VsyncMode vsync)
{ @autoreleasepool {
	m_window_info = wi;

	m_dev=GSMTLDevice(MRCRetain([_current metalDevice]));
	m_queue = MRCTransfer([m_dev.dev newCommandQueue]);

	m_pass_desc = MRCTransfer([MTLRenderPassDescriptor new]);
	[m_pass_desc colorAttachments][0].loadAction = MTLLoadActionClear;
	[m_pass_desc colorAttachments][0].clearColor = MTLClearColorMake(0, 0, 0, 0);
	[m_pass_desc colorAttachments][0].storeAction = MTLStoreActionStore;

	if (char* env = getenv("MTL_USE_PRESENT_DRAWABLE"))
		m_use_present_drawable = static_cast<UsePresentDrawable>(atoi(env));
	else if (@available(macOS 13.0, *))
		m_use_present_drawable = UsePresentDrawable::Always;
	else // Before Ventura, presentDrawable acts like vsync is on when windowed
		m_use_present_drawable = UsePresentDrawable::IfVsync;

	m_capture_start_frame = 0;
	if (char* env = getenv("MTL_CAPTURE"))
	{
		m_capture_start_frame = atoi(env);
	}
	if (m_capture_start_frame)
	{
		Console.WriteLn("Metal will capture frame %u", m_capture_start_frame);
	}

	if (m_dev.IsOk() && m_queue)
	{
		Console.WriteLn("Renderer info:\n    %s", GetDriverInfo().c_str());
			
		m_layer = MRCRetain([CAMetalLayer layer]);
		m_layer.Get().framebufferOnly=NO;
		[m_layer setDrawableSize:CGSizeMake(m_window_info.surface_width, m_window_info.surface_height)];
		[m_layer setDevice:m_dev.dev];
		
		SetVSync(vsync);
		return true;
	}
	else
		return false;
}}

bool MetalHostDisplay::SetupDevice()
{
	return true;
}

bool MetalHostDisplay::MakeCurrent() { return true; }
bool MetalHostDisplay::DoneCurrent() { return true; }

void MetalHostDisplay::DestroySurface()
{
	if (!m_layer)
		return;
	
	m_layer = nullptr;
	
}

bool MetalHostDisplay::ChangeWindow(const WindowInfo& wi)
{
	return true;
}

bool MetalHostDisplay::SupportsFullscreen() const { return false; }
bool MetalHostDisplay::IsFullscreen() { return false; }
bool MetalHostDisplay::SetFullscreen(bool fullscreen, u32 width, u32 height, float refresh_rate) { return false; }

HostDisplay::AdapterAndModeList MetalHostDisplay::GetAdapterAndModeList()
{
	return GetMetalAdapterAndModeList();
}

std::string MetalHostDisplay::GetDriverInfo() const
{ @autoreleasepool {
	std::string desc([[m_dev.dev description] UTF8String]);
	desc += "\n    Texture Swizzle:   " + std::string(m_dev.features.texture_swizzle   ? "Supported" : "Unsupported");
	desc += "\n    Unified Memory:    " + std::string(m_dev.features.unified_memory    ? "Supported" : "Unsupported");
	desc += "\n    Framebuffer Fetch: " + std::string(m_dev.features.framebuffer_fetch ? "Supported" : "Unsupported");
	desc += "\n    Primitive ID:      " + std::string(m_dev.features.primid            ? "Supported" : "Unsupported");
	desc += "\n    Shader Version:    " + std::string(to_string(m_dev.features.shader_version));
	desc += "\n    Max Texture Size:  " + std::to_string(m_dev.features.max_texsize);
	return desc;
}}

void MetalHostDisplay::ResizeWindow(s32 new_window_width, s32 new_window_height, float new_window_scale)
{
	m_window_info.surface_scale = new_window_scale;
	if (m_window_info.surface_width == static_cast<u32>(new_window_width) && m_window_info.surface_height == static_cast<u32>(new_window_height))
		return;
	m_window_info.surface_width = new_window_width;
	m_window_info.surface_height = new_window_height;
	@autoreleasepool
	{
		[m_layer setDrawableSize:CGSizeMake(new_window_width, new_window_height)];
	}
}

std::unique_ptr<HostDisplayTexture> MetalHostDisplay::CreateTexture(u32 width, u32 height, const void* data, u32 data_stride, bool dynamic)
{ @autoreleasepool {
	MTLTextureDescriptor* desc = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
									 width:width
									height:height
								 mipmapped:false];
	[desc setUsage:MTLTextureUsageShaderRead];
	[desc setStorageMode:MTLStorageModePrivate];
	MRCOwned<id<MTLTexture>> tex = MRCTransfer([m_dev.dev newTextureWithDescriptor:desc]);
	if (!tex)
		return nullptr; // Something broke yay
	[tex setLabel:@"MetalHostDisplay Texture"];
	if (data)
		UpdateTexture(tex, 0, 0, width, height, data, data_stride);
	return std::make_unique<MetalHostDisplayTexture>(std::move(tex), width, height);
}}

void MetalHostDisplay::UpdateTexture(id<MTLTexture> texture, u32 x, u32 y, u32 width, u32 height, const void* data, u32 data_stride)
{
	id<MTLCommandBuffer> cmdbuf = [m_queue commandBuffer];
	id<MTLBlitCommandEncoder> enc = [cmdbuf blitCommandEncoder];
	size_t bytes = data_stride * height;
	MRCOwned<id<MTLBuffer>> buf = MRCTransfer([m_dev.dev newBufferWithLength:bytes options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined]);
	memcpy([buf contents], data, bytes);
	[enc copyFromBuffer:buf
	       sourceOffset:0
	  sourceBytesPerRow:data_stride
	sourceBytesPerImage:bytes
	         sourceSize:MTLSizeMake(width, height, 1)
	          toTexture:texture
	   destinationSlice:0
	   destinationLevel:0
	  destinationOrigin:MTLOriginMake(0, 0, 0)];
	[enc endEncoding];
	[cmdbuf commit];
}

void MetalHostDisplay::UpdateTexture(HostDisplayTexture* texture, u32 x, u32 y, u32 width, u32 height, const void* data, u32 data_stride)
{ @autoreleasepool {
	UpdateTexture((__bridge id<MTLTexture>)texture->GetHandle(), x, y, width, height, data, data_stride);
}}

static bool s_capture_next = false;

bool MetalHostDisplay::BeginPresent(bool frame_skip)
{ @autoreleasepool {
	GSDeviceMTL* dev = static_cast<GSDeviceMTL*>(g_gs_device.get());
	if (dev && m_capture_start_frame && dev->FrameNo() == m_capture_start_frame)
		s_capture_next = true;
	if (frame_skip || m_window_info.type == WindowInfo::Type::Surfaceless || !g_gs_device)
	{
		return false;
	}
	id<MTLCommandBuffer> buf = dev->GetRenderCmdBuf();
	m_current_drawable = MRCRetain([m_layer nextDrawable]);
	dev->EndRenderPass();
	if (!m_current_drawable)
	{
		[buf pushDebugGroup:@"Present Skipped"];
		[buf popDebugGroup];
		dev->FlushEncoders();
		return false;
	}
	[m_pass_desc colorAttachments][0].texture = [m_current_drawable texture];
	id<MTLRenderCommandEncoder> enc = [buf renderCommandEncoderWithDescriptor:m_pass_desc];
	[enc setLabel:@"Present"];
	dev->m_current_render.encoder = MRCRetain(enc);
	
	
	return true;
}}

void MetalHostDisplay::EndPresent()
{ @autoreleasepool {
	GSDeviceMTL* dev = static_cast<GSDeviceMTL*>(g_gs_device.get());
	pxAssertDev(dev && dev->m_current_render.encoder && dev->m_current_render_cmdbuf, "BeginPresent cmdbuf was destroyed");
	dev->EndRenderPass();
	
	if (m_current_drawable){  //Here is where we blit the Metal Texture to the OEMetalRenderTexture
		id<MTLBlitCommandEncoder> blitCommandEncoder = [dev->m_current_render_cmdbuf blitCommandEncoder];
		
		if (@available(macOS 10.15, *)) {
			[blitCommandEncoder copyFromTexture:[m_current_drawable texture] toTexture:id<MTLTexture>([_current metalTexture])];
		} else {
			// Fallback on earlier versions
			// TODO:  Add pre 10.15 metal blit
		}
		
		[blitCommandEncoder endEncoding];
	}
	
	if (@available(macOS 10.15, iOS 13, *))
	{
		const bool use_present_drawable = m_use_present_drawable == UsePresentDrawable::Always ||
			(m_use_present_drawable == UsePresentDrawable::IfVsync && m_vsync_mode != VsyncMode::Off);

		if (use_present_drawable)
			[dev->m_current_render_cmdbuf presentDrawable:m_current_drawable];
		else
			[dev->m_current_render_cmdbuf addScheduledHandler:[drawable = std::move(m_current_drawable)](id<MTLCommandBuffer>){
				[drawable present];
			}];
	}
	dev->FlushEncoders();
	dev->FrameCompleted();
	m_current_drawable = nullptr;
	if (m_capture_start_frame)
	{
		if (@available(macOS 10.15, iOS 13, *))
		{
			static NSString* const path = @"/tmp/PCSX2MTLCapture.gputrace";
			static u32 frames;
			if (frames)
			{
				--frames;
				if (!frames)
				{
					[[MTLCaptureManager sharedCaptureManager] stopCapture];
					Console.WriteLn("Metal Trace Capture to /tmp/PCSX2MTLCapture.gputrace finished");
					[[NSWorkspace sharedWorkspace] selectFile:path
					                 inFileViewerRootedAtPath:@"/tmp/"];
				}
			}
			else if (s_capture_next)
			{
				s_capture_next = false;
				MTLCaptureManager* mgr = [MTLCaptureManager sharedCaptureManager];
				if ([mgr supportsDestination:MTLCaptureDestinationGPUTraceDocument])
				{
					MTLCaptureDescriptor* desc = [[MTLCaptureDescriptor new] autorelease];
					[desc setCaptureObject:m_dev.dev];
					if ([[NSFileManager defaultManager] fileExistsAtPath:path])
						[[NSFileManager defaultManager] removeItemAtPath:path error:nil];
					[desc setOutputURL:[NSURL fileURLWithPath:path]];
					[desc setDestination:MTLCaptureDestinationGPUTraceDocument];
					NSError* err = nullptr;
					[mgr startCaptureWithDescriptor:desc error:&err];
					if (err)
					{
						Console.Error("Metal Trace Capture failed: %s", [[err localizedDescription] UTF8String]);
					}
					else
					{
						Console.WriteLn("Metal Trace Capture to /tmp/PCSX2MTLCapture.gputrace started");
						frames = 2;
					}
				}
				else
				{
					Console.Error("Metal Trace Capture Failed: MTLCaptureManager doesn't support GPU trace documents! (Did you forget to run with METAL_CAPTURE_ENABLED=1?)");
				}
			}
		}
	}
}}

void MetalHostDisplay::SetVSync(VsyncMode mode)
{
	[m_layer setDisplaySyncEnabled:mode != VsyncMode::Off];
	m_vsync_mode = mode;
}

bool MetalHostDisplay::CreateImGuiContext()
{
	return true;
}

void MetalHostDisplay::DestroyImGuiContext()
{
}

bool MetalHostDisplay::UpdateImGuiFontTexture()
{
	return true;
}

bool MetalHostDisplay::GetHostRefreshRate(float* refresh_rate)
{
	return *refresh_rate != 0;
}

bool MetalHostDisplay::SetGPUTimingEnabled(bool enabled)
{
	if (enabled == m_gpu_timing_enabled)
		return true;
	if (@available(macOS 10.15, iOS 10.3, *))
	{
		std::lock_guard<std::mutex> l(m_mtx);
		m_gpu_timing_enabled = enabled;
		m_accumulated_gpu_time = 0;
		m_last_gpu_time_end = 0;
		return true;
	}
	return false;
}

float MetalHostDisplay::GetAndResetAccumulatedGPUTime()
{
	std::lock_guard<std::mutex> l(m_mtx);
	float time = m_accumulated_gpu_time * 1000;
	m_accumulated_gpu_time = 0;
	return time;
}

void MetalHostDisplay::AccumulateCommandBufferTime(id<MTLCommandBuffer> buffer)
{
	std::lock_guard<std::mutex> l(m_mtx);
	if (!m_gpu_timing_enabled)
		return;
	// We do the check before enabling m_gpu_timing_enabled
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
	// It's unlikely, but command buffers can overlap or run out of order
	// This doesn't handle every case (fully out of order), but it should at least handle overlapping
	double begin = std::max(m_last_gpu_time_end, [buffer GPUStartTime]);
	double end = [buffer GPUEndTime];
	if (end > begin)
	{
		m_accumulated_gpu_time += end - begin;
		m_last_gpu_time_end = end;
	}
#pragma clang diagnostic pop
}

#endif // __APPLE__
