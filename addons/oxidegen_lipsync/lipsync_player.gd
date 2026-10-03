@icon("res://addons/oxidegen_lipsync/icon.svg")
class_name LipsyncPlayer
extends Node
## Lip sync for Godot 4: drives a character's face shapes (blend shapes with ARKit names, e.g.
## jawOpen, mouthFunnel, eyeBlinkLeft) from a voiced line's oxidegen curves (mouth_curves.json and
## face_curves.json: weights per ARKit name, 30 fps) in sync with the line's audio. Each frame it
## samples the curves at the audio player's playback position, interpolating between frames.
## Any character whose meshes carry ARKit-named blend shapes works; on meshes without any it does
## nothing.
## - Correctives (hifipushie faceshapes.py CORRECTIVES): shapes whose weight is a function of
##   others, set here when a mesh has them (jawOpen_mouthClose = min(jawOpen, mouthClose)).
## - When the line ends (or its audio stops) the shapes it drove ease back to neutral over
##   `release` seconds.
## - Idle blinks every few seconds, except while a line's face curves blink the eyes themselves.
##
##   $LipsyncPlayer.say(preload("res://voice/hello.wav"), "res://voice/hello")
##   # plays the clip on audio_player and its hello.mouth_curves.json / hello.face_curves.json
##   $LipsyncPlayer.play_line($Voice, LipsyncPlayer.load_curves(mouth_path), face_curves)
##   # times curves by an AudioStreamPlayer you already started

signal line_finished

const CORRECTIVES := {&"jawOpen_mouthClose": [&"min", &"jawOpen", &"mouthClose"]}
const BLINKS: Array[StringName] = [&"eyeBlinkLeft", &"eyeBlinkRight"]
## A face curve "blinks" (and idle blinks stay off) when an eyeBlink channel reaches this.
const CURVE_BLINK := 0.5

## Where the face's meshes are (every MeshInstance3D under it, recursively).
@export var face_root: NodePath = ^".."
## The player say() plays clips on (AudioStreamPlayer, AudioStreamPlayer2D or 3D).
@export var audio_player: NodePath
## Seconds to ease back to neutral when a line ends.
@export var release := 0.25
## Idle blinks: seconds between them (random in this range) and how long one takes.
@export var blinks := true
@export var blink_interval := Vector2(2.0, 6.0)
@export var blink_time := 0.18

## The current line: its curves (load_curves()) and the player whose position times them.
var mouth := {}
var face := {}
var audio: Node  # AudioStreamPlayer, AudioStreamPlayer2D or AudioStreamPlayer3D
## Seconds into the current line (from the audio), -1 when none plays.
var line_time := -1.0
var rng := RandomNumberGenerator.new()

var _shapes := {}  # name -> Array of [MeshInstance3D, blend shape index]
var _set := {}  # name -> the weight we last set
var _fade := 0.0  # 1 -> 0 while easing to neutral
var _fade_from := {}
var _blink_in := 0.0  # seconds to the next idle blink
var _blink_t := -1.0  # seconds into the current blink, -1 when none


func _ready() -> void:
	rng.randomize()
	_blink_in = rng.randf_range(blink_interval.x, blink_interval.y)
	find_shapes()


## Finds the ARKit-named (and corrective) blend shapes on the meshes under face_root.
func find_shapes() -> void:
	_shapes = {}
	var r := get_node_or_null(face_root)
	if r == null:
		return
	for mi: MeshInstance3D in r.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_blend_shape_count():
			var n := StringName(mi.mesh.get_blend_shape_name(i))
			if not _shapes.has(n):
				_shapes[n] = []
			_shapes[n].append([mi, i])


## True when the face has shapes to drive.
func has_face() -> bool:
	return not _shapes.is_empty()


func has_shape(n: StringName) -> bool:
	return _shapes.has(n)


