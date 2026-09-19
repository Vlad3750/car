extends VehicleBody3D

# --- Tunables (Inspector) ---
@export_group("Air Control")
## Peak air-spin rate (rad/s) A/D can drive the car to while airborne.
@export var air_spin_speed := 1.6
## Peak air-pitch rate (rad/s) W/S can drive the car to while airborne.
@export var air_pitch_speed := 1.6
## How fast air spin and pitch reach (and fall back from) those rates.
@export var air_spin_accel := 6.0
## How hard the car rights itself toward wheels-down while airborne.
@export var air_level_speed := 3.0
## How fast that righting torque builds up.
@export var air_level_accel := 4.0
## Strength of the righting nudge while some wheels are down. Torque, not a
## velocity override, so the physics solver stays in charge of the landing.
@export var partial_contact_torque := 2.0

## Friction of the car body itself when it scrapes the ground. The wheels'
## slip settings do nothing for chassis-on-floor contact - that is plain
## rigid-body friction, and at the default 1.0 a bottomed-out landing grinds
## the car to a halt. Set to 1.0 to restore stock behaviour.
@export var chassis_friction := 0.05

## Peak engine force.
@export var max_engine_force := 100.0

@export_group("Debug")
## Prints speed / sideways slide / wheel contacts, and every frame near a landing.
@export var debug := false

@export_group("Steering Lockout")
## Height above ground (m) past which steering is frozen.
@export var lockout_height := 0.2
## Continuous air time (s) past which steering is frozen, regardless of height.
@export var lockout_air_time := 1.0
## Ray distance from the car origin to the ground when parked. Measure it once
## in the editor and tune: it is the zero point for "height above ground".
@export var ride_height := 0.46
## How far down the ray looks. Anything beyond this counts as "very high".
@export var ray_length := 8.0

@onready var wheels: Array[VehicleWheel3D] = [$Front_Left, $Front_Right, $Back_Left, $Back_Right]

var ground_ray: RayCast3D
var airborne := false
var wheel_contacts := 0                # 0-4, how many wheels are actually down
var air_time_since_land := 99.0        # debug only: seconds since touchdown
var air_time := 0.0


func _ready() -> void:
	var mat := PhysicsMaterial.new()
	mat.friction = chassis_friction
	physics_material_override = mat

	# Created in code so there is nothing to add by hand in the editor.
	ground_ray = RayCast3D.new()
	ground_ray.name = "GroundRay"
	ground_ray.target_position = Vector3(0, -ray_length, 0)
	ground_ray.exclude_parent = true      # never hit our own body
	ground_ray.enabled = true
	add_child(ground_ray)


func _physics_process(delta: float) -> void:
	_update_ground_state(delta)

	engine_force = lerp(engine_force, Input.get_axis("Back", "Forward") * max_engine_force, 3 * delta)

	# Steering holds its last angle only on a genuine jump, not on small bounces.
	if not _steering_locked():
		steering = lerp(steering, Input.get_axis("Right", "Left") * 0.4, 3 * delta)

	# Runs while ANY wheel is off the ground, not just in full flight: a
	# rear-wheels-only landing still needs the nose held down.
	if wheel_contacts < wheels.size():
		_air_spin(delta)

	# Log every frame near a landing - the 0.5s sampling was too coarse to tell
	# a one-frame collision impulse from a gradual loss of speed.
	if debug and (airborne or air_time_since_land < 0.6 or Engine.get_physics_frames() % 30 == 0):
		_debug_print()
	air_time_since_land = 0.0 if airborne else air_time_since_land + delta


## Wheel contact drives airborne/landing; the ray only measures height.
func _update_ground_state(delta: float) -> void:
	wheel_contacts = 0
	for wheel in wheels:
		if wheel.get_contact_body() != null:
			wheel_contacts += 1
	var grounded := wheel_contacts > 0

	if grounded:
		air_time = 0.0
	else:
		air_time += delta

	airborne = not grounded


