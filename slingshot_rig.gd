extends Node3D

## Slingshot launcher. The car sits in the pouch, you drag with the left mouse
## button to pull back and aim, and releasing fires the car along the line from
## the pouch back to its rest position. Bands stretch to follow the pouch.
##
## Each band's ORIGIN must sit at its fork-tip end (set in Blender): a band is
## rotated and scaled about its origin, so an origin anywhere else makes it
## swing from the wrong point.

## Leave empty to auto-find a sibling named "Car".
@export var car: RigidBody3D
## Node names inside the imported model, found by name at startup.
@export var pouch_name := "Pouch"
@export var band_names: Array[String] = ["BandL", "BandR", "WrapPouchL", "WrapPouchR"]

@export_group("Aiming")
## Furthest the pouch can travel from its rest position, in model units. This
## caps the TOTAL draw, so it is also what limits how far the bands stretch.
@export var max_draw := 2.5
## Model units of pull per pixel of mouse movement.
@export var drag_sensitivity := 0.03
## Launch speed per unit of draw. Multiplied by mass, so it survives retuning.
@export var launch_power := 4.0
## How far the pouch pulls BACK per unit of up/down/sideways aim. 1.0 fires at
## 45 degrees, higher flattens the shot toward the horizon. The launch runs
## along the draw, so this is the trajectory as well as the pouch motion.
@export var pull_ratio := 2.5
## Car origin height above the pouch origin, in WORLD units. The car's chassis
## bottom is 0.26 below its origin, so this seats it on the cradle.
@export var car_height := 0.31
## Press this to put the car back in the pouch for another shot.
@export var reset_key := KEY_R

enum State { AIMING, FLYING }

var state := State.AIMING
var dragging := false
var drag := Vector2.ZERO
var pouch: Node3D
var pouch_rest := Vector3.ZERO
var bands: Array[Node3D] = []
var rest_dir: Array[Vector3] = []
var rest_len: Array[float] = []
var rest_basis: Array[Basis] = []
var axis_index: Array[int] = []
var is_rider: Array[bool] = []      # slides to the pouch instead of stretching
var anchor: Array[Vector3] = []     # fork-tip position, fixed
var rest_axis: Array[Vector3] = []  # the band's own length axis, at rest


func _ready() -> void:
	if car == null:
		car = get_parent().get_node_or_null("Car")
	pouch = find_child(pouch_name, true, false)
	for n in band_names:
		var b := find_child(n, true, false)
		if b == null:
			push_warning("slingshot_rig: no node named '%s' in the model" % n)
		else:
			bands.append(b)

	if pouch == null or bands.is_empty() or car == null:
		push_warning("slingshot_rig: missing pouch, bands or car")
		set_process(false)
		return

	pouch_rest = pouch.position
	for band in bands:
		var d := pouch.global_position - band.global_position
		var l := d.length()
		if l < 0.001:
			push_warning("slingshot_rig: %s origin is on the pouch - set its origin to the fork tip" % band.name)
			l = 1.0
			d = Vector3.UP
		rest_dir.append(d / l)
		rest_basis.append(band.global_basis)
		anchor.append(band.global_position)
		# Whichever local axis runs along the band is the one to stretch.
		var b := band.global_basis
		var dots := [absf(b.x.dot(d) / l), absf(b.y.dot(d) / l), absf(b.z.dot(d) / l)]
		var ax: int = dots.find(dots.max())
		axis_index.append(ax)
		# Aim the band's OWN length axis, not the anchor-to-pouch line. They are
		# close but not identical, and scaling along one while rotating by the
		# other leaves a gap that grows the further the pouch is drawn.
		var cols := [b.x, b.y, b.z]
		var col: Vector3 = cols[ax]
		if col.dot(d) < 0.0:
			col = -col              # point it along the band, not back up it
		rest_axis.append(col.normalized())
		# Two kinds of part. A BAND's geometry starts at its origin, so it is
		# stretched to span the gap. A WRAP sits bunched near the far end with
		# empty space between it and the origin - stretching that scales it
		# about a distant point and throws it across the level, so it is slid
		# along instead, keeping its size.
		var near := 0.0
		var far := 1.0
		if band is MeshInstance3D:
			var ab: AABB = band.get_aabb()
			near = ab.position[ax]
			far = ab.position[ax] + ab.size[ax]
		# far is in the model's own units; the gap we measure against it is in
		# global units, and a scaled Slingshot node makes those differ. Convert
		# once here so every later comparison is like for like.
		var sc: float = band.global_basis.get_scale()[ax]
		rest_len.append(maxf(far * sc, 0.001))
		is_rider.append(far > 0.001 and near / far > 0.5)

	_reset()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == reset_key:
		_reset()
		return
	if state != State.AIMING:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			dragging = true
			drag = Vector2.ZERO
		elif dragging:
			dragging = false
			_launch()
	elif event is InputEventMouseMotion and dragging:
		drag += event.relative


