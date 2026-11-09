## A 3D quad whose shader material is reached as `material`, so a shader-quad layer binds the same path
## ("material:shader_parameter/strength") in 2D and in 3D.
class_name FxQuad3D
extends MeshInstance3D

var material: Material:
	get:
		return material_override
	set(value):
		material_override = value