func _steering_locked() -> bool:
	if not airborne:
		return false
	return _height_above_ground() > lockout_height or air_time > lockout_air_time


func _height_above_ground() -> float:
	if not ground_ray.is_colliding():
		return ray_length          # nothing under us: definitely high
	var dist := global_position.distance_to(ground_ray.get_collision_point())
	return dist - ride_height


## angular_velocity is in world space, so rotate it into the car's own frame
## before touching yaw/roll, then rotate the result back. orthonormalized()
## strips any scale/skew inherited from a parent, which would otherwise jitter.
## A/D drive yaw directly here: releasing them lerps toward 0, so the same
## line both spins the car and stops the spin.
func _air_spin(delta: float) -> void:
	var car_basis := global_basis.orthonormalized()
	var local_ang := car_basis.inverse() * angular_velocity
	# Yaw is player input, and only in true flight - not while two wheels bite.
	if airborne:
		var spin := Input.get_axis("Right", "Left") * air_spin_speed
		local_ang.y = lerp(local_ang.y, spin, air_spin_accel * delta)

	# Scaled by how much of the car is unsupported, so a two-wheel landing gets
	# half-strength righting instead of none, and a flat car gets none.
	var lift := 1.0 - float(wheel_contacts) / float(wheels.size())
	var pitch := Input.get_axis("Back", "Forward") if airborne else 0.0

	# Self-right: the cross product of our up axis and world up is the axis that
	# rotates one onto the other, and its length is sin(tilt) - so the torque
	# fades out as the car comes level instead of overshooting. Yaw is left
	# alone, that is the player's. (Dead flat at exactly 180 deg: sin is 0.
	# Never happens in practice, air spin breaks the tie.)
	# Level to the SURFACE, not to the world. On a ramp the car is supposed to
	# be tilted, and treating that tilt as an error makes the righting torque
	# fight the slope - which the gripping wheels convert into a yaw kick.
	# Ignore near-vertical hits (walls) and fall back to world up.
	var up_ref := Vector3.UP
	if ground_ray.is_colliding():
		var n := ground_ray.get_collision_normal()
		if n.dot(Vector3.UP) > 0.5:
			up_ref = n
	var level := car_basis.inverse() * global_basis.y.cross(up_ref)

	if absf(pitch) > 0.1:
		# Player pitch wins over self-righting, otherwise the two fight and W/S
		# feels dead. Righting takes the axis back the moment the key is released.
		local_ang.x = lerp(local_ang.x, pitch * air_pitch_speed, air_spin_accel * delta)
	else:
		local_ang.x = lerp(local_ang.x, level.x * air_level_speed * lift, air_level_accel * delta)

	local_ang.z = lerp(local_ang.z, level.z * air_level_speed * lift, air_level_accel * delta)

	if wheel_contacts == 0:
		# Free flight: nothing else is driving the body, so setting the velocity
		# outright is safe and gives crisp, predictable air control.
		angular_velocity = car_basis * local_ang
	else:
		# Wheels are gripping and the solver is computing a contact response.
		# Overwriting angular_velocity here stomps that result every frame, and
		# the solver fights back through the contacts - which scrubs off linear
		# speed and makes 1-2 wheel landings behave strangely. Torque is
		# additive, so the solver keeps its own answer and we only nudge it.
		var want := car_basis * local_ang
		apply_torque((want - angular_velocity) * mass * partial_contact_torque)


func _debug_print() -> void:
	var local_vel := global_basis.orthonormalized().inverse() * linear_velocity
	# Horizontal speed only: linear_velocity.length() includes the downward
	# component, which is *supposed* to vanish on impact and hides the real loss.
	var flat := Vector2(linear_velocity.x, linear_velocity.z).length()
	print("flat %.1f  sideways %.2f  wheels %d  air %.2f" % [
		flat, absf(local_vel.x), wheel_contacts, air_time])
