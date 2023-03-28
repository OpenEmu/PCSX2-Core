/*  PCSX2 - PS2 Emulator for PCs
 *  Copyright (C) 2002-2021 PCSX2 Dev Team
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
#include "GSMetalCPPAccessible.h"
#include "GSDeviceMTL.h"

#include "Frontend/MetalHostDisplay.h"
#include "GSTextureMTL.h"
#include "GS/GSPerfMon.h"
#include "HostDisplay.h"

#ifdef __APPLE__
#include "GSMTLSharedHeader.h"

GSDevice* MakeGSDeviceMTL()
{
	return new GSDeviceMTL();
}

static constexpr simd::float2 ToSimd(const GSVector2& vec)
{
	return simd::make_float2(vec.x, vec.y);
}

bool GSDeviceMTL::UsageTracker::PrepareForAllocation(u64 last_draw, size_t amt)
{
	auto removeme = std::find_if(m_usage.begin(), m_usage.end(), [last_draw](UsageEntry usage){ return usage.drawno > last_draw; });
	if (removeme != m_usage.begin())
		m_usage.erase(m_usage.begin(), removeme);

	bool still_in_use = false;
	bool needs_wrap = m_pos + amt > m_size;
	if (!m_usage.empty())
	{
		size_t used = m_usage.front().pos;
		if (needs_wrap)
			still_in_use = used >= m_pos || used < amt;
		else
			still_in_use = used >= m_pos && used < m_pos + amt;
	}
	if (needs_wrap)
		m_pos = 0;

	return still_in_use || amt > m_size;
}

size_t GSDeviceMTL::UsageTracker::Allocate(u64 current_draw, size_t amt)
{
	if (m_usage.empty() || m_usage.back().drawno != current_draw)
		m_usage.push_back({current_draw, m_pos});
	size_t ret = m_pos;
	m_pos += amt;
	return ret;
}

void GSDeviceMTL::UsageTracker::Reset(size_t new_size)
{
	m_usage.clear();
	m_size = new_size;
	m_pos = 0;
}

GSDeviceMTL::GSDeviceMTL()
	: m_backref(std::make_shared<std::pair<std::mutex, GSDeviceMTL*>>())
	, m_dev(nil)
{
	m_backref->second = this;
}

GSDeviceMTL::~GSDeviceMTL()
{ @autoreleasepool {
	FlushEncoders();
	std::lock_guard<std::mutex> guard(m_backref->first);
	m_backref->second = nullptr;
}}

GSDeviceMTL::Map GSDeviceMTL::Allocate(UploadBuffer& buffer, size_t amt)
{
	amt = (amt + 31) & ~31ull;
	u64 last_draw = m_last_finished_draw.load(std::memory_order_acquire);
	bool needs_new = buffer.usage.PrepareForAllocation(last_draw, amt);
	if (unlikely(needs_new))
	{
		// Orphan buffer
		size_t newsize = std::max<size_t>(buffer.usage.Size() * 2, 4096);
		while (newsize < amt)
			newsize *= 2;
		MTLResourceOptions options = MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined;
		buffer.mtlbuffer = MRCTransfer([m_dev.dev newBufferWithLength:newsize options:options]);
		pxAssertRel(buffer.mtlbuffer, "Failed to allocate MTLBuffer (out of memory?)");
		buffer.buffer = [buffer.mtlbuffer contents];
		buffer.usage.Reset(newsize);
	}

	size_t pos = buffer.usage.Allocate(m_current_draw, amt);

	Map ret = {buffer.mtlbuffer, pos, reinterpret_cast<char*>(buffer.buffer) + pos};
	ASSERT(pos <= buffer.usage.Size() && "Previous code should have guaranteed there was enough space");
	return ret;
}

/// Allocate space in the given buffer for use with the given render command encoder
GSDeviceMTL::Map GSDeviceMTL::Allocate(BufferPair& buffer, size_t amt)
{
	amt = (amt + 31) & ~31ull;
	u64 last_draw = m_last_finished_draw.load(std::memory_order_acquire);
	size_t base_pos = buffer.usage.Pos();
	bool needs_new = buffer.usage.PrepareForAllocation(last_draw, amt);
	bool needs_upload = needs_new || buffer.usage.Pos() == 0;
	if (!m_dev.features.unified_memory && needs_upload)
	{
		if (base_pos != buffer.last_upload)
		{
			id<MTLBlitCommandEncoder> enc = GetVertexUploadEncoder();
			[enc copyFromBuffer:buffer.cpubuffer
			       sourceOffset:buffer.last_upload
			           toBuffer:buffer.gpubuffer
			  destinationOffset:buffer.last_upload
			               size:base_pos - buffer.last_upload];
		}
		buffer.last_upload = 0;
	}
	if (unlikely(needs_new))
	{
		// Orphan buffer
		size_t newsize = std::max<size_t>(buffer.usage.Size() * 2, 4096);
		while (newsize < amt)
			newsize *= 2;
		MTLResourceOptions options = MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined;
		buffer.cpubuffer = MRCTransfer([m_dev.dev newBufferWithLength:newsize options:options]);
		pxAssertRel(buffer.cpubuffer, "Failed to allocate MTLBuffer (out of memory?)");
		buffer.buffer = [buffer.cpubuffer contents];
		buffer.usage.Reset(newsize);
		if (!m_dev.features.unified_memory)
		{
			options = MTLResourceStorageModePrivate | MTLResourceHazardTrackingModeUntracked;
			buffer.gpubuffer = MRCTransfer([m_dev.dev newBufferWithLength:newsize options:options]);
			pxAssertRel(buffer.gpubuffer, "Failed to allocate MTLBuffer (out of memory?)");
		}
	}

	size_t pos = buffer.usage.Allocate(m_current_draw, amt);
	Map ret = {nil, pos, reinterpret_cast<char*>(buffer.buffer) + pos};
	ret.gpu_buffer = m_dev.features.unified_memory ? buffer.cpubuffer : buffer.gpubuffer;
	ASSERT(pos <= buffer.usage.Size() && "Previous code should have guaranteed there was enough space");
	return ret;
}

void GSDeviceMTL::Sync(BufferPair& buffer)
{
	if (m_dev.features.unified_memory || buffer.usage.Pos() == buffer.last_upload)
		return;

	id<MTLBlitCommandEncoder> enc = GetVertexUploadEncoder();
	[enc copyFromBuffer:buffer.cpubuffer
	       sourceOffset:buffer.last_upload
	           toBuffer:buffer.gpubuffer
	  destinationOffset:buffer.last_upload
	               size:buffer.usage.Pos() - buffer.last_upload];
	[enc updateFence:m_draw_sync_fence];
	buffer.last_upload = buffer.usage.Pos();
}

id<MTLBlitCommandEncoder> GSDeviceMTL::GetTextureUploadEncoder()
{
	if (!m_texture_upload_cmdbuf)
	{
		m_texture_upload_cmdbuf = MRCRetain([m_queue commandBuffer]);
		m_texture_upload_encoder = MRCRetain([m_texture_upload_cmdbuf blitCommandEncoder]);
		pxAssertRel(m_texture_upload_encoder, "Failed to create texture upload encoder!");
		[m_texture_upload_cmdbuf setLabel:@"Texture Upload"];
	}
	return m_texture_upload_encoder;
}

id<MTLBlitCommandEncoder> GSDeviceMTL::GetLateTextureUploadEncoder()
{
	if (!m_late_texture_upload_encoder)
	{
		EndRenderPass();
		m_late_texture_upload_encoder = MRCRetain([GetRenderCmdBuf() blitCommandEncoder]);
		pxAssertRel(m_late_texture_upload_encoder, "Failed to create late texture upload encoder!");
		[m_late_texture_upload_encoder setLabel:@"Late Texture Upload"];
		if (!m_dev.features.unified_memory)
			[m_late_texture_upload_encoder waitForFence:m_draw_sync_fence];
	}
	return m_late_texture_upload_encoder;
}

id<MTLBlitCommandEncoder> GSDeviceMTL::GetVertexUploadEncoder()
{
	if (!m_vertex_upload_cmdbuf)
	{
		m_vertex_upload_cmdbuf = MRCRetain([m_queue commandBuffer]);
		m_vertex_upload_encoder = MRCRetain([m_vertex_upload_cmdbuf blitCommandEncoder]);
		pxAssertRel(m_vertex_upload_encoder, "Failed to create vertex upload encoder!");
		[m_vertex_upload_cmdbuf setLabel:@"Vertex Upload"];
	}
	return m_vertex_upload_encoder;
}

/// Get the draw command buffer, creating a new one if it doesn't exist
id<MTLCommandBuffer> GSDeviceMTL::GetRenderCmdBuf()
{
	if (!m_current_render_cmdbuf)
	{
		m_encoders_in_current_cmdbuf = 0;
		m_current_render_cmdbuf = MRCRetain([m_queue commandBuffer]);
		pxAssertRel(m_current_render_cmdbuf, "Failed to create draw command buffer!");
		[m_current_render_cmdbuf setLabel:@"Draw"];
	}
	return m_current_render_cmdbuf;
}

id<MTLCommandBuffer> GSDeviceMTL::GetRenderCmdBufWithoutCreate()
{
	return m_current_render_cmdbuf;
}

id<MTLFence> GSDeviceMTL::GetSpinFence()
{
	return m_spin_timer ? m_spin_fence : nil;
}

void GSDeviceMTL::DrawCommandBufferFinished(u64 draw, id<MTLCommandBuffer> buffer)
{
	// We can do the update non-atomically because we only ever update under the lock
	u64 newval = std::max(draw, m_last_finished_draw.load(std::memory_order_relaxed));
	m_last_finished_draw.store(newval, std::memory_order_release);
	static_cast<MetalHostDisplay*>(g_host_display.get())->AccumulateCommandBufferTime(buffer);
}

void GSDeviceMTL::FlushEncoders()
{
	if (!m_current_render_cmdbuf)
		return;
	EndRenderPass();
	Sync(m_vertex_upload_buf);
	if (m_dev.features.unified_memory)
	{
		ASSERT(!m_vertex_upload_cmdbuf && "Should never be used!");
	}
	else if (m_vertex_upload_cmdbuf)
	{
		[m_vertex_upload_encoder endEncoding];
		[m_vertex_upload_cmdbuf commit];
		m_vertex_upload_encoder = nil;
		m_vertex_upload_cmdbuf = nil;
	}
	if (m_texture_upload_cmdbuf)
	{
		[m_texture_upload_encoder endEncoding];
		[m_texture_upload_cmdbuf commit];
		m_texture_upload_encoder = nil;
		m_texture_upload_cmdbuf = nil;
	}
	if (m_late_texture_upload_encoder)
	{
		[m_late_texture_upload_encoder endEncoding];
		m_late_texture_upload_encoder = nil;
	}
	u32 spin_cycles = 0;
	constexpr double s_to_ns = 1000000000;
	if (m_spin_timer)
	{
		u32 spin_id;
		{
			std::lock_guard<std::mutex> guard(m_backref->first);
			auto draw = m_spin_manager.DrawSubmitted(m_encoders_in_current_cmdbuf);
			u32 constant_offset = 200000 * m_spin_manager.SpinsPerUnitTime(); // 200µs
			u32 minimum_spin = 2 * constant_offset; // 400µs (200µs after subtracting constant_offset)
			u32 maximum_spin = std::max<u32>(1024, 16000000 * m_spin_manager.SpinsPerUnitTime()); // 16ms
			if (draw.recommended_spin > minimum_spin)
				spin_cycles = std::min(draw.recommended_spin - constant_offset, maximum_spin);
			spin_id = draw.id;
		}
		[m_current_render_cmdbuf addCompletedHandler:[backref = m_backref, draw = m_current_draw, spin_id](id<MTLCommandBuffer> buf)
		{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
			// Starting from kernelStartTime includes time the command buffer spent waiting to execute
			// This is useful for avoiding issues on GPUs without async compute (Intel) where spinning
			// delays the next command buffer start, which then makes the spin manager think it should spin more
			// (If a command buffer contains multiple encoders, the GPU will start before the kernel finishes,
			//  so we choose kernelStartTime over kernelEndTime)
			u64 begin = [buf kernelStartTime] * s_to_ns;
			u64 end = [buf GPUEndTime] * s_to_ns;
#pragma clang diagnostic pop
			std::lock_guard<std::mutex> guard(backref->first);
			if (GSDeviceMTL* dev = backref->second)
			{
				dev->DrawCommandBufferFinished(draw, buf);
				dev->m_spin_manager.DrawCompleted(spin_id, static_cast<u32>(begin), static_cast<u32>(end));
			}
		}];
	}
	else
	{
		[m_current_render_cmdbuf addCompletedHandler:[backref = m_backref, draw = m_current_draw](id<MTLCommandBuffer> buf)
		{
			std::lock_guard<std::mutex> guard(backref->first);
			if (GSDeviceMTL* dev = backref->second)
				dev->DrawCommandBufferFinished(draw, buf);
		}];
	}
	[m_current_render_cmdbuf commit];
	m_current_render_cmdbuf = nil;
	m_current_draw++;
	if (spin_cycles)
	{
		id<MTLCommandBuffer> spinCmdBuf = [m_queue commandBuffer];
		[spinCmdBuf setLabel:@"Spin"];
		id<MTLComputeCommandEncoder> spinCmdEncoder = [spinCmdBuf computeCommandEncoder];
		[spinCmdEncoder setLabel:@"Spin"];
		[spinCmdEncoder waitForFence:m_spin_fence];
		[spinCmdEncoder setComputePipelineState:m_spin_pipeline];
		[spinCmdEncoder setBytes:&spin_cycles length:sizeof(spin_cycles) atIndex:0];
		[spinCmdEncoder setBuffer:m_spin_buffer offset:0 atIndex:1];
		[spinCmdEncoder dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
		[spinCmdEncoder endEncoding];
		[spinCmdBuf addCompletedHandler:[backref = m_backref, spin_cycles](id<MTLCommandBuffer> buf)
		{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
			u64 begin = [buf GPUStartTime] * s_to_ns;
			u64 end = [buf GPUEndTime] * s_to_ns;
#pragma clang diagnostic pop
			std::lock_guard<std::mutex> guard(backref->first);
			if (GSDeviceMTL* dev = backref->second)
				dev->m_spin_manager.SpinCompleted(spin_cycles, static_cast<u32>(begin), static_cast<u32>(end));
		}];
		[spinCmdBuf commit];
	}
}

void GSDeviceMTL::FlushEncodersForReadback()
{
	FlushEncoders();
	if (@available(macOS 10.15, iOS 10.3, *))
	{
		if (GSConfig.HWSpinGPUForReadbacks)
		{
			m_spin_manager.ReadbackRequested();
			m_spin_timer = 30;
		}
	}
}

void GSDeviceMTL::EndRenderPass()
{
	if (m_current_render.encoder)
	{
		EndDebugGroup(m_current_render.encoder);
		if (m_spin_timer)
			[m_current_render.encoder updateFence:m_spin_fence afterStages:MTLRenderStageFragment];
		[m_current_render.encoder endEncoding];
		m_current_render.encoder = nil;
		memset(&m_current_render, 0, offsetof(MainRenderEncoder, depth_sel));
		m_current_render.depth_sel = DepthStencilSelector::NoDepth();
	}
}

void GSDeviceMTL::BeginRenderPass(NSString* name, GSTexture* color, MTLLoadAction color_load, GSTexture* depth, MTLLoadAction depth_load, GSTexture* stencil, MTLLoadAction stencil_load)
{
	GSTextureMTL* mc = static_cast<GSTextureMTL*>(color);
	GSTextureMTL* md = static_cast<GSTextureMTL*>(depth);
	GSTextureMTL* ms = static_cast<GSTextureMTL*>(stencil);
	bool needs_new = color   != m_current_render.color_target
	              || depth   != m_current_render.depth_target
	              || stencil != m_current_render.stencil_target;
	GSVector4 color_clear;
	float depth_clear=0;
	int stencil_clear=0;
	bool needs_color_clear = false;
	bool needs_depth_clear = false;
	bool needs_stencil_clear = false;
	if (mc) needs_color_clear   = mc->GetResetNeedsColorClear(color_clear);
	if (md) needs_depth_clear   = md->GetResetNeedsDepthClear(depth_clear);
	if (ms) needs_stencil_clear = ms->GetResetNeedsStencilClear(stencil_clear);
	if (needs_color_clear   && color_load   != MTLLoadActionDontCare) color_load   = MTLLoadActionClear;
	if (needs_depth_clear   && depth_load   != MTLLoadActionDontCare) depth_load   = MTLLoadActionClear;
	if (needs_stencil_clear && stencil_load != MTLLoadActionDontCare) stencil_load = MTLLoadActionClear;
	needs_new |= mc && color_load   == MTLLoadActionClear;
	needs_new |= md && depth_load   == MTLLoadActionClear;
	needs_new |= ms && stencil_load == MTLLoadActionClear;

	if (!needs_new)
	{
		if (m_current_render.name != (__bridge void*)name)
		{
			m_current_render.name = (__bridge void*)name;
			[m_current_render.encoder setLabel:name];
		}
		return;
	}

	m_encoders_in_current_cmdbuf++;

	if (m_late_texture_upload_encoder)
	{
		[m_late_texture_upload_encoder endEncoding];
		m_late_texture_upload_encoder = nullptr;
	}

	int idx = 0;
	if (mc) idx |= 1;
	if (md) idx |= 2;
	if (ms) idx |= 4;

	MTLRenderPassDescriptor* desc = m_render_pass_desc[idx];
	if (mc)
	{
		mc->m_last_write = m_current_draw;
		desc.colorAttachments[0].texture = mc->GetTexture();
		if (color_load == MTLLoadActionClear)
			desc.colorAttachments[0].clearColor = MTLClearColorMake(color_clear.r, color_clear.g, color_clear.b, color_clear.a);
		desc.colorAttachments[0].loadAction = color_load;
	}
	if (md)
	{
		md->m_last_write = m_current_draw;
		desc.depthAttachment.texture = md->GetTexture();
		if (depth_load == MTLLoadActionClear)
			desc.depthAttachment.clearDepth = depth_clear;
		desc.depthAttachment.loadAction = depth_load;
	}
	if (ms)
	{
		ms->m_last_write = m_current_draw;
		desc.stencilAttachment.texture = ms->GetTexture();
		if (stencil_load == MTLLoadActionClear)
			desc.stencilAttachment.clearStencil = stencil_clear;
		desc.stencilAttachment.loadAction = stencil_load;
	}

	EndRenderPass();
	m_current_render.encoder = MRCRetain([GetRenderCmdBuf() renderCommandEncoderWithDescriptor:desc]);
	m_current_render.name = (__bridge void*)name;
	[m_current_render.encoder setLabel:name];
	if (!m_dev.features.unified_memory)
		[m_current_render.encoder waitForFence:m_draw_sync_fence
		                          beforeStages:MTLRenderStageVertex];
	m_current_render.color_target = color;
	m_current_render.depth_target = depth;
	m_current_render.stencil_target = stencil;
	pxAssertRel(m_current_render.encoder, "Failed to create render encoder!");
}

void GSDeviceMTL::FrameCompleted()
{
	if (m_spin_timer)
		m_spin_timer--;
	m_spin_manager.NextFrame();
}

static constexpr MTLPixelFormat ConvertPixelFormat(GSTexture::Format format)
{
	switch (format)
	{
		case GSTexture::Format::PrimID:       return MTLPixelFormatR32Float;
		case GSTexture::Format::UInt32:       return MTLPixelFormatR32Uint;
		case GSTexture::Format::UInt16:       return MTLPixelFormatR16Uint;
		case GSTexture::Format::UNorm8:       return MTLPixelFormatA8Unorm;
		case GSTexture::Format::Color:        return MTLPixelFormatRGBA8Unorm;
		case GSTexture::Format::HDRColor:     return MTLPixelFormatRGBA16Unorm;
		case GSTexture::Format::DepthStencil: return MTLPixelFormatDepth32Float_Stencil8;
		case GSTexture::Format::Invalid:      return MTLPixelFormatInvalid;
		case GSTexture::Format::BC1:          return MTLPixelFormatBC1_RGBA;
		case GSTexture::Format::BC2:          return MTLPixelFormatBC2_RGBA;
		case GSTexture::Format::BC3:          return MTLPixelFormatBC3_RGBA;
		case GSTexture::Format::BC7:          return MTLPixelFormatBC7_RGBAUnorm;
	}
}

GSTexture* GSDeviceMTL::CreateSurface(GSTexture::Type type, int width, int height, int levels, GSTexture::Format format)
{ @autoreleasepool {
	MTLPixelFormat fmt = ConvertPixelFormat(format);
	pxAssertRel(format != GSTexture::Format::Invalid, "Can't create surface of this format!");

	MTLTextureDescriptor* desc = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:fmt
									 width:std::max(1, std::min(width,  m_dev.features.max_texsize))
									height:std::max(1, std::min(height, m_dev.features.max_texsize))
								 mipmapped:levels > 1];

	if (levels > 1)
		[desc setMipmapLevelCount:levels];

	[desc setStorageMode:MTLStorageModePrivate];
	switch (type)
	{
		case GSTexture::Type::Texture:
			[desc setUsage:MTLTextureUsageShaderRead];
			break;
		case GSTexture::Type::RenderTarget:
			if (m_dev.features.slow_color_compression)
				[desc setUsage:MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView]; // Force color compression off by including PixelFormatView
			else
				[desc setUsage:MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget];
			break;
		case GSTexture::Type::RWTexture:
			[desc setUsage:MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite];
			break;
		default:
			[desc setUsage:MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget];
	}

	MRCOwned<id<MTLTexture>> tex = MRCTransfer([m_dev.dev newTextureWithDescriptor:desc]);
	if (tex)
	{
		GSTextureMTL* t = new GSTextureMTL(this, tex, type, format);
		switch (type)
		{
			case GSTexture::Type::RenderTarget:
				ClearRenderTarget(t, 0);
				break;
			case GSTexture::Type::DepthStencil:
				ClearDepth(t);
				break;
			default:
				break;
		}
		return t;
	}
	else
	{
		return nullptr;
	}
}}

void GSDeviceMTL::DoMerge(GSTexture* sTex[3], GSVector4* sRect, GSTexture* dTex, GSVector4* dRect, const GSRegPMODE& PMODE, const GSRegEXTBUF& EXTBUF, const GSVector4& c, const bool linear)
{ @autoreleasepool {
	id<MTLCommandBuffer> cmdbuf = GetRenderCmdBuf();
	GSScopedDebugGroupMTL dbg(cmdbuf, @"DoMerge");

	GSVector4 full_r(0.0f, 0.0f, 1.0f, 1.0f);
	bool feedback_write_2 = PMODE.EN2 && sTex[2] != nullptr && EXTBUF.FBIN == 1;
	bool feedback_write_1 = PMODE.EN1 && sTex[2] != nullptr && EXTBUF.FBIN == 0;
	bool feedback_write_2_but_blend_bg = feedback_write_2 && PMODE.SLBG == 1;

	ClearRenderTarget(dTex, c);

	vector_float4 cb_c = { c.r, c.g, c.b, c.a };
	GSMTLConvertPSUniform cb_yuv = {};
	cb_yuv.emoda = EXTBUF.EMODA;
	cb_yuv.emodc = EXTBUF.EMODC;

	if (sTex[1] && (PMODE.SLBG == 0 || feedback_write_2_but_blend_bg))
	{
		// 2nd output is enabled and selected. Copy it to destination so we can blend it with 1st output
		// Note: value outside of dRect must contains the background color (c)
		StretchRect(sTex[1], sRect[1], dTex, dRect[1], ShaderConvert::COPY, linear);
	}

	// Save 2nd output
	if (feedback_write_2) // FIXME I'm not sure dRect[1] is always correct
		DoStretchRect(dTex, full_r, sTex[2], dRect[1], m_convert_pipeline[static_cast<int>(ShaderConvert::YUV)], linear, LoadAction::DontCareIfFull, &cb_yuv, sizeof(cb_yuv));

	if (feedback_write_2_but_blend_bg)
		ClearRenderTarget(dTex, c);

	if (sTex[0])
	{
		int idx = (PMODE.AMOD << 1) | PMODE.MMOD;
		id<MTLRenderPipelineState> pipeline = m_merge_pipeline[idx];

		// 1st output is enabled. It must be blended
		if (PMODE.MMOD == 1)
		{
			// Blend with a constant alpha
			DoStretchRect(sTex[0], sRect[0], dTex, dRect[0], pipeline, linear, LoadAction::Load, &cb_c, sizeof(cb_c));
		}
		else
		{
			// Blend with 2 * input alpha
			DoStretchRect(sTex[0], sRect[0], dTex, dRect[0], pipeline, linear, LoadAction::Load, nullptr, 0);
		}
	}

	if (feedback_write_1) // FIXME I'm not sure dRect[0] is always correct
		StretchRect(dTex, full_r, sTex[2], dRect[0], ShaderConvert::YUV, linear);
}}

void GSDeviceMTL::DoInterlace(GSTexture* sTex, const GSVector4& sRect, GSTexture* dTex, const GSVector4& dRect, ShaderInterlace shader, bool linear, const InterlaceConstantBuffer& cb)
{ @autoreleasepool {
	id<MTLCommandBuffer> cmdbuf = GetRenderCmdBuf();
	GSScopedDebugGroupMTL dbg(cmdbuf, @"DoInterlace");

	const bool can_discard = shader == ShaderInterlace::WEAVE || shader == ShaderInterlace::MAD_BUFFER;
	DoStretchRect(sTex, sRect, dTex, dRect, m_interlace_pipeline[static_cast<int>(shader)], linear, !can_discard ? LoadAction::DontCareIfFull : LoadAction::Load, &cb, sizeof(cb));
}}

void GSDeviceMTL::DoFXAA(GSTexture* sTex, GSTexture* dTex)
{
	BeginRenderPass(@"FXAA", dTex, MTLLoadActionDontCare, nullptr, MTLLoadActionDontCare);
	RenderCopy(sTex, m_fxaa_pipeline, GSVector4i(0, 0, dTex->GetSize().x, dTex->GetSize().y));
}

void GSDeviceMTL::DoShadeBoost(GSTexture* sTex, GSTexture* dTex, const float params[4])
{
	BeginRenderPass(@"ShadeBoost", dTex, MTLLoadActionDontCare, nullptr, MTLLoadActionDontCare);
	[m_current_render.encoder setFragmentBytes:params
	                                    length:sizeof(float) * 4
	                                   atIndex:GSMTLBufferIndexUniforms];
	RenderCopy(sTex, m_shadeboost_pipeline, GSVector4i(0, 0, dTex->GetSize().x, dTex->GetSize().y));
}

bool GSDeviceMTL::DoCAS(GSTexture* sTex, GSTexture* dTex, bool sharpen_only, const std::array<u32, NUM_CAS_CONSTANTS>& constants)
{ @autoreleasepool {
	static constexpr int threadGroupWorkRegionDim = 16;
	const int dispatchX = (dTex->GetWidth() + (threadGroupWorkRegionDim - 1)) / threadGroupWorkRegionDim;
	const int dispatchY = (dTex->GetHeight() + (threadGroupWorkRegionDim - 1)) / threadGroupWorkRegionDim;
	static_assert(sizeof(constants) == sizeof(GSMTLCASPSUniform));

	EndRenderPass();
	id<MTLComputeCommandEncoder> enc = [GetRenderCmdBuf() computeCommandEncoder];
	[enc setLabel:@"CAS"];
	[enc setComputePipelineState:m_cas_pipeline[sharpen_only]];
	[enc setTexture:static_cast<GSTextureMTL*>(sTex)->GetTexture() atIndex:0];
	[enc setTexture:static_cast<GSTextureMTL*>(dTex)->GetTexture() atIndex:1];
	[enc setBytes:&constants length:sizeof(constants) atIndex:GSMTLBufferIndexUniforms];
	[enc dispatchThreadgroups:MTLSizeMake(dispatchX, dispatchY, 1)
	    threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
	[enc endEncoding];
	return true;
}}

MRCOwned<id<MTLFunction>> GSDeviceMTL::LoadShader(NSString* name)
{
	NSError* err = nil;
	MRCOwned<id<MTLFunction>> fn = MRCTransfer([m_dev.shaders newFunctionWithName:name constantValues:m_fn_constants error:&err]);
	if (unlikely(err))
	{
		NSString* msg = [NSString stringWithFormat:@"Failed to load shader %@: %@", name, [err localizedDescription]];
		Console.Error("%s", [msg UTF8String]);
		throw GSRecoverableError();
	}
	return fn;
}

MRCOwned<id<MTLRenderPipelineState>> GSDeviceMTL::MakePipeline(MTLRenderPipelineDescriptor* desc, id<MTLFunction> vertex, id<MTLFunction> fragment, NSString* name)
{
	[desc setLabel:name];
	[desc setVertexFunction:vertex];
	[desc setFragmentFunction:fragment];
	NSError* err;
	MRCOwned<id<MTLRenderPipelineState>> res = MRCTransfer([m_dev.dev newRenderPipelineStateWithDescriptor:desc error:&err]);
	if (unlikely(err))
	{
		NSString* msg = [NSString stringWithFormat:@"Failed to create pipeline %@: %@", name, [err localizedDescription]];
		Console.Error("%s", [msg UTF8String]);
		throw GSRecoverableError();
	}
	return res;
}

MRCOwned<id<MTLComputePipelineState>> GSDeviceMTL::MakeComputePipeline(id<MTLFunction> compute, NSString* name)
{
	MRCOwned<MTLComputePipelineDescriptor*> desc = MRCTransfer([MTLComputePipelineDescriptor new]);
	[desc setLabel:name];
	[desc setComputeFunction:compute];
	NSError* err;
	MRCOwned<id<MTLComputePipelineState>> res = MRCTransfer([m_dev.dev
		newComputePipelineStateWithDescriptor:desc
		                              options:0
		                           reflection:nil
		                                error:&err]);
	if (unlikely(err))
	{
		NSString* msg = [NSString stringWithFormat:@"Failed to create pipeline %@: %@", name, [err localizedDescription]];
		Console.Error("%s", [msg UTF8String]);
		throw GSRecoverableError();
	}
	return res;
}

static void applyAttribute(MTLVertexDescriptor* desc, NSUInteger idx, MTLVertexFormat fmt, NSUInteger offset, NSUInteger buffer_index)
{
	MTLVertexAttributeDescriptor* attrs = desc.attributes[idx];
	attrs.format = fmt;
	attrs.offset = offset;
	attrs.bufferIndex = buffer_index;
}

static void setFnConstantB(MTLFunctionConstantValues* fc, bool value, GSMTLFnConstants constant)
{
	[fc setConstantValue:&value type:MTLDataTypeBool atIndex:constant];
}

static void setFnConstantI(MTLFunctionConstantValues* fc, unsigned int value, GSMTLFnConstants constant)
{
	[fc setConstantValue:&value type:MTLDataTypeUInt atIndex:constant];
}

bool GSDeviceMTL::Create()
{ @autoreleasepool {
	if (!GSDevice::Create())
		return false;

	if (g_host_display->GetRenderAPI() != RenderAPI::Metal)
		return false;

	if (!g_host_display->HasDevice() || !g_host_display->HasSurface())
		return false;
	m_dev = *static_cast<const GSMTLDevice*>(g_host_display->GetDevice());
	m_queue = MRCRetain((__bridge id<MTLCommandQueue>)g_host_display->GetContext());
	MTLPixelFormat layer_px_fmt = [(__bridge CAMetalLayer*)g_host_display->GetSurface() pixelFormat];

	m_features.broken_point_sampler = [[m_dev.dev name] containsString:@"AMD"];
	m_features.geometry_shader = false;
	m_features.vs_expand = true;
	m_features.primitive_id = m_dev.features.primid;
	m_features.texture_barrier = true;
	m_features.provoking_vertex_last = false;
	m_features.point_expand = true;
	m_features.line_expand = false;
	m_features.prefer_new_textures = true;
	m_features.dxt_textures = true;
	m_features.bptc_textures = true;
	m_features.framebuffer_fetch = m_dev.features.framebuffer_fetch;
	m_features.dual_source_blend = true;
	m_features.clip_control = true;
	m_features.stencil_buffer = true;
	m_features.cas_sharpening = true;

	try
	{
		// Init metal stuff
		m_fn_constants = MRCTransfer([MTLFunctionConstantValues new]);
		setFnConstantB(m_fn_constants, m_dev.features.framebuffer_fetch, GSMTLConstantIndex_FRAMEBUFFER_FETCH);

		m_draw_sync_fence = MRCTransfer([m_dev.dev newFence]);
		[m_draw_sync_fence setLabel:@"Draw Sync Fence"];
		m_spin_fence = MRCTransfer([m_dev.dev newFence]);
		[m_spin_fence setLabel:@"Spin Fence"];
		constexpr MTLResourceOptions spin_opts = MTLResourceStorageModePrivate | MTLResourceHazardTrackingModeUntracked;
		m_spin_buffer = MRCTransfer([m_dev.dev newBufferWithLength:4 options:spin_opts]);
		[m_spin_buffer setLabel:@"Spin Buffer"];
		id<MTLCommandBuffer> initCommands = [m_queue commandBuffer];
		id<MTLBlitCommandEncoder> clearSpinBuffer = [initCommands blitCommandEncoder];
		[clearSpinBuffer fillBuffer:m_spin_buffer range:NSMakeRange(0, 4) value:0];
		[clearSpinBuffer updateFence:m_spin_fence];
		[clearSpinBuffer endEncoding];
		m_spin_pipeline = MakeComputePipeline(LoadShader(@"waste_time"), @"waste_time");

		for (int sharpen_only = 0; sharpen_only < 2; sharpen_only++)
		{
			setFnConstantB(m_fn_constants, sharpen_only, GSMTLConstantIndex_CAS_SHARPEN_ONLY);
			NSString* shader = m_dev.features.has_fast_half ? @"CASHalf" : @"CASFloat";
			m_cas_pipeline[sharpen_only] = MakeComputePipeline(LoadShader(shader), sharpen_only ? @"CAS Sharpen" : @"CAS Upscale");
		}

		m_hw_vertex = MRCTransfer([MTLVertexDescriptor new]);
		[[[m_hw_vertex layouts] objectAtIndexedSubscript:GSMTLBufferIndexHWVertices] setStride:sizeof(GSVertex)];
		applyAttribute(m_hw_vertex, GSMTLAttributeIndexST, MTLVertexFormatFloat2,           offsetof(GSVertex, ST),      GSMTLBufferIndexHWVertices);
		applyAttribute(m_hw_vertex, GSMTLAttributeIndexC,  MTLVertexFormatUChar4,           offsetof(GSVertex, RGBAQ.R), GSMTLBufferIndexHWVertices);
		applyAttribute(m_hw_vertex, GSMTLAttributeIndexQ,  MTLVertexFormatFloat,            offsetof(GSVertex, RGBAQ.Q), GSMTLBufferIndexHWVertices);
		applyAttribute(m_hw_vertex, GSMTLAttributeIndexXY, MTLVertexFormatUShort2,          offsetof(GSVertex, XYZ.X),   GSMTLBufferIndexHWVertices);
		applyAttribute(m_hw_vertex, GSMTLAttributeIndexZ,  MTLVertexFormatUInt,             offsetof(GSVertex, XYZ.Z),   GSMTLBufferIndexHWVertices);
		applyAttribute(m_hw_vertex, GSMTLAttributeIndexUV, MTLVertexFormatUShort2,          offsetof(GSVertex, UV),      GSMTLBufferIndexHWVertices);
		applyAttribute(m_hw_vertex, GSMTLAttributeIndexF,  MTLVertexFormatUChar4Normalized, offsetof(GSVertex, FOG),     GSMTLBufferIndexHWVertices);

		for (auto& desc : m_render_pass_desc)
		{
			desc = MRCTransfer([MTLRenderPassDescriptor new]);
			[[desc   depthAttachment] setStoreAction:MTLStoreActionStore];
			[[desc stencilAttachment] setStoreAction:MTLStoreActionStore];
		}

		// Init samplers
		MTLSamplerDescriptor* sdesc = [[MTLSamplerDescriptor new] autorelease];
		for (size_t i = 0; i < std::size(m_sampler_hw); i++)
		{
			GSHWDrawConfig::SamplerSelector sel;
			sel.key = i;
			const char* minname = sel.biln ? "Ln" : "Pt";
			const char* magname = minname;
			sdesc.minFilter = sel.biln ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
			sdesc.magFilter = sel.biln ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
			switch (static_cast<GS_MIN_FILTER>(sel.triln))
			{
				case GS_MIN_FILTER::Nearest:
				case GS_MIN_FILTER::Linear:
					sdesc.mipFilter = MTLSamplerMipFilterNotMipmapped;
					break;
				case GS_MIN_FILTER::Nearest_Mipmap_Nearest:
					minname = "PtPt";
					sdesc.minFilter = MTLSamplerMinMagFilterNearest;
					sdesc.mipFilter = MTLSamplerMipFilterNearest;
					break;
				case GS_MIN_FILTER::Nearest_Mipmap_Linear:
					minname = "PtLn";
					sdesc.minFilter = MTLSamplerMinMagFilterNearest;
					sdesc.mipFilter = MTLSamplerMipFilterLinear;
					break;
				case GS_MIN_FILTER::Linear_Mipmap_Nearest:
					minname = "LnPt";
					sdesc.minFilter = MTLSamplerMinMagFilterLinear;
					sdesc.mipFilter = MTLSamplerMipFilterNearest;
					break;
				case GS_MIN_FILTER::Linear_Mipmap_Linear:
					minname = "LnLn";
					sdesc.minFilter = MTLSamplerMinMagFilterLinear;
					sdesc.mipFilter = MTLSamplerMipFilterLinear;
					break;
			}

			const char* taudesc = sel.tau ? "Repeat" : "Clamp";
			const char* tavdesc = sel.tav == sel.tau ? "" : sel.tav ? "Repeat" : "Clamp";
			sdesc.sAddressMode = sel.tau ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
			sdesc.tAddressMode = sel.tav ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
			sdesc.rAddressMode = MTLSamplerAddressModeClampToEdge;

			sdesc.maxAnisotropy = GSConfig.MaxAnisotropy && sel.aniso ? GSConfig.MaxAnisotropy : 1;
			sdesc.lodMaxClamp = sel.lodclamp ? 0.25f : FLT_MAX;

			[sdesc setLabel:[NSString stringWithFormat:@"%s%s %s%s", taudesc, tavdesc, magname, minname]];
			m_sampler_hw[i] = MRCTransfer([m_dev.dev newSamplerStateWithDescriptor:sdesc]);
		}

		// Init depth stencil states
		MTLDepthStencilDescriptor* dssdesc = [[MTLDepthStencilDescriptor new] autorelease];
		MTLStencilDescriptor* stencildesc = [[MTLStencilDescriptor new] autorelease];
		stencildesc.stencilCompareFunction = MTLCompareFunctionAlways;
		stencildesc.depthFailureOperation = MTLStencilOperationKeep;
		stencildesc.stencilFailureOperation = MTLStencilOperationKeep;
		stencildesc.depthStencilPassOperation = MTLStencilOperationReplace;
		dssdesc.frontFaceStencil = stencildesc;
		dssdesc.backFaceStencil = stencildesc;
		[dssdesc setLabel:@"Stencil Write"];
		m_dss_stencil_write = MRCTransfer([m_dev.dev newDepthStencilStateWithDescriptor:dssdesc]);
		dssdesc.frontFaceStencil.depthStencilPassOperation = MTLStencilOperationZero;
		dssdesc.backFaceStencil.depthStencilPassOperation = MTLStencilOperationZero;
		[dssdesc setLabel:@"Stencil Zero"];
		m_dss_stencil_zero = MRCTransfer([m_dev.dev newDepthStencilStateWithDescriptor:dssdesc]);
		stencildesc.stencilCompareFunction = MTLCompareFunctionEqual;
		stencildesc.readMask = 1;
		stencildesc.writeMask = 1;
		for (size_t i = 0; i < std::size(m_dss_hw); i++)
		{
			GSHWDrawConfig::DepthStencilSelector sel;
			sel.key = i;
			if (sel.date)
			{
				if (sel.date_one)
					stencildesc.depthStencilPassOperation = MTLStencilOperationZero;
				else
					stencildesc.depthStencilPassOperation = MTLStencilOperationKeep;
				dssdesc.frontFaceStencil = stencildesc;
				dssdesc.backFaceStencil = stencildesc;
			}
			else
			{
				dssdesc.frontFaceStencil = nil;
				dssdesc.backFaceStencil = nil;
			}
			dssdesc.depthWriteEnabled = sel.zwe ? YES : NO;
			static constexpr MTLCompareFunction ztst[] =
			{
				MTLCompareFunctionNever,
				MTLCompareFunctionAlways,
				MTLCompareFunctionGreaterEqual,
				MTLCompareFunctionGreater,
			};
			static constexpr const char* ztstname[] =
			{
				"DepthNever",
				"DepthAlways",
				"DepthGEq",
				"DepthEq",
			};
			const char* datedesc = sel.date ? (sel.date_one ? " DATE_ONE" : " DATE") : "";
			const char* zwedesc = sel.zwe ? " ZWE" : "";
			dssdesc.depthCompareFunction = ztst[sel.ztst];
			[dssdesc setLabel:[NSString stringWithFormat:@"%s%s%s", ztstname[sel.ztst], zwedesc, datedesc]];
			m_dss_hw[i] = MRCTransfer([m_dev.dev newDepthStencilStateWithDescriptor:dssdesc]);
		}

		// Init HW Vertex Shaders
		for (size_t i = 0; i < std::size(m_hw_vs); i++)
		{
			VSSelector sel;
			sel.key = i;
			if (sel.point_size && sel.expand != GSMTLExpandType::None)
				continue;
			setFnConstantB(m_fn_constants, sel.fst,        GSMTLConstantIndex_FST);
			setFnConstantB(m_fn_constants, sel.iip,        GSMTLConstantIndex_IIP);
			setFnConstantB(m_fn_constants, sel.point_size, GSMTLConstantIndex_VS_POINT_SIZE);
			NSString* shader = @"vs_main";
			if (sel.expand != GSMTLExpandType::None)
			{
				setFnConstantI(m_fn_constants, static_cast<u32>(sel.expand), GSMTLConstantIndex_VS_EXPAND_TYPE);
				shader = @"vs_main_expand";
			}
			m_hw_vs[i] = LoadShader(shader);
		}

		// Init pipelines
		auto vs_convert = LoadShader(@"vs_convert");
		auto fs_triangle = LoadShader(@"fs_triangle");
		auto ps_copy = LoadShader(@"ps_copy");
		auto pdesc = [[MTLRenderPipelineDescriptor new] autorelease];
		// FS Triangle Pipelines
		pdesc.colorAttachments[0].pixelFormat = ConvertPixelFormat(GSTexture::Format::Color);
		m_hdr_resolve_pipeline = MakePipeline(pdesc, fs_triangle, LoadShader(@"ps_hdr_resolve"), @"HDR Resolve");
		m_fxaa_pipeline = MakePipeline(pdesc, fs_triangle, LoadShader(@"ps_fxaa"), @"fxaa");
		m_shadeboost_pipeline = MakePipeline(pdesc, fs_triangle, LoadShader(@"ps_shadeboost"), @"shadeboost");
		m_clut_pipeline[0] = MakePipeline(pdesc, fs_triangle, LoadShader(@"ps_convert_clut_4"), @"4-bit CLUT Update");
		m_clut_pipeline[1] = MakePipeline(pdesc, fs_triangle, LoadShader(@"ps_convert_clut_8"), @"8-bit CLUT Update");
		pdesc.colorAttachments[0].pixelFormat = ConvertPixelFormat(GSTexture::Format::HDRColor);
		m_hdr_init_pipeline = MakePipeline(pdesc, fs_triangle, LoadShader(@"ps_hdr_init"), @"HDR Init");
		pdesc.colorAttachments[0].pixelFormat = MTLPixelFormatInvalid;
		pdesc.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
		m_datm_pipeline[0] = MakePipeline(pdesc, fs_triangle, LoadShader(@"ps_datm0"), @"datm0");
		m_datm_pipeline[1] = MakePipeline(pdesc, fs_triangle, LoadShader(@"ps_datm1"), @"datm1");
		m_stencil_clear_pipeline = MakePipeline(pdesc, fs_triangle, nil, @"Stencil Clear");
		pdesc.colorAttachments[0].pixelFormat = ConvertPixelFormat(GSTexture::Format::PrimID);
		pdesc.stencilAttachmentPixelFormat = MTLPixelFormatInvalid;
		pdesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
		m_primid_init_pipeline[1][0] = MakePipeline(pdesc, fs_triangle, LoadShader(@"ps_primid_init_datm0"), @"PrimID DATM0 Clear");
		m_primid_init_pipeline[1][1] = MakePipeline(pdesc, fs_triangle, LoadShader(@"ps_primid_init_datm1"), @"PrimID DATM1 Clear");
		pdesc.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
		m_primid_init_pipeline[0][0] = MakePipeline(pdesc, fs_triangle, LoadShader(@"ps_primid_init_datm0"), @"PrimID DATM0 Clear");
		m_primid_init_pipeline[0][1] = MakePipeline(pdesc, fs_triangle, LoadShader(@"ps_primid_init_datm1"), @"PrimID DATM1 Clear");

		pdesc.colorAttachments[0].pixelFormat = ConvertPixelFormat(GSTexture::Format::Color);
		applyAttribute(pdesc.vertexDescriptor, 0, MTLVertexFormatFloat2, offsetof(ConvertShaderVertex, pos),    0);
		applyAttribute(pdesc.vertexDescriptor, 1, MTLVertexFormatFloat2, offsetof(ConvertShaderVertex, texpos), 0);
		pdesc.vertexDescriptor.layouts[0].stride = sizeof(ConvertShaderVertex);

		for (size_t i = 0; i < std::size(m_interlace_pipeline); i++)
		{
			NSString* name = [NSString stringWithFormat:@"ps_interlace%zu", i];
			m_interlace_pipeline[i] = MakePipeline(pdesc, vs_convert, LoadShader(name), name);
		}
		for (size_t i = 0; i < std::size(m_convert_pipeline); i++)
		{
			ShaderConvert conv = static_cast<ShaderConvert>(i);
			NSString* name = [NSString stringWithCString:shaderName(conv) encoding:NSUTF8StringEncoding];
			switch (conv)
			{
				case ShaderConvert::COPY:
				case ShaderConvert::Count:
				case ShaderConvert::DATM_0:
				case ShaderConvert::DATM_1:
				case ShaderConvert::CLUT_4:
				case ShaderConvert::CLUT_8:
				case ShaderConvert::HDR_INIT:
				case ShaderConvert::HDR_RESOLVE:
					continue;
				case ShaderConvert::FLOAT32_TO_32_BITS:
					pdesc.colorAttachments[0].pixelFormat = ConvertPixelFormat(GSTexture::Format::UInt32);
					pdesc.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
					break;
				case ShaderConvert::FLOAT32_TO_16_BITS:
				case ShaderConvert::RGBA8_TO_16_BITS:
					pdesc.colorAttachments[0].pixelFormat = ConvertPixelFormat(GSTexture::Format::UInt16);
					pdesc.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
					break;
				case ShaderConvert::DEPTH_COPY:
				case ShaderConvert::RGBA8_TO_FLOAT32:
				case ShaderConvert::RGBA8_TO_FLOAT24:
				case ShaderConvert::RGBA8_TO_FLOAT16:
				case ShaderConvert::RGB5A1_TO_FLOAT16:
				case ShaderConvert::RGBA8_TO_FLOAT32_BILN:
				case ShaderConvert::RGBA8_TO_FLOAT24_BILN:
				case ShaderConvert::RGBA8_TO_FLOAT16_BILN:
				case ShaderConvert::RGB5A1_TO_FLOAT16_BILN:
					pdesc.colorAttachments[0].pixelFormat = MTLPixelFormatInvalid;
					pdesc.depthAttachmentPixelFormat = ConvertPixelFormat(GSTexture::Format::DepthStencil);
					break;
				case ShaderConvert::RGBA_TO_8I: // Yes really
				case ShaderConvert::TRANSPARENCY_FILTER:
				case ShaderConvert::FLOAT32_TO_RGBA8:
				case ShaderConvert::FLOAT16_TO_RGB5A1:
				case ShaderConvert::YUV:
					pdesc.colorAttachments[0].pixelFormat = ConvertPixelFormat(GSTexture::Format::Color);
					pdesc.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
					break;
			}
			m_convert_pipeline[i] = MakePipeline(pdesc, vs_convert, LoadShader(name), name);
		}
		pdesc.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
		for (size_t i = 0; i < std::size(m_present_pipeline); i++)
		{
			PresentShader conv = static_cast<PresentShader>(i);
			NSString* name = [NSString stringWithCString:shaderName(conv) encoding:NSUTF8StringEncoding];
			pdesc.colorAttachments[0].pixelFormat = layer_px_fmt;
			m_present_pipeline[i] = MakePipeline(pdesc, vs_convert, LoadShader(name), [NSString stringWithFormat:@"present_%s", shaderName(conv) + 3]);
		}
		pdesc.colorAttachments[0].pixelFormat = ConvertPixelFormat(GSTexture::Format::Color);
		m_convert_pipeline_copy[0] = MakePipeline(pdesc, vs_convert, ps_copy, @"copy_color");
		pdesc.colorAttachments[0].pixelFormat = ConvertPixelFormat(GSTexture::Format::HDRColor);
		m_convert_pipeline_copy[1] = MakePipeline(pdesc, vs_convert, ps_copy, @"copy_hdr");

		pdesc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
		for (size_t i = 0; i < std::size(m_convert_pipeline_copy_mask); i++)
		{
			MTLColorWriteMask mask = MTLColorWriteMaskNone;
			if (i & 1) mask |= MTLColorWriteMaskRed;
			if (i & 2) mask |= MTLColorWriteMaskGreen;
			if (i & 4) mask |= MTLColorWriteMaskBlue;
			if (i & 8) mask |= MTLColorWriteMaskAlpha;
			NSString* name = [NSString stringWithFormat:@"copy_%s%s%s%s", i & 1 ? "r" : "", i & 2 ? "g" : "", i & 4 ? "b" : "", i & 8 ? "a" : ""];
			pdesc.colorAttachments[0].writeMask = mask;
			m_convert_pipeline_copy_mask[i] = MakePipeline(pdesc, vs_convert, ps_copy, name);
		}

		pdesc.colorAttachments[0].blendingEnabled = YES;
		pdesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
		pdesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pdesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
		for (size_t i = 0; i < std::size(m_merge_pipeline); i++)
		{
			bool mmod = i & 1;
			bool amod = i & 2;
			NSString* name = [NSString stringWithFormat:@"ps_merge%zu", mmod];
			NSString* pipename = [NSString stringWithFormat:@"Merge%s%s", mmod ? " MMOD" : "", amod ? " AMOD" : ""];
			pdesc.colorAttachments[0].writeMask = amod ? MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue : MTLColorWriteMaskAll;
			m_merge_pipeline[i] = MakePipeline(pdesc, vs_convert, LoadShader(name), pipename);
		}
		pdesc.colorAttachments[0].writeMask = MTLColorWriteMaskAll;

		pdesc.colorAttachments[0].pixelFormat = layer_px_fmt;

		[initCommands commit];
	}
	catch (GSRecoverableError&)
	{
		return false;
	}
	return true;
}}

void GSDeviceMTL::ClearRenderTarget(GSTexture* t, const GSVector4& c)
{
	if (!t) return;
	static_cast<GSTextureMTL*>(t)->RequestColorClear(c);
}

void GSDeviceMTL::ClearRenderTarget(GSTexture* t, uint32 c)
{
	GSVector4 color = GSVector4::rgba32(c) * (1.f / 255.f);
	ClearRenderTarget(t, color);
}

void GSDeviceMTL::ClearDepth(GSTexture* t)
{
	if (!t) return;
	static_cast<GSTextureMTL*>(t)->RequestDepthClear(0);
}

void GSDeviceMTL::ClearStencil(GSTexture* t, uint8 c)
{
	if (!t) return;
	static_cast<GSTextureMTL*>(t)->RequestStencilClear(c);
}

std::unique_ptr<GSDownloadTexture> GSDeviceMTL::CreateDownloadTexture(u32 width, u32 height, GSTexture::Format format)
{
	return GSDownloadTextureMTL::Create(this, width, height, format);
}

void GSDeviceMTL::CopyRect(GSTexture* sTex, GSTexture* dTex, const GSVector4i& r, u32 destX, u32 destY)
{ @autoreleasepool {
	g_perfmon.Put(GSPerfMon::TextureCopies, 1);

	GSTextureMTL* sT = static_cast<GSTextureMTL*>(sTex);
	GSTextureMTL* dT = static_cast<GSTextureMTL*>(dTex);

	// Process clears
	GSVector2i dsize = dTex->GetSize();
	if (r.width() < dsize.x || r.height() < dsize.y)
		dT->FlushClears();
	else
		dT->InvalidateClears();

	EndRenderPass();

	sT->m_last_read  = m_current_draw;
	dT->m_last_write = m_current_draw;

	id<MTLCommandBuffer> cmdbuf = GetRenderCmdBuf();
	id<MTLBlitCommandEncoder> encoder = [cmdbuf blitCommandEncoder];
	[encoder setLabel:@"CopyRect"];
	[encoder copyFromTexture:sT->GetTexture()
	             sourceSlice:0
	             sourceLevel:0
	            sourceOrigin:MTLOriginMake(r.x, r.y, 0)
	              sourceSize:MTLSizeMake(r.width(), r.height(), 1)
	               toTexture:dT->GetTexture()
	        destinationSlice:0
	        destinationLevel:0
	       destinationOrigin:MTLOriginMake((int)destX, (int)destY, 0)];
	[encoder endEncoding];
}}

void GSDeviceMTL::DoStretchRect(GSTexture* sTex, const GSVector4& sRect, GSTexture* dTex, const GSVector4& dRect, id<MTLRenderPipelineState> pipeline, bool linear, LoadAction load_action, const void* frag_uniform, size_t frag_uniform_len)
{
	FlushClears(sTex);

	GSTextureMTL* sT = static_cast<GSTextureMTL*>(sTex);
	GSTextureMTL* dT = static_cast<GSTextureMTL*>(dTex);

	GSVector2i ds = dT->GetSize();

	bool covers_target = static_cast<int>(dRect.x) <= 0
	                  && static_cast<int>(dRect.y) <= 0
	                  && static_cast<int>(dRect.z) >= ds.x
	                  && static_cast<int>(dRect.w) >= ds.y;
	bool dontcare = load_action == LoadAction::DontCare || (load_action == LoadAction::DontCareIfFull && covers_target);
	MTLLoadAction action = dontcare ? MTLLoadActionDontCare : MTLLoadActionLoad;

	if (dT->GetFormat() == GSTexture::Format::DepthStencil)
		BeginRenderPass(@"StretchRect", nullptr, MTLLoadActionDontCare, dT, action);
	else
		BeginRenderPass(@"StretchRect", dT, action, nullptr, MTLLoadActionDontCare);

	FlushDebugEntries(m_current_render.encoder);
	MREClearScissor();
	DepthStencilSelector dsel;
	dsel.ztst = ZTST_ALWAYS;
	dsel.zwe = dT->GetFormat() == GSTexture::Format::DepthStencil;
	MRESetDSS(dsel);

	MRESetPipeline(pipeline);
	MRESetTexture(sT, GSMTLTextureIndexNonHW);

	if (frag_uniform && frag_uniform_len)
		[m_current_render.encoder setFragmentBytes:frag_uniform length:frag_uniform_len atIndex:GSMTLBufferIndexUniforms];

	MRESetSampler(linear ? SamplerSelector::Linear() : SamplerSelector::Point());

	DrawStretchRect(sRect, dRect, ds);
}

void GSDeviceMTL::DrawStretchRect(const GSVector4& sRect, const GSVector4& dRect, const GSVector2i& ds)
{
	float left = dRect.x * 2 / ds.x - 1.0f;
	float right = dRect.z * 2 / ds.x - 1.0f;
	float top = 1.0f - dRect.y * 2 / ds.y;
	float bottom = 1.0f - dRect.w * 2 / ds.y;

	ConvertShaderVertex vertices[] =
	{
		{{left,  top},    {sRect.x, sRect.y}},
		{{right, top},    {sRect.z, sRect.y}},
		{{left,  bottom}, {sRect.x, sRect.w}},
		{{right, bottom}, {sRect.z, sRect.w}}
	};

	[m_current_render.encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:GSMTLBufferIndexVertices];

	[m_current_render.encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
	                             vertexStart:0
	                             vertexCount:4];
	g_perfmon.Put(GSPerfMon::DrawCalls, 1);
}

void GSDeviceMTL::RenderCopy(GSTexture* sTex, id<MTLRenderPipelineState> pipeline, const GSVector4i& rect)
{
	// FS Triangle encoder uses vertex ID alone to make a FS triangle, which we then scissor to the desired rectangle
	MRESetScissor(rect);
	MRESetPipeline(pipeline);
	MRESetTexture(sTex, GSMTLTextureIndexNonHW);
	[m_current_render.encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	g_perfmon.Put(GSPerfMon::DrawCalls, 1);
}

void GSDeviceMTL::StretchRect(GSTexture* sTex, const GSVector4& sRect, GSTexture* dTex, const GSVector4& dRect, ShaderConvert shader, bool linear)
{ @autoreleasepool {
	id<MTLRenderPipelineState> pipeline;

	pxAssert(linear ? SupportsBilinear(shader) : SupportsNearest(shader));

	if (shader == ShaderConvert::COPY)
		pipeline = m_convert_pipeline_copy[dTex->GetFormat() == GSTexture::Format::Color ? 0 : 1];
	else
		pipeline = m_convert_pipeline[static_cast<int>(shader)];

	if (!pipeline)
		[NSException raise:@"StretchRect Missing Pipeline" format:@"No pipeline for %d", static_cast<int>(shader)];

	DoStretchRect(sTex, sRect, dTex, dRect, pipeline, linear, LoadAction::DontCareIfFull, nullptr, 0);
}}

void GSDeviceMTL::StretchRect(GSTexture* sTex, const GSVector4& sRect, GSTexture* dTex, const GSVector4& dRect, bool red, bool green, bool blue, bool alpha)
{ @autoreleasepool {
	int sel = 0;
	if (red)   sel |= 1;
	if (green) sel |= 2;
	if (blue)  sel |= 4;
	if (alpha) sel |= 8;

	id<MTLRenderPipelineState> pipeline = m_convert_pipeline_copy_mask[sel];

	DoStretchRect(sTex, sRect, dTex, dRect, pipeline, false, sel == 15 ? LoadAction::DontCareIfFull : LoadAction::Load, nullptr, 0);
}}

static_assert(sizeof(DisplayConstantBuffer) == sizeof(GSMTLPresentPSUniform));
static_assert(offsetof(DisplayConstantBuffer, SourceRect)          == offsetof(GSMTLPresentPSUniform, source_rect));
static_assert(offsetof(DisplayConstantBuffer, TargetRect)          == offsetof(GSMTLPresentPSUniform, target_rect));
static_assert(offsetof(DisplayConstantBuffer, TargetSize)          == offsetof(GSMTLPresentPSUniform, target_size));
static_assert(offsetof(DisplayConstantBuffer, TargetResolution)    == offsetof(GSMTLPresentPSUniform, target_resolution));
static_assert(offsetof(DisplayConstantBuffer, RcpTargetResolution) == offsetof(GSMTLPresentPSUniform, rcp_target_resolution));
static_assert(offsetof(DisplayConstantBuffer, SourceResolution)    == offsetof(GSMTLPresentPSUniform, source_resolution));
static_assert(offsetof(DisplayConstantBuffer, RcpSourceResolution) == offsetof(GSMTLPresentPSUniform, rcp_source_resolution));
static_assert(offsetof(DisplayConstantBuffer, TimeAndPad.x)        == offsetof(GSMTLPresentPSUniform, time));

void GSDeviceMTL::PresentRect(GSTexture* sTex, const GSVector4& sRect, GSTexture* dTex, const GSVector4& dRect, PresentShader shader, float shaderTime, bool linear)
{ @autoreleasepool {
	GSVector2i ds = dTex ? dTex->GetSize() : GSVector2i(g_host_display->GetWindowWidth(), g_host_display->GetWindowHeight());
	DisplayConstantBuffer cb;
	cb.SetSource(sRect, sTex->GetSize());
	cb.SetTarget(dRect, ds);
	cb.SetTime(shaderTime);
	id<MTLRenderPipelineState> pipe = m_present_pipeline[static_cast<int>(shader)];

	if (dTex)
	{
		DoStretchRect(sTex, sRect, dTex, dRect, pipe, linear, LoadAction::DontCareIfFull, &cb, sizeof(cb));
	}
	else
	{
		// !dTex → Use current draw encoder
		[m_current_render.encoder setRenderPipelineState:pipe];
		[m_current_render.encoder setFragmentSamplerState:m_sampler_hw[linear ? SamplerSelector::Linear().key : SamplerSelector::Point().key] atIndex:0];
		[m_current_render.encoder setFragmentTexture:static_cast<GSTextureMTL*>(sTex)->GetTexture() atIndex:0];
		[m_current_render.encoder setFragmentBytes:&cb length:sizeof(cb) atIndex:GSMTLBufferIndexUniforms];
		DrawStretchRect(sRect, dRect, ds);
	}
}}

void GSDeviceMTL::UpdateCLUTTexture(GSTexture* sTex, float sScale, u32 offsetX, u32 offsetY, GSTexture* dTex, u32 dOffset, u32 dSize)
{
	GSMTLCLUTConvertPSUniform uniform = { sScale, {offsetX, offsetY}, dOffset };

	const bool is_clut4 = dSize == 16;
	const GSVector4i dRect(0, 0, dSize, 1);

	BeginRenderPass(@"CLUT Update", dTex, MTLLoadActionDontCare, nullptr, MTLLoadActionDontCare);
	[m_current_render.encoder setFragmentBytes:&uniform length:sizeof(uniform) atIndex:GSMTLBufferIndexUniforms];
	RenderCopy(sTex, m_clut_pipeline[!is_clut4], dRect);
}

void GSDeviceMTL::ConvertToIndexedTexture(GSTexture* sTex, float sScale, u32 offsetX, u32 offsetY, u32 SBW, u32 SPSM, GSTexture* dTex, u32 DBW, u32 DPSM)
{ @autoreleasepool {
	const ShaderConvert shader = ShaderConvert::RGBA_TO_8I;
	id<MTLRenderPipelineState> pipeline = m_convert_pipeline[static_cast<int>(shader)];
	if (!pipeline)
		[NSException raise:@"StretchRect Missing Pipeline" format:@"No pipeline for %d", static_cast<int>(shader)];

	GSMTLIndexedConvertPSUniform uniform = { sScale, SBW, DBW };

	const GSVector4 dRect(0, 0, dTex->GetWidth(), dTex->GetHeight());
	DoStretchRect(sTex, GSVector4::zero(), dTex, dRect, pipeline, false, LoadAction::DontCareIfFull, &uniform, sizeof(uniform));
}}

void GSDeviceMTL::FlushClears(GSTexture* tex)
{
	if (tex)
		static_cast<GSTextureMTL*>(tex)->FlushClears();
}

// MARK: - MainRenderEncoder Operations

static MTLBlendFactor ConvertBlendFactor(GSDevice::BlendFactor generic)
{
	switch (generic)
	{
		case GSDevice::SRC_COLOR:       return MTLBlendFactorSourceColor;
		case GSDevice::INV_SRC_COLOR:   return MTLBlendFactorOneMinusSourceColor;
		case GSDevice::DST_COLOR:       return MTLBlendFactorDestinationColor;
		case GSDevice::INV_DST_COLOR:   return MTLBlendFactorOneMinusBlendColor;
		case GSDevice::SRC1_COLOR:      return MTLBlendFactorSource1Color;
		case GSDevice::INV_SRC1_COLOR:  return MTLBlendFactorOneMinusSource1Color;
		case GSDevice::SRC_ALPHA:       return MTLBlendFactorSourceAlpha;
		case GSDevice::INV_SRC_ALPHA:   return MTLBlendFactorOneMinusSourceAlpha;
		case GSDevice::DST_ALPHA:       return MTLBlendFactorDestinationAlpha;
		case GSDevice::INV_DST_ALPHA:   return MTLBlendFactorOneMinusDestinationAlpha;
		case GSDevice::SRC1_ALPHA:      return MTLBlendFactorSource1Alpha;
		case GSDevice::INV_SRC1_ALPHA:  return MTLBlendFactorOneMinusSource1Alpha;
		case GSDevice::CONST_COLOR:     return MTLBlendFactorBlendColor;
		case GSDevice::INV_CONST_COLOR: return MTLBlendFactorOneMinusBlendColor;
		case GSDevice::CONST_ONE:       return MTLBlendFactorOne;
		case GSDevice::CONST_ZERO:      return MTLBlendFactorZero;
	}
}

static MTLBlendOperation ConvertBlendOp(GSDevice::BlendOp generic)
{
	switch (generic)
	{
		case GSDevice::OP_ADD:          return MTLBlendOperationAdd;
		case GSDevice::OP_SUBTRACT:     return MTLBlendOperationSubtract;
		case GSDevice::OP_REV_SUBTRACT: return MTLBlendOperationReverseSubtract;
	}
}

static constexpr MTLColorWriteMask MTLColorWriteMaskRGB = MTLColorWriteMaskRed | MTLColorWriteMaskGreen | MTLColorWriteMaskBlue;

static GSMTLExpandType ConvertVSExpand(GSHWDrawConfig::VSExpand generic)
{
	switch (generic)
	{
		case GSHWDrawConfig::VSExpand::None:   return GSMTLExpandType::None;
		case GSHWDrawConfig::VSExpand::Point:  return GSMTLExpandType::Point;
		case GSHWDrawConfig::VSExpand::Line:   return GSMTLExpandType::Line;
		case GSHWDrawConfig::VSExpand::Sprite: return GSMTLExpandType::Sprite;
	}
}

void GSDeviceMTL::MRESetHWPipelineState(GSHWDrawConfig::VSSelector vssel, GSHWDrawConfig::PSSelector pssel, GSHWDrawConfig::BlendState blend, GSHWDrawConfig::ColorMaskSelector cms)
{
	PipelineSelectorExtrasMTL extras(blend, m_current_render.color_target, cms, m_current_render.depth_target, m_current_render.stencil_target);
	PipelineSelectorMTL fullsel(vssel, pssel, extras);
	if (m_current_render.has.pipeline_sel && fullsel == m_current_render.pipeline_sel)
		return;
	m_current_render.pipeline_sel = fullsel;
	m_current_render.has.pipeline_sel = true;
	auto idx = m_hw_pipeline.find(fullsel);
	if (idx != m_hw_pipeline.end())
	{
		[m_current_render.encoder setRenderPipelineState:idx->second];
		return;
	}

	bool primid_tracking_init = pssel.date == 1 || pssel.date == 2;

	VSSelector vssel_mtl;
	vssel_mtl.fst = vssel.fst;
	vssel_mtl.iip = vssel.iip;
	vssel_mtl.point_size = vssel.point_size;
	vssel_mtl.expand = ConvertVSExpand(vssel.expand);
	id<MTLFunction> vs = m_hw_vs[vssel_mtl.key];

	id<MTLFunction> ps;
	auto idx2 = m_hw_ps.find(pssel);
	if (idx2 != m_hw_ps.end())
	{
		ps = idx2->second;
	}
	else
	{
		setFnConstantB(m_fn_constants, pssel.fst,                GSMTLConstantIndex_FST);
		setFnConstantB(m_fn_constants, pssel.iip,                GSMTLConstantIndex_IIP);
		setFnConstantI(m_fn_constants, pssel.aem_fmt,            GSMTLConstantIndex_PS_AEM_FMT);
		setFnConstantI(m_fn_constants, pssel.pal_fmt,            GSMTLConstantIndex_PS_PAL_FMT);
		setFnConstantI(m_fn_constants, pssel.dfmt,               GSMTLConstantIndex_PS_DFMT);
		setFnConstantI(m_fn_constants, pssel.depth_fmt,          GSMTLConstantIndex_PS_DEPTH_FMT);
		setFnConstantB(m_fn_constants, pssel.aem,                GSMTLConstantIndex_PS_AEM);
		setFnConstantB(m_fn_constants, pssel.fba,                GSMTLConstantIndex_PS_FBA);
		setFnConstantB(m_fn_constants, pssel.fog,                GSMTLConstantIndex_PS_FOG);
		setFnConstantI(m_fn_constants, pssel.date,               GSMTLConstantIndex_PS_DATE);
		setFnConstantI(m_fn_constants, pssel.atst,               GSMTLConstantIndex_PS_ATST);
		setFnConstantI(m_fn_constants, pssel.tfx,                GSMTLConstantIndex_PS_TFX);
		setFnConstantB(m_fn_constants, pssel.tcc,                GSMTLConstantIndex_PS_TCC);
		setFnConstantI(m_fn_constants, pssel.wms,                GSMTLConstantIndex_PS_WMS);
		setFnConstantI(m_fn_constants, pssel.wmt,                GSMTLConstantIndex_PS_WMT);
		setFnConstantB(m_fn_constants, pssel.adjs,               GSMTLConstantIndex_PS_ADJS);
		setFnConstantB(m_fn_constants, pssel.adjt,               GSMTLConstantIndex_PS_ADJT);
		setFnConstantB(m_fn_constants, pssel.ltf,                GSMTLConstantIndex_PS_LTF);
		setFnConstantB(m_fn_constants, pssel.shuffle,            GSMTLConstantIndex_PS_SHUFFLE);
		setFnConstantB(m_fn_constants, pssel.read_ba,            GSMTLConstantIndex_PS_READ_BA);
		setFnConstantB(m_fn_constants, pssel.real16src,          GSMTLConstantIndex_PS_READ16_SRC);
		setFnConstantB(m_fn_constants, pssel.write_rg,           GSMTLConstantIndex_PS_WRITE_RG);
		setFnConstantB(m_fn_constants, pssel.fbmask,             GSMTLConstantIndex_PS_FBMASK);
		setFnConstantI(m_fn_constants, pssel.blend_a,            GSMTLConstantIndex_PS_BLEND_A);
		setFnConstantI(m_fn_constants, pssel.blend_b,            GSMTLConstantIndex_PS_BLEND_B);
		setFnConstantI(m_fn_constants, pssel.blend_c,            GSMTLConstantIndex_PS_BLEND_C);
		setFnConstantI(m_fn_constants, pssel.blend_d,            GSMTLConstantIndex_PS_BLEND_D);
		setFnConstantI(m_fn_constants, pssel.blend_hw,           GSMTLConstantIndex_PS_BLEND_HW);
		setFnConstantB(m_fn_constants, pssel.a_masked,           GSMTLConstantIndex_PS_A_MASKED);
		setFnConstantB(m_fn_constants, pssel.hdr,                GSMTLConstantIndex_PS_HDR);
		setFnConstantB(m_fn_constants, pssel.colclip,            GSMTLConstantIndex_PS_COLCLIP);
		setFnConstantI(m_fn_constants, pssel.blend_mix,          GSMTLConstantIndex_PS_BLEND_MIX);
		setFnConstantB(m_fn_constants, pssel.round_inv,          GSMTLConstantIndex_PS_ROUND_INV);
		setFnConstantB(m_fn_constants, pssel.fixed_one_a,        GSMTLConstantIndex_PS_FIXED_ONE_A);
		setFnConstantB(m_fn_constants, pssel.pabe,               GSMTLConstantIndex_PS_PABE);
		setFnConstantB(m_fn_constants, pssel.no_color,           GSMTLConstantIndex_PS_NO_COLOR);
		setFnConstantB(m_fn_constants, pssel.no_color1,          GSMTLConstantIndex_PS_NO_COLOR1);
		// no_ablend ignored for now (No Metal driver has had DSB so broken that it's needed to be disabled, though Intel's was pretty close)
		setFnConstantB(m_fn_constants, pssel.only_alpha,         GSMTLConstantIndex_PS_ONLY_ALPHA);
		setFnConstantI(m_fn_constants, pssel.channel,            GSMTLConstantIndex_PS_CHANNEL);
		setFnConstantI(m_fn_constants, pssel.dither,             GSMTLConstantIndex_PS_DITHER);
		setFnConstantB(m_fn_constants, pssel.zclamp,             GSMTLConstantIndex_PS_ZCLAMP);
		setFnConstantB(m_fn_constants, pssel.tcoffsethack,       GSMTLConstantIndex_PS_TCOFFSETHACK);
		setFnConstantB(m_fn_constants, pssel.urban_chaos_hle,    GSMTLConstantIndex_PS_URBAN_CHAOS_HLE);
		setFnConstantB(m_fn_constants, pssel.tales_of_abyss_hle, GSMTLConstantIndex_PS_TALES_OF_ABYSS_HLE);
		setFnConstantB(m_fn_constants, pssel.tex_is_fb,          GSMTLConstantIndex_PS_TEX_IS_FB);
		setFnConstantB(m_fn_constants, pssel.automatic_lod,      GSMTLConstantIndex_PS_AUTOMATIC_LOD);
		setFnConstantB(m_fn_constants, pssel.manual_lod,         GSMTLConstantIndex_PS_MANUAL_LOD);
		setFnConstantB(m_fn_constants, pssel.point_sampler,      GSMTLConstantIndex_PS_POINT_SAMPLER);
		setFnConstantI(m_fn_constants, pssel.scanmsk,            GSMTLConstantIndex_PS_SCANMSK);
		auto newps = LoadShader(@"ps_main");
		ps = newps;
		m_hw_ps.insert(std::make_pair(pssel, std::move(newps)));
	}

	MRCOwned<MTLRenderPipelineDescriptor*> pdesc = MRCTransfer([MTLRenderPipelineDescriptor new]);
	if (vssel_mtl.point_size)
		[pdesc setInputPrimitiveTopology:MTLPrimitiveTopologyClassPoint];
	if (vssel_mtl.expand == GSMTLExpandType::None)
		[pdesc setVertexDescriptor:m_hw_vertex];
	else
		[pdesc setInputPrimitiveTopology:MTLPrimitiveTopologyClassTriangle];
	MTLRenderPipelineColorAttachmentDescriptor* color = [[pdesc colorAttachments] objectAtIndexedSubscript:0];
	color.pixelFormat = ConvertPixelFormat(extras.rt);
	[pdesc setDepthAttachmentPixelFormat:extras.has_depth ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatInvalid];
	[pdesc setStencilAttachmentPixelFormat:extras.has_stencil ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatInvalid];
	color.writeMask = extras.writemask;
	if (primid_tracking_init)
	{
		color.blendingEnabled = YES;
		color.rgbBlendOperation = MTLBlendOperationMin;
		color.sourceRGBBlendFactor = MTLBlendFactorOne;
		color.destinationRGBBlendFactor = MTLBlendFactorOne;
		color.writeMask = MTLColorWriteMaskRed;
	}
	else if (extras.blend_enable && (extras.writemask & MTLColorWriteMaskRGB))
	{
		color.blendingEnabled = YES;
		color.rgbBlendOperation = ConvertBlendOp(extras.blend_op);
		color.sourceRGBBlendFactor = ConvertBlendFactor(extras.src_factor);
		color.destinationRGBBlendFactor = ConvertBlendFactor(extras.dst_factor);
	}
	NSString* pname = [NSString stringWithFormat:@"HW Render %x.%x.%llx.%x", vssel_mtl.key, pssel.key_hi, pssel.key_lo, extras.fullkey()];
	auto pipeline = MakePipeline(pdesc, vs, ps, pname);

	[m_current_render.encoder setRenderPipelineState:pipeline];
	m_hw_pipeline.insert(std::make_pair(fullsel, std::move(pipeline)));
}

void GSDeviceMTL::MRESetDSS(DepthStencilSelector sel)
{
	if (!m_current_render.depth_target || m_current_render.depth_sel.key == sel.key)
		return;
	[m_current_render.encoder setDepthStencilState:m_dss_hw[sel.key]];
	m_current_render.depth_sel = sel;
}

void GSDeviceMTL::MRESetDSS(id<MTLDepthStencilState> dss)
{
	[m_current_render.encoder setDepthStencilState:dss];
	m_current_render.depth_sel.key = -1;
}

void GSDeviceMTL::MRESetSampler(SamplerSelector sel)
{
	if (m_current_render.has.sampler && m_current_render.sampler_sel.key == sel.key)
		return;
	[m_current_render.encoder setFragmentSamplerState:m_sampler_hw[sel.key] atIndex:0];
	m_current_render.sampler_sel = sel;
	m_current_render.has.sampler = true;
}

static void textureBarrier(id<MTLRenderCommandEncoder> enc)
{
	if (@available(macOS 10.14, *)) {
		[enc memoryBarrierWithScope:MTLBarrierScopeRenderTargets
		                afterStages:MTLRenderStageFragment
		               beforeStages:MTLRenderStageFragment];
	} else {
		[enc textureBarrier];
	}
}

void GSDeviceMTL::MRESetTexture(GSTexture* tex, int pos)
{
	if (tex == m_current_render.tex[pos])
		return;
	m_current_render.tex[pos] = tex;
	if (GSTextureMTL* mtex = static_cast<GSTextureMTL*>(tex))
	{
		[m_current_render.encoder setFragmentTexture:mtex->GetTexture() atIndex:pos];
		mtex->m_last_read = m_current_draw;
	}
}

void GSDeviceMTL::MRESetVertices(id<MTLBuffer> buffer, size_t offset)
{
	if (m_current_render.vertex_buffer != (__bridge void*)buffer)
	{
		m_current_render.vertex_buffer = (__bridge void*)buffer;
		[m_current_render.encoder setVertexBuffer:buffer offset:offset atIndex:GSMTLBufferIndexHWVertices];
	}
	else
	{
		[m_current_render.encoder setVertexBufferOffset:offset atIndex:GSMTLBufferIndexHWVertices];
	}
}

void GSDeviceMTL::MRESetScissor(const GSVector4i& scissor)
{
	if (m_current_render.has.scissor && (m_current_render.scissor == scissor).alltrue())
		return;
	MTLScissorRect r;
	r.x = scissor.x;
	r.y = scissor.y;
	r.width = scissor.width();
	r.height = scissor.height();
	[m_current_render.encoder setScissorRect:r];
	m_current_render.scissor = scissor;
	m_current_render.has.scissor = true;
}

void GSDeviceMTL::MREClearScissor()
{
	if (!m_current_render.has.scissor)
		return;
	m_current_render.has.scissor = false;
	GSVector4i size = GSVector4i(0);
	if (m_current_render.color_target)   size = size.max_u32(GSVector4i(m_current_render.color_target  ->GetSize()));
	if (m_current_render.depth_target)   size = size.max_u32(GSVector4i(m_current_render.depth_target  ->GetSize()));
	if (m_current_render.stencil_target) size = size.max_u32(GSVector4i(m_current_render.stencil_target->GetSize()));
	MTLScissorRect r;
	r.x = 0;
	r.y = 0;
	r.width = size.x;
	r.height = size.y;
	[m_current_render.encoder setScissorRect:r];
}

void GSDeviceMTL::MRESetCB(const GSHWDrawConfig::VSConstantBuffer& cb)
{
	if (m_current_render.has.cb_vs && m_current_render.cb_vs == cb)
		return;
	[m_current_render.encoder setVertexBytes:&cb length:sizeof(cb) atIndex:GSMTLBufferIndexHWUniforms];
	m_current_render.has.cb_vs = true;
	m_current_render.cb_vs = cb;
}

void GSDeviceMTL::MRESetCB(const GSHWDrawConfig::PSConstantBuffer& cb)
{
	if (m_current_render.has.cb_ps && m_current_render.cb_ps == cb)
		return;
	[m_current_render.encoder setFragmentBytes:&cb length:sizeof(cb) atIndex:GSMTLBufferIndexHWUniforms];
	m_current_render.has.cb_ps = true;
	m_current_render.cb_ps = cb;
}

void GSDeviceMTL::MRESetBlendColor(u8 color)
{
	if (m_current_render.has.blend_color && m_current_render.blend_color == color)
		return;
	float fc = static_cast<float>(color) / 128.f;
	[m_current_render.encoder setBlendColorRed:fc green:fc blue:fc alpha:fc];
	m_current_render.has.blend_color = true;
	m_current_render.blend_color = color;
}

void GSDeviceMTL::MRESetPipeline(id<MTLRenderPipelineState> pipe)
{
	[m_current_render.encoder setRenderPipelineState:pipe];
	m_current_render.has.pipeline_sel = false;
}

// MARK: - HW Render

// Metal can't import GSDevice.h, but we should make sure the structs are at least compatible
static_assert(sizeof(GSVertex) == sizeof(GSMTLMainVertex));
static_assert(offsetof(GSVertex, ST)      == offsetof(GSMTLMainVertex, st));
static_assert(offsetof(GSVertex, RGBAQ.R) == offsetof(GSMTLMainVertex, rgba));
static_assert(offsetof(GSVertex, RGBAQ.Q) == offsetof(GSMTLMainVertex, q));
static_assert(offsetof(GSVertex, XYZ.X)   == offsetof(GSMTLMainVertex, xy));
static_assert(offsetof(GSVertex, XYZ.Z)   == offsetof(GSMTLMainVertex, z));
static_assert(offsetof(GSVertex, UV)      == offsetof(GSMTLMainVertex, uv));
static_assert(offsetof(GSVertex, FOG)     == offsetof(GSMTLMainVertex, fog));

static_assert(sizeof(GSHWDrawConfig::VSConstantBuffer) == sizeof(GSMTLMainVSUniform));
static_assert(sizeof(GSHWDrawConfig::PSConstantBuffer) == sizeof(GSMTLMainPSUniform));
static_assert(offsetof(GSHWDrawConfig::VSConstantBuffer, vertex_scale)     == offsetof(GSMTLMainVSUniform, vertex_scale));
static_assert(offsetof(GSHWDrawConfig::VSConstantBuffer, vertex_offset)    == offsetof(GSMTLMainVSUniform, vertex_offset));
static_assert(offsetof(GSHWDrawConfig::VSConstantBuffer, texture_scale)    == offsetof(GSMTLMainVSUniform, texture_scale));
static_assert(offsetof(GSHWDrawConfig::VSConstantBuffer, texture_offset)   == offsetof(GSMTLMainVSUniform, texture_offset));
static_assert(offsetof(GSHWDrawConfig::VSConstantBuffer, point_size)       == offsetof(GSMTLMainVSUniform, point_size));
static_assert(offsetof(GSHWDrawConfig::VSConstantBuffer, max_depth)        == offsetof(GSMTLMainVSUniform, max_depth));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, FogColor_AREF.x)  == offsetof(GSMTLMainPSUniform, fog_color));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, FogColor_AREF.a)  == offsetof(GSMTLMainPSUniform, aref));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, WH)               == offsetof(GSMTLMainPSUniform, wh));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, TA_MaxDepth_Af.x) == offsetof(GSMTLMainPSUniform, ta));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, TA_MaxDepth_Af.z) == offsetof(GSMTLMainPSUniform, max_depth));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, TA_MaxDepth_Af.w) == offsetof(GSMTLMainPSUniform, alpha_fix));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, FbMask)           == offsetof(GSMTLMainPSUniform, fbmask));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, HalfTexel)        == offsetof(GSMTLMainPSUniform, half_texel));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, MinMax)           == offsetof(GSMTLMainPSUniform, uv_min_max));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, STRange)          == offsetof(GSMTLMainPSUniform, st_range));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, ChannelShuffle)   == offsetof(GSMTLMainPSUniform, channel_shuffle));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, TCOffsetHack)     == offsetof(GSMTLMainPSUniform, tc_offset));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, STScale)          == offsetof(GSMTLMainPSUniform, st_scale));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, DitherMatrix)     == offsetof(GSMTLMainPSUniform, dither_matrix));
static_assert(offsetof(GSHWDrawConfig::PSConstantBuffer, ScaleFactor)      == offsetof(GSMTLMainPSUniform, scale_factor));

void GSDeviceMTL::SetupDestinationAlpha(GSTexture* rt, GSTexture* ds, const GSVector4i& r, bool datm)
{
	FlushClears(rt);
	BeginRenderPass(@"Destination Alpha Setup", nullptr, MTLLoadActionDontCare, nullptr, MTLLoadActionDontCare, ds, MTLLoadActionDontCare);
	[m_current_render.encoder setStencilReferenceValue:1];
	MRESetDSS(m_dss_stencil_zero);
	RenderCopy(nullptr, m_stencil_clear_pipeline, r);
	MRESetDSS(m_dss_stencil_write);
	RenderCopy(rt, m_datm_pipeline[datm], r);
}

static id<MTLTexture> getTexture(GSTexture* tex)
{
	return tex ? static_cast<GSTextureMTL*>(tex)->GetTexture() : nil;
}

void GSDeviceMTL::MREInitHWDraw(GSHWDrawConfig& config, const Map& verts)
{
	MRESetScissor(config.scissor);
	MRESetTexture(config.tex, GSMTLTextureIndexTex);
	MRESetTexture(config.pal, GSMTLTextureIndexPalette);
	MRESetSampler(config.sampler);
	MRESetCB(config.cb_vs);
	MRESetCB(config.cb_ps);
	MRESetVertices(verts.gpu_buffer, verts.gpu_offset);
}

void GSDeviceMTL::RenderHW(GSHWDrawConfig& config)
{ @autoreleasepool {
	if (config.topology == GSHWDrawConfig::Topology::Point)
		config.vs.point_size = 1; // M1 requires point size output on *all* points

	if (config.tex && config.ds == config.tex)
		EndRenderPass(); // Barrier

	size_t vertsize = config.nverts * sizeof(*config.verts);
	size_t idxsize = config.nindices * sizeof(*config.indices);
	Map allocation = Allocate(m_vertex_upload_buf, vertsize + idxsize);
	memcpy(allocation.cpu_buffer, config.verts, vertsize);
	memcpy(static_cast<u8*>(allocation.cpu_buffer) + vertsize, config.indices, idxsize);

	FlushClears(config.tex);
	FlushClears(config.pal);

	GSTexture* stencil = nullptr;
	GSTexture* primid_tex = nullptr;
	GSTexture* rt = config.rt;
	switch (config.destination_alpha)
	{
		case GSHWDrawConfig::DestinationAlphaMode::Off:
		case GSHWDrawConfig::DestinationAlphaMode::Full:
			break; // No setup
		case GSHWDrawConfig::DestinationAlphaMode::PrimIDTracking:
		{
			FlushClears(config.rt);
			GSVector2i size = config.rt->GetSize();
			primid_tex = CreateRenderTarget(size.x, size.y, GSTexture::Format::PrimID);
			DepthStencilSelector dsel = config.depth;
			dsel.zwe = 0;
			GSTexture* depth = dsel.key == DepthStencilSelector::NoDepth().key ? nullptr : config.ds;
			BeginRenderPass(@"PrimID Destination Alpha Init", primid_tex, MTLLoadActionDontCare, depth, MTLLoadActionLoad);
			RenderCopy(config.rt, m_primid_init_pipeline[static_cast<bool>(depth)][config.datm], config.drawarea);
			MRESetDSS(dsel);
			ASSERT(config.ps.date == 1 || config.ps.date == 2);
			if (config.ps.tex_is_fb)
				MRESetTexture(config.rt, GSMTLTextureIndexRenderTarget);
			config.require_one_barrier = false; // Ending render pass is our barrier
			ASSERT(config.require_full_barrier == false && config.drawlist == nullptr);
			MRESetHWPipelineState(config.vs, config.ps, {}, {});
			MREInitHWDraw(config, allocation);
			SendHWDraw(config, m_current_render.encoder, allocation.gpu_buffer, allocation.gpu_offset + vertsize);
			config.ps.date = 3;
			break;
		}
		case GSHWDrawConfig::DestinationAlphaMode::StencilOne:
			BeginRenderPass(@"Destination Alpha Stencil Clear", nullptr, MTLLoadActionDontCare, nullptr, MTLLoadActionDontCare, config.ds, MTLLoadActionDontCare);
			[m_current_render.encoder setStencilReferenceValue:1];
			MRESetDSS(m_dss_stencil_write);
			RenderCopy(nullptr, m_stencil_clear_pipeline, config.drawarea);
			stencil = config.ds;
			break;
		case GSHWDrawConfig::DestinationAlphaMode::Stencil:
			SetupDestinationAlpha(config.rt, config.ds, config.drawarea, config.datm);
			stencil = config.ds;
			break;
	}

	GSTexture* hdr_rt = nullptr;
	if (config.ps.hdr)
	{
		GSVector2i size = config.rt->GetSize();
		hdr_rt = CreateRenderTarget(size.x, size.y, GSTexture::Format::HDRColor);
		BeginRenderPass(@"HDR Init", hdr_rt, MTLLoadActionDontCare, nullptr, MTLLoadActionDontCare);
		RenderCopy(config.rt, m_hdr_init_pipeline, config.drawarea);
		rt = hdr_rt;
		g_perfmon.Put(GSPerfMon::TextureCopies, 1);
	}

	// Try to reduce render pass restarts
	if (!stencil && config.depth.key == DepthStencilSelector::NoDepth().key && (m_current_render.color_target != rt || m_current_render.depth_target != config.ds))
		config.ds = nullptr;
	if (!config.ds && m_current_render.color_target == rt && stencil == m_current_render.stencil_target && m_current_render.depth_target != config.tex)
		config.ds = m_current_render.depth_target;
	if (!rt && !config.ds)
	{
		// If we were rendering depth-only and depth gets cleared by the above check, that turns into rendering nothing, which should be a no-op
		pxAssertDev(0, "RenderHW was given a completely useless draw call!");
		[m_current_render.encoder insertDebugSignpost:@"Skipped no-color no-depth draw"];
		if (primid_tex)
			Recycle(primid_tex);
		return;
	}

	BeginRenderPass(@"RenderHW", rt, MTLLoadActionLoad, config.ds, MTLLoadActionLoad, stencil, MTLLoadActionLoad);
	id<MTLRenderCommandEncoder> mtlenc = m_current_render.encoder;
	FlushDebugEntries(mtlenc);
	MREInitHWDraw(config, allocation);
	if (config.require_one_barrier || config.require_full_barrier)
		MRESetTexture(config.rt, GSMTLTextureIndexRenderTarget);
	if (primid_tex)
		MRESetTexture(primid_tex, GSMTLTextureIndexPrimIDs);
	if (config.blend.constant_enable)
		MRESetBlendColor(config.blend.constant);
	MRESetHWPipelineState(config.vs, config.ps, config.blend, config.colormask);
	MRESetDSS(config.depth);

	SendHWDraw(config, mtlenc, allocation.gpu_buffer, allocation.gpu_offset + vertsize);

	if (config.alpha_second_pass.enable)
	{
		if (config.alpha_second_pass.ps_aref != config.cb_ps.FogColor_AREF.a)
		{
			config.cb_ps.FogColor_AREF.a = config.alpha_second_pass.ps_aref;
			MRESetCB(config.cb_ps);
		}
		MRESetHWPipelineState(config.vs, config.alpha_second_pass.ps, config.blend, config.alpha_second_pass.colormask);
		MRESetDSS(config.alpha_second_pass.depth);
		SendHWDraw(config, mtlenc, allocation.gpu_buffer, allocation.gpu_offset + vertsize);
	}

	if (hdr_rt)
	{
		BeginRenderPass(@"HDR Resolve", config.rt, MTLLoadActionLoad, nullptr, MTLLoadActionDontCare);
		RenderCopy(hdr_rt, m_hdr_resolve_pipeline, config.drawarea);
		g_perfmon.Put(GSPerfMon::TextureCopies, 1);

		Recycle(hdr_rt);
	}

	if (primid_tex)
		Recycle(primid_tex);
}}

void GSDeviceMTL::SendHWDraw(GSHWDrawConfig& config, id<MTLRenderCommandEncoder> enc, id<MTLBuffer> buffer, size_t off)
{
	MTLPrimitiveType topology;
	switch (config.topology)
	{
		case GSHWDrawConfig::Topology::Point:    topology = MTLPrimitiveTypePoint;    break;
		case GSHWDrawConfig::Topology::Line:     topology = MTLPrimitiveTypeLine;     break;
		case GSHWDrawConfig::Topology::Triangle: topology = MTLPrimitiveTypeTriangle; break;
	}

	if (config.drawlist)
	{
		[enc pushDebugGroup:[NSString stringWithFormat:@"Full barrier split draw (%d sprites in %d groups)", config.nindices / config.indices_per_prim, config.drawlist->size()]];
#if defined(_DEBUG)
		// Check how draw call is split.
		std::map<size_t, size_t> frequency;
		for (const auto& it : *config.drawlist)
			++frequency[it];

		std::string message;
		for (const auto& it : frequency)
			message += " " + std::to_string(it.first) + "(" + std::to_string(it.second) + ")";

		[enc insertDebugSignpost:[NSString stringWithFormat:@"Split single draw (%d sprites) into %zu draws: consecutive draws(frequency):%s",
			config.nindices / config.indices_per_prim, config.drawlist->size(), message.c_str()]];
#endif


		g_perfmon.Put(GSPerfMon::DrawCalls, config.drawlist->size());
		g_perfmon.Put(GSPerfMon::Barriers, config.drawlist->size());
		for (size_t count = 0, p = 0, n = 0; n < config.drawlist->size(); p += count, ++n)
		{
			count = (*config.drawlist)[n] * config.indices_per_prim;
			textureBarrier(enc);
			[enc drawIndexedPrimitives:topology
			                indexCount:count
			                 indexType:MTLIndexTypeUInt32
			               indexBuffer:buffer
			         indexBufferOffset:off + p * sizeof(*config.indices)];
		}
		[enc popDebugGroup];
	}
	else if (config.require_full_barrier)
	{
		const u32 ndraws = config.nindices / config.indices_per_prim;
		g_perfmon.Put(GSPerfMon::DrawCalls, ndraws);
		g_perfmon.Put(GSPerfMon::Barriers, ndraws);
		[enc pushDebugGroup:[NSString stringWithFormat:@"Full barrier split draw (%d prims)", ndraws]];
		for (size_t p = 0; p < config.nindices; p += config.indices_per_prim)
		{
			textureBarrier(enc);
			[enc drawIndexedPrimitives:topology
			                indexCount:config.indices_per_prim
			                 indexType:MTLIndexTypeUInt32
			               indexBuffer:buffer
			         indexBufferOffset:off + p * sizeof(*config.indices)];
		}
		[enc popDebugGroup];
	}
	else if (config.require_one_barrier)
	{
		// One barrier needed
		textureBarrier(enc);
		[enc drawIndexedPrimitives:topology
		                indexCount:config.nindices
		                 indexType:MTLIndexTypeUInt32
		               indexBuffer:buffer
		         indexBufferOffset:off];
		g_perfmon.Put(GSPerfMon::DrawCalls, 1);
		g_perfmon.Put(GSPerfMon::Barriers, 1);
	}
	else
	{
		// No barriers needed
		[enc drawIndexedPrimitives:topology
		                indexCount:config.nindices
		                 indexType:MTLIndexTypeUInt32
		               indexBuffer:buffer
		         indexBufferOffset:off];
		g_perfmon.Put(GSPerfMon::DrawCalls, 1);
	}
}

// tbh I'm not a fan of the current debug groups
// not much useful information and makes things harder to find
// good to turn on if you're debugging tc stuff though
#ifndef MTL_ENABLE_DEBUG
	#define MTL_ENABLE_DEBUG 0
#endif

void GSDeviceMTL::PushDebugGroup(const char* fmt, ...)
{
#if MTL_ENABLE_DEBUG
	va_list va;
	va_start(va, fmt);
	MRCOwned<NSString*> nsfmt = MRCTransfer([[NSString alloc] initWithUTF8String:fmt]);
	m_debug_entries.emplace_back(DebugEntry::Push, MRCTransfer([[NSString alloc] initWithFormat:nsfmt arguments:va]));
	va_end(va);
#endif
}

void GSDeviceMTL::PopDebugGroup()
{
#if MTL_ENABLE_DEBUG
	m_debug_entries.emplace_back(DebugEntry::Pop, nullptr);
#endif
}

void GSDeviceMTL::InsertDebugMessage(DebugMessageCategory category, const char* fmt, ...)
{
#if MTL_ENABLE_DEBUG
	va_list va;
	va_start(va, fmt);
	MRCOwned<NSString*> nsfmt = MRCTransfer([[NSString alloc] initWithUTF8String:fmt]);
	m_debug_entries.emplace_back(DebugEntry::Insert, MRCTransfer([[NSString alloc] initWithFormat:nsfmt arguments:va]));
	va_end(va);
#endif
}

void GSDeviceMTL::ProcessDebugEntry(id<MTLCommandEncoder> enc, const DebugEntry& entry)
{
	switch (entry.op)
	{
		case DebugEntry::Push:
			[enc pushDebugGroup:entry.str];
			m_debug_group_level++;
			break;
		case DebugEntry::Pop:
			[enc popDebugGroup];
			if (m_debug_group_level > 0)
				m_debug_group_level--;
			break;
		case DebugEntry::Insert:
			[enc insertDebugSignpost:entry.str];
			break;
	}
}

void GSDeviceMTL::FlushDebugEntries(id<MTLCommandEncoder> enc)
{
#if MTL_ENABLE_DEBUG
	if (!m_debug_entries.empty())
	{
		for (const DebugEntry& entry : m_debug_entries)
		{
			ProcessDebugEntry(enc, entry);
		}
		m_debug_entries.clear();
	}
#endif
}

void GSDeviceMTL::EndDebugGroup(id<MTLCommandEncoder> enc)
{
#if MTL_ENABLE_DEBUG
	if (!m_debug_entries.empty() && m_debug_group_level)
	{
		auto begin = m_debug_entries.begin();
		auto cur = begin;
		auto end = m_debug_entries.end();
		while (cur != end && m_debug_group_level)
		{
			ProcessDebugEntry(enc, *cur);
			cur++;
		}
		m_debug_entries.erase(begin, cur);
	}
#endif
}

#endif // __APPLE__