func _process(_delta: float) -> void:
	if state == State.AIMING:
		pouch.position = pouch_rest + _draw_offset()
		# Car rides in the cradle. NOT frozen: freezing a VehicleBody3D stops
		# the vehicle simulation and collapses every wheel transform onto the
		# body origin - the wheels vanish inside the chassis and do not come
		# back on unfreeze. Killing gravity and velocity holds it just as still.
		car.global_position = pouch.global_position + global_basis.y.normalized() * car_height
		car.linear_velocity = Vector3.ZERO
		car.angular_velocity = Vector3.ZERO

	for i in bands.size():
		_stretch(bands[i], i)


## Pull vector in the slingshot's own space. The pouch follows the mouse
## directly: drag up and it rises, drag down and it drops. Screen Y grows
## downward, hence the negation. The backward pull grows with the drag
## distance, so aim and power are one gesture.
func _draw_offset() -> Vector3:
	var aim := Vector3(-drag.x, -drag.y, 0.0) * drag_sensitivity
	var o := Vector3(aim.x, aim.y, -aim.length() * pull_ratio)
	# Clamp the whole draw, not just the sideways part: pull_ratio multiplies
	# the backward pull, so clamping only the aim let the pouch run far past
	# max_draw and stretched the bands to several times their length.
	if o.length() > max_draw:
		o = o.normalized() * max_draw
	return o


func _launch() -> void:
	var offset := _draw_offset()
	var pull := offset.length()
	if pull < 0.01:
		return                       # a click with no drag is not a shot

	state = State.FLYING
	car.gravity_scale = 1.0
	# Fire back along the draw: the further you pulled, the harder it goes.
	var dir := (global_basis * -offset).normalized()
	car.apply_central_impulse(dir * launch_power * pull * car.mass)
	drag = Vector2.ZERO
	pouch.position = pouch_rest


func _reset() -> void:
	state = State.AIMING
	dragging = false
	drag = Vector2.ZERO
	pouch.position = pouch_rest
	car.freeze = false
	car.gravity_scale = 0.0
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	# Face the car the way the slingshot fires.
	# orthonormalized: global_basis carries this node's scale, and assigning it
	# raw stamps that scale onto the car - a 0.3 Slingshot shrank the car to
	# 30% and dragged its wheels in with it.
	car.global_transform = Transform3D(global_basis.orthonormalized(), pouch.global_position + global_basis.y.normalized() * car_height)


func _stretch(band: Node3D, i: int) -> void:
	var d := pouch.global_position - anchor[i]
	var l := d.length()
	if l < 0.001:
		return
	var dir := d / l
	# Quaternion(a, b) is undefined when the vectors are exactly opposite, and
	# a NaN basis makes the mesh vanish. Nudge off the singularity.
	if rest_axis[i].dot(dir) < -0.9999:
		dir = (dir + Vector3(0.001, 0.001, 0.0)).normalized()
	var rot := Basis(Quaternion(rest_axis[i], dir))
	if is_rider[i]:
		# Keep its size, just carry it out to where the pouch now is.
		band.global_basis = rot * rest_basis[i]
		band.global_position = anchor[i] + dir * (l - rest_len[i])
	else:
		var s := Vector3.ONE
		s[axis_index[i]] = l / rest_len[i]
		# Multiply on the RIGHT so the stretch happens along the band's own
		# length axis. Basis.scaled() scales the rows, i.e. in global space,
		# which on a rotated band stretches it diagonally - wrong length, and
		# it tapers into a cone.
		band.global_basis = rot * (rest_basis[i] * Basis.from_scale(s))
