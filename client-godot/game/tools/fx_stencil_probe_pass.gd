## Spec vfx-stencil 1.4, claim K4 part 2 (probe only): a CompositorEffect that attaches the scene's depth-stencil buffer and draws
## a full-screen magenta triangle with a stencil test (EQUAL `reference`). If magenta shows over the stamped object, a compositor can
## use the main stencil buffer; nothing else in the project uses this. What it saw is kept in `report` for the probe to read.
extends CompositorEffect

const VERTEX := """
#version 450
void main() {
	vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
	gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
"""
const FRAGMENT := """
#version 450
layout(location = 0) out vec4 frag_color;
void main() {
	frag_color = vec4(1.0, 0.0, 1.0, 1.0);
}
"""

var reference: int = 1
## When valid, the pass draws into this texture of its own (cleared first) instead of the scene's colour: the docs' "copy the main
## stencil buffer to a custom texture" case. Same size as the viewport.
var target: RID
## What the callback saw: the depth format, whether it carries stencil, errors on the way, frames drawn.
var report: Dictionary = {"frames": 0, "depth_format": -1, "depth_has_stencil": false, "color_format": -1, "problem": ""}

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
var _pipeline_format: int = -1


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT


func _render_callback(_type: int, render_data: RenderData) -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		report["problem"] = "no RenderingDevice (not an RD renderer)"
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if buffers == null:
		report["problem"] = "no RenderSceneBuffersRD"
		return
	var color: RID = buffers.get_color_layer(0)
	var depth: RID = buffers.get_depth_layer(0)
	var depth_format: int = _rd.texture_get_format(depth).format
	report["depth_format"] = depth_format
	report["depth_has_stencil"] = depth_format in [RenderingDevice.DATA_FORMAT_D24_UNORM_S8_UINT,
		RenderingDevice.DATA_FORMAT_D32_SFLOAT_S8_UINT, RenderingDevice.DATA_FORMAT_D16_UNORM_S8_UINT]
	report["color_format"] = _rd.texture_get_format(color).format
	if not report["depth_has_stencil"]:
		report["problem"] = "the depth buffer has no stencil aspect"
		return
	if not _shader.is_valid():
		var source := RDShaderSource.new()
		source.source_vertex = VERTEX
		source.source_fragment = FRAGMENT
		var spirv := _rd.shader_compile_spirv_from_source(source)
		if spirv.compile_error_vertex != "" or spirv.compile_error_fragment != "":
			report["problem"] = "shader: %s %s" % [spirv.compile_error_vertex, spirv.compile_error_fragment]
			return
		_shader = _rd.shader_create_from_spirv(spirv)
	var framebuffer := _rd.framebuffer_create([target if target.is_valid() else color, depth])
	if not framebuffer.is_valid():
		report["problem"] = "framebuffer_create([color, depth]) failed"
		return
	var format := _rd.framebuffer_get_format(framebuffer)
	if format != _pipeline_format:
		if _pipeline.is_valid():
			_rd.free_rid(_pipeline)  # the old format's pipeline
		_pipeline = _rd.render_pipeline_create(_shader, format, RenderingDevice.INVALID_FORMAT_ID,
			RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, RDPipelineRasterizationState.new(), RDPipelineMultisampleState.new(),
			_stencil_state(), _blend_state())
		_pipeline_format = format
	if not _pipeline.is_valid():
		report["problem"] = "render_pipeline_create failed"
		_rd.free_rid(framebuffer)
		return
	var list := _rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_COLOR_0 if target.is_valid() else RenderingDevice.DRAW_DEFAULT_ALL,
		PackedColorArray([Color(0, 0, 0, 1)]))
	_rd.draw_list_bind_render_pipeline(list, _pipeline)
	_rd.draw_list_draw(list, false, 1, 3)
	_rd.draw_list_end()
	_rd.free_rid(framebuffer)
	report["frames"] += 1


func _stencil_state() -> RDPipelineDepthStencilState:
	var state := RDPipelineDepthStencilState.new()
	state.enable_depth_test = false
	state.enable_depth_write = false
	state.enable_stencil = true
	for side in ["front_op", "back_op"]:
		state.set(side + "_compare", RenderingDevice.COMPARE_OP_EQUAL)
		state.set(side + "_reference", reference)
		state.set(side + "_compare_mask", 0xFF)
		state.set(side + "_write_mask", 0)
		state.set(side + "_pass", RenderingDevice.STENCIL_OP_KEEP)
		state.set(side + "_fail", RenderingDevice.STENCIL_OP_KEEP)
		state.set(side + "_depth_fail", RenderingDevice.STENCIL_OP_KEEP)
	return state


func _blend_state() -> RDPipelineColorBlendState:
	var blend := RDPipelineColorBlendState.new()
	blend.attachments = [RDPipelineColorBlendStateAttachment.new()]
	return blend


func free_resources() -> void:
	if _rd == null:
		return
	if _pipeline.is_valid():
		_rd.free_rid(_pipeline)
	if _shader.is_valid():
		_rd.free_rid(_shader)
