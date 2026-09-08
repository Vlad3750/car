extends VehicleBody3D

# --- Tunables (Inspector) ---
@export_group("Air Control")
## Peak air-spin rate (rad/s) A/D can drive the car to while airborne.
@export var air_spin_speed := 4.0
## How fast air spin reaches (and falls back from) that rate.
@export var air_spin_accel := 6.0
## Roll (Z) is scaled toward this fraction of itself while airborne.
@export var air_roll_scale := 0.3
## How fast roll settles toward that fraction.
@export var air_roll_damp := 5.0

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

@export_group("Landing Drift")
## Landing faster than this (m/s) breaks traction.
@export var drift_landing_speed_threshold := 12.0
## wheel_friction_slip is multiplied by this on a hard landing.
@export var drift_friction_multiplier := 0.35
## Seconds to lerp friction back to the stored originals.
@export var drift_recovery_time := 1.2

@onready var wheels: Array[VehicleWheel3D] = [$Front_Left, $Front_Right, $Back_Left, $Back_Right]

var ground_ray: RayCast3D
var base_friction: Array[float] = []   # per-wheel originals, wheels may differ
var airborne := false
var air_time := 0.0
var drift_timer := 0.0                 # counts down through the recovery lerp


func _ready() -> void:
	for wheel in wheels:
		base_friction.append(wheel.wheel_friction_slip)

	# Created in code so there is nothing to add by hand in the editor.
	ground_ray = RayCast3D.new()
	ground_ray.name = "GroundRay"
	ground_ray.target_position = Vector3(0, -ray_length, 0)
	ground_ray.exclude_parent = true      # never hit our own body
	ground_ray.enabled = true
	add_child(ground_ray)


func _physics_process(delta: float) -> void:
	_update_ground_state(delta)

	engine_force = lerp(engine_force, Input.get_axis("Back", "Forward") * 100, 3 * delta)

	# Steering holds its last angle only on a genuine jump, not on small bounces.
	if not _steering_locked():
		steering = lerp(steering, Input.get_axis("Right", "Left") * 0.4, 3 * delta)

	if airborne:
		_air_spin(delta)

	_recover_friction(delta)


## Wheel contact drives airborne/landing; the ray only measures height.
func _update_ground_state(delta: float) -> void:
	var grounded := false
	for wheel in wheels:
		if wheel.get_contact_body() != null:
			grounded = true
			break

	if grounded:
		if airborne:
			_on_landed()
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
	var spin := Input.get_axis("Right", "Left") * air_spin_speed
	local_ang.y = lerp(local_ang.y, spin, air_spin_accel * delta)
	local_ang.z = lerp(local_ang.z, local_ang.z * air_roll_scale, air_roll_damp * delta)
	angular_velocity = car_basis * local_ang


func _on_landed() -> void:
	if linear_velocity.length() < drift_landing_speed_threshold:
		return                     # gentle landing keeps full grip
	for i in wheels.size():
		wheels[i].wheel_friction_slip = base_friction[i] * drift_friction_multiplier
	drift_timer = drift_recovery_time


func _recover_friction(delta: float) -> void:
	if drift_timer <= 0.0:
		return
	drift_timer = max(drift_timer - delta, 0.0)
	var t := 1.0 - drift_timer / drift_recovery_time   # 0 at landing -> 1 when recovered
	for i in wheels.size():
		var low := base_friction[i] * drift_friction_multiplier
		wheels[i].wheel_friction_slip = lerp(low, base_friction[i], t)