## An oxidegen curves file (mouth_curves / face_curves): {fps, frames, duration, curves: {name:
## PackedFloat32Array}}; {} when missing or not curves.
static func load_curves(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not d is Dictionary or not (d as Dictionary).has("curves"):
		return {}
	var curves := {}
	for n: String in d.curves:
		curves[StringName(n)] = PackedFloat32Array(d.curves[n])
	var fps := float(d.get("fps", 30.0))
	var frames := int(d.get("frames", 0))
	return {
		"fps": fps,
		"frames": frames,
		"duration": float(d.get("duration", frames / fps)),
		"curves": curves,
	}


## The curves files of a line: <base>.mouth_curves.json and <base>.face_curves.json, where base is
## the clip's path without its extension: [mouth, face] (each {} when absent).
static func curves_for(clip_path: String) -> Array[Dictionary]:
	var base := clip_path.get_basename()
	return [load_curves(base + ".mouth_curves.json"), load_curves(base + ".face_curves.json")]


## Every channel of `c` at `t` seconds, interpolated between frames (held at the ends).
static func sample(c: Dictionary, t: float) -> Dictionary:
	var out := {}
	if c.is_empty():
		return out
	var f := maxf(t, 0.0) * float(c.fps)
	var i := int(floor(f))
	var k := f - i
	for n: StringName in c.curves:
		var a: PackedFloat32Array = c.curves[n]
		if a.is_empty():
			continue
		var i0 := mini(i, a.size() - 1)
		var i1 := mini(i + 1, a.size() - 1)
		out[n] = lerpf(a[i0], a[i1], k)
	return out


## ARKit weights -> the weights to set, correctives filled in (faceshapes.playback()).
static func with_correctives(w: Dictionary) -> Dictionary:
	var out := w.duplicate()
	for n: StringName in CORRECTIVES:
		var c: Array = CORRECTIVES[n]
		if c[0] == &"min":
			out[n] = minf(float(w.get(c[1], 0.0)), float(w.get(c[2], 0.0)))
	return out


## The face's weights for the current line at `t` seconds (mouth over face where both have one).
func pose_at(t: float) -> Dictionary:
	var w := sample(face, t)
	w.merge(sample(mouth, t), true)
	return with_correctives(w)


## Plays `stream` on audio_player and its curves (curves_for(`curves_base`), default the stream's
## own path). Returns false (and plays nothing) without an audio player.
func say(stream: AudioStream, curves_base := "") -> bool:
	var p := get_node_or_null(audio_player)
	if p == null:
		return false
	var c := curves_for(curves_base if curves_base != "" else stream.resource_path)
	p.stream = stream
	p.play()
	play_line(p, c[0], c[1])
	return true


## Plays a line's curves timed by `player`'s position (call right after the audio starts).
func play_line(player: Node, mouth_curves: Dictionary, face_curves := {}) -> void:
	audio = player
	mouth = mouth_curves
	face = face_curves
	line_time = 0.0
	_fade = 0.0


## Ends the current line: its shapes ease to neutral.
func stop_line() -> void:
	if mouth.is_empty() and face.is_empty():
		return
	mouth = {}
	face = {}
	audio = null
	line_time = -1.0
	_fade_from = _set.duplicate()
	_fade = 1.0
	line_finished.emit()


func duration() -> float:
	return maxf(float(mouth.get("duration", 0.0)), float(face.get("duration", 0.0)))


## Seconds into the audio: its playback position plus what has played since the last mix.
func audio_time() -> float:
	if audio == null or not audio.playing:
		return -1.0
	var t: float = audio.get_playback_position()
	t += AudioServer.get_time_since_last_mix() - AudioServer.get_output_latency()
	return maxf(t, 0.0)


func _process(delta: float) -> void:
	step(delta)


## One frame: the line's pose at the audio's position (or the ease to neutral), idle blinks.
func step(delta: float) -> void:
	if not has_face():
		return
	var w := {}
	var playing := not (mouth.is_empty() and face.is_empty())
	if playing:
		var t := audio_time()
		if t < 0.0 or t > duration():
			stop_line()
			playing = false
		else:
			line_time = t
			w = pose_at(t)
	if not playing and _fade > 0.0:
		_fade = maxf(_fade - delta / maxf(release, 0.001), 0.0)
		var s := smoothstep(0.0, 1.0, _fade)
		for n: StringName in _fade_from:
			w[n] = _fade_from[n] * s
	_blink(delta, w)
	apply(w)


## Sets these weights on every mesh that has the shape.
func apply(w: Dictionary) -> void:
	for n: StringName in w:
		var on: Array = _shapes.get(n, [])
		var v := clampf(float(w[n]), 0.0, 1.0)
		for s: Array in on:
			(s[0] as MeshInstance3D).set_blend_shape_value(s[1], v)
		if not on.is_empty():
			_set[n] = v


## The weight a shape has now (what was last set; 0 when never).
func weight(n: StringName) -> float:
	return float(_set.get(n, 0.0))


func _blink(delta: float, w: Dictionary) -> void:
	if not blinks or not (has_shape(BLINKS[0]) or has_shape(BLINKS[1])):
		return
	if _curves_blink():
		_blink_t = -1.0
		return
	if _blink_t < 0.0:
		_blink_in -= delta
		if _blink_in > 0.0:
			return
		_blink_t = 0.0
		_blink_in = rng.randf_range(blink_interval.x, blink_interval.y)
	_blink_t += delta
	var k := _blink_t / blink_time
	var b := 0.0
	if k < 0.4:
		b = smoothstep(0.0, 1.0, k / 0.4)
	elif k < 1.0:
		b = 1.0 - smoothstep(0.0, 1.0, (k - 0.4) / 0.6)
	else:
		_blink_t = -1.0
	for n in BLINKS:
		w[n] = maxf(float(w.get(n, 0.0)), b)


## The current line's face curves close the eyes themselves.
func _curves_blink() -> bool:
	if face.is_empty():
		return false
	for n in BLINKS:
		var a: PackedFloat32Array = face.curves.get(n, PackedFloat32Array())
		for v in a:
			if v >= CURVE_BLINK:
				return true
	return false
