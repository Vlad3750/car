extends SpringArm3D

## Chase camera. Goes top_level so it does NOT inherit the car's rotation:
## a rigid child camera rolls and pitches with the body, which hides drift
## (the car looks straight while the world spins) and makes flips nauseating.
## Instead we follow the car's position with lag and copy only its yaw.

## How fast the rig catches up to the car. Lower = more trailing lag.
@export var follow_speed := 8.0
## How fast the rig swings around to the car's new heading. Keep this BELOW
## follow_speed - the lag between where the car points and where the camera
## points is what makes a drift read on screen.
@export var turn_speed := 4.0
## Height above the car's origin to orbit around.
@export var height := 0.6
## Downward tilt of the camera, in degrees.
@export var pitch_degrees := 20.0

var car: Node3D
var aim := Vector3.FORWARD          # last good horizontal heading


func _ready() -> void:
	car = get_parent()
	top_level = true                # own transform, ignore the car's rotation
	add_excluded_object(car.get_rid())   # never collide the arm with the car
	global_position = car.global_position + Vector3.UP * height
	aim = _flat_forward()
	global_basis = _target_basis()


func _physics_process(delta: float) -> void:
	global_position = global_position.lerp(
		car.global_position + Vector3.UP * height,
		clampf(follow_speed * delta, 0.0, 1.0))

	# Yaw only, and lagged. Roll/pitch are deliberately dropped so the horizon
	# stays level no matter what the car is doing.
	aim = aim.slerp(_flat_forward(), clampf(turn_speed * delta, 0.0, 1.0))
	global_basis = _target_basis()


## The car's heading flattened onto the ground plane. While the car is on its
## nose or roof the forward axis goes vertical and the flattened vector
## collapses, so we keep the last good one instead of snapping to garbage.
func _flat_forward() -> Vector3:
	var fwd := car.global_basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.01:
		return aim
	return fwd.normalized()


func _target_basis() -> Basis:
	# looking_at points -Z along `aim`, so +Z (the arm, where the camera sits)
	# ends up behind the car. Negative angle because a positive rotation about
	# the local x axis swings +Z down, which buries the camera under the car.
	var b := Basis.looking_at(aim, Vector3.UP)
	return b.rotated(b.x, deg_to_rad(-pitch_degrees))
