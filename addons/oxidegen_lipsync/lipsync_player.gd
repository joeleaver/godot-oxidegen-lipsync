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
## - Emotion (oxidegen prod v100+): a take timed with its emotion also has directed_curves.json (every
##   channel, played with the feeling read from its direction) and emotion_layers.json (per emotion,
##   the change from neutral). By default the line plays its directed curves; set_mood() gives it
##   another mood live: neutral + gain x layer for each emotion, eased in over `mood_time`.
## - Expression beats (oxidegen prod v102+): expression_curves.json is the face where the character
##   isn't speaking: the look it wears before the first word, the one it is left with after the
##   last, an expression on a sigh or a laugh. They are added on top of whatever the line plays
##   (x `expression`, 0 = off). The file starts `lead_in` seconds BEFORE the audio and runs `tail`
##   seconds past it: say() shows the lead-in and then starts the audio (unless `lead_in` is off),
##   and the line finishes after the tail.
##
##   $LipsyncPlayer.say(preload("res://voice/hello.wav"), "res://voice/hello")
##   # plays the clip on audio_player and its hello.mouth_curves.json / hello.face_curves.json
##   $LipsyncPlayer.play_line($Voice, LipsyncPlayer.load_curves(mouth_path), face_curves)
##   # times curves by an AudioStreamPlayer you already started
##   $LipsyncPlayer.set_mood({&"anger": 0.8})   # this line, angrier than directed ({} = as directed)

signal line_finished

const CORRECTIVES := {&"jawOpen_mouthClose": [&"min", &"jawOpen", &"mouthClose"]}
const BLINKS: Array[StringName] = [&"eyeBlinkLeft", &"eyeBlinkRight"]
## A face curve "blinks" (and idle blinks stay off) when an eyeBlink channel reaches this.
const CURVE_BLINK := 0.5
## Audio2Face-3D's emotions, the keys of an emotion_layers file and of set_mood().
const EMOTIONS: Array[StringName] = [&"amazement", &"anger", &"cheekiness", &"disgust", &"fear", &"grief",
		&"joy", &"outofbreath", &"pain", &"sadness"]

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
## Play a line's directed curves (its emotion) when it has them; off = the neutral curves.
@export var emotion := true
## Seconds to ease from one mood to another (set_mood()).
@export var mood_time := 0.4
## How strongly a line's expression beats show (expression_curves.json), 0 = not at all.
@export_range(0.0, 1.0) var expression := 1.0
## say() shows a line's lead-in (the face before its first sound) before starting the audio. Off:
## the audio starts at once (lines that follow each other closely).
@export var lead_in := true

## The current line: its curves (load_curves()) and the player whose position times them.
var mouth := {}
var face := {}
## The current line's emotion: directed curves (load_curves()) and layers (load_layers()), {} when none.
var directed := {}
var layers := {}
## The current line's expression beats (load_curves() of expression_curves.json), {} when none.
var beats := {}
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
var _mood := {}  # emotion -> the gain set_mood() asked for
var _gains := {}  # emotion -> the gain now (easing toward _mood)
var _mood_mix := 0.0  # 0 = the line as directed, 1 = neutral + the mood's layers
var _ease_secs := 0.4
var _lead := 0.0  # seconds of lead-in left before say() starts the audio
var _started := false  # the audio has played (so a stop is the line's end, not a late start)


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
		# expression_curves: frame 0 is `offset` seconds from the audio's start (<= 0)
		"offset": float(d.get("offset", 0.0)),
		"lead_in": float(d.get("lead_in", 0.0)),
		"tail": float(d.get("tail", 0.0)),
	}


## An oxidegen emotion_layers file: {fps, frames, duration, layers: {emotion: {name:
## PackedFloat32Array of deltas from neutral}}}; {} when missing or not layers.
static func load_layers(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not d is Dictionary or not (d as Dictionary).has("layers"):
		return {}
	var out := {}
	for e: String in d.layers:
		var ch := {}
		for n: String in d.layers[e]:
			ch[StringName(n)] = PackedFloat32Array(d.layers[e][n])
		out[StringName(e)] = ch
	var fps := float(d.get("fps", 30.0))
	var frames := int(d.get("frames", 0))
	return {"fps": fps, "frames": frames, "duration": float(d.get("duration", frames / fps)), "layers": out}


## The curves files of a line: <base>.mouth_curves.json and <base>.face_curves.json, where base is
## the clip's path without its extension: [mouth, face] (each {} when absent).
static func curves_for(clip_path: String) -> Array[Dictionary]:
	var base := clip_path.get_basename()
	return [load_curves(base + ".mouth_curves.json"), load_curves(base + ".face_curves.json")]


## A line's emotion files next to the clip: [<base>.directed_curves.json (load_curves()),
## <base>.emotion_layers.json (load_layers())] (each {} when absent: a take timed before v100).
static func emotion_for(clip_path: String) -> Array[Dictionary]:
	var base := clip_path.get_basename()
	return [load_curves(base + ".directed_curves.json"), load_layers(base + ".emotion_layers.json")]


## One layer set's deltas at `t` seconds (sample() over each emotion's channels).
static func sample_layers(l: Dictionary, t: float) -> Dictionary:
	var out := {}
	if l.is_empty():
		return out
	for e: StringName in l.layers:
		out[e] = sample({"fps": l.fps, "curves": l.layers[e]}, t)
	return out


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


## The line's neutral weights at `t` (mouth over face where both have one).
## A line's expression beats next to the clip: <base>.expression_curves.json (load_curves(); {} when
## absent: a take timed before v102, or a line with no feeling and no events).
static func expression_for(clip_path: String) -> Dictionary:
	return load_curves(clip_path.get_basename() + ".expression_curves.json")


func neutral_at(t: float) -> Dictionary:
	var w := sample(face, t)
	w.merge(sample(mouth, t), true)
	return w


## The face's weights for the current line at `t` seconds: its directed curves (or neutral, without
## them or with `emotion` off), blended toward neutral + the mood's layers while a mood is set.
func pose_at(t: float) -> Dictionary:
	var neutral := neutral_at(t)
	var base := sample(directed, t) if emotion and not directed.is_empty() else neutral
	if _mood_mix <= 0.0 or layers.is_empty():
		return with_correctives(_with_beats(base, t))
	var moody := neutral.duplicate()
	var deltas := sample_layers(layers, t)
	for e: StringName in _gains:
		var g := float(_gains[e])
		if g == 0.0 or not deltas.has(e):
			continue
		for n: StringName in deltas[e]:
			moody[n] = float(moody.get(n, 0.0)) + g * float(deltas[e][n])
	var w := {}
	for n: StringName in base.keys() + moody.keys():
		w[n] = lerpf(float(base.get(n, 0.0)), clampf(float(moody.get(n, 0.0)), 0.0, 1.0), _mood_mix)
	return with_correctives(_with_beats(w, t))


## `w` with the line's expression beats at `t` added (x `expression`), clamped.
func _with_beats(w: Dictionary, t: float) -> Dictionary:
	if beats.is_empty() or expression <= 0.0:
		return w
	var b := sample(beats, t - float(beats.get("offset", 0.0)))
	for n: StringName in b:
		w[n] = clampf(float(w.get(n, 0.0)) + expression * float(b[n]), 0.0, 1.0)
	return w


## Gives the line (and the lines after it) this mood: emotion -> gain 0..1 over the line's
## emotion layers (e.g. {&"anger": 0.8, &"fear": 0.2}), eased in over `mood_time`. {} = back to the
## line as directed. Takes without emotion layers ignore it.
func set_mood(gains: Dictionary, ease_time := -1.0) -> void:
	_mood = {}
	for e in gains:
		var k := StringName(e)
		if EMOTIONS.has(k):
			_mood[k] = clampf(float(gains[e]), 0.0, 1.0)
	_ease_secs = ease_time if ease_time >= 0.0 else mood_time
	if _ease_secs <= 0.0:
		_gains = _mood.duplicate()
		_mood_mix = 1.0 if _mood_on() else 0.0
		return
	if _mood_mix <= 0.0:
		_gains = _mood.duplicate()  # from the line as directed: only the mix eases
		return
	for e: StringName in _mood:
		if not _gains.has(e):
			_gains[e] = 0.0  # a new emotion joins a mood already showing: it grows in


## The mood set_mood() asked for.
func mood() -> Dictionary:
	return _mood.duplicate()


func _mood_on() -> bool:
	for e: StringName in _mood:
		if float(_mood[e]) > 0.0:
			return true
	return false



## Eases the mood's gains and mix toward what set_mood() asked for.
func _ease_mood(delta: float) -> void:
	var r := 1.0 if _ease_secs <= 0.0 else delta / _ease_secs
	_mood_mix = move_toward(_mood_mix, 1.0 if _mood_on() else 0.0, r)
	if _mood_mix <= 0.0:
		_gains = _mood.duplicate()  # nothing shows: jump straight to the new gains
		return
	for e: StringName in _gains.keys():
		var to := float(_mood.get(e, 0.0)) if _mood_on() else float(_gains[e])
		_gains[e] = move_toward(float(_gains[e]), to, r)


## Plays `stream` on audio_player and its curves (curves_for(`curves_base`), default the stream's
## own path). Returns false (and plays nothing) without an audio player.
func say(stream: AudioStream, curves_base := "") -> bool:
	var p := get_node_or_null(audio_player)
	if p == null:
		return false
	var base := curves_base if curves_base != "" else stream.resource_path
	var c := curves_for(base)
	var e := emotion_for(base)
	var x := expression_for(base)
	p.stream = stream
	var lead := float(x.get("lead_in", 0.0)) if lead_in and expression > 0.0 else 0.0
	if lead <= 0.0:
		p.play()
	play_line(p, c[0], c[1], e[0], e[1], x)
	_lead = lead  # step() shows the lead-in, then starts the audio
	_started = lead <= 0.0
	if lead > 0.0:
		line_time = -lead
	return true


## Plays a line's curves timed by `player`'s position (call right after the audio starts); with its
## emotion files (emotion_for()) it plays as directed, or in the mood set_mood() set.
## `expression_curves` (expression_for()) adds its beats; the audio is already playing, so there is no
## lead-in here, only the tail after the audio ends.
func play_line(player: Node, mouth_curves: Dictionary, face_curves := {}, directed_curves := {},
		emotion_layers := {}, expression_curves := {}) -> void:
	audio = player
	mouth = mouth_curves
	face = face_curves
	directed = directed_curves
	layers = emotion_layers
	beats = expression_curves
	line_time = 0.0
	_lead = 0.0
	_started = true
	_fade = 0.0


## Ends the current line: its shapes ease to neutral.
func stop_line() -> void:
	if mouth.is_empty() and face.is_empty() and directed.is_empty() and beats.is_empty():
		return
	mouth = {}
	face = {}
	directed = {}
	layers = {}
	beats = {}
	audio = null
	line_time = -1.0
	_lead = 0.0
	_fade_from = _set.duplicate()
	_fade = 1.0
	line_finished.emit()


func duration() -> float:
	return maxf(maxf(float(mouth.get("duration", 0.0)), float(face.get("duration", 0.0))),
			float(directed.get("duration", 0.0)))


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
	_ease_mood(delta)
	var w := {}
	var playing := not (mouth.is_empty() and face.is_empty() and directed.is_empty())
	if playing and _lead > 0.0:  # the face before the line's first sound; then the audio starts
		_lead -= delta
		if _lead <= 0.0:
			_lead = 0.0
			_started = true
			audio.play()
			line_time = 0.0
		else:
			line_time = -_lead
		w = pose_at(line_time)
	elif playing:
		var t := audio_time()
		var tail := float(beats.get("tail", 0.0)) if expression > 0.0 else 0.0
		if t >= 0.0 and t <= duration():
			line_time = t
			w = pose_at(t)
		elif tail > 0.0 and line_time >= duration() - 0.25 and line_time + delta < duration() + tail:
			line_time += delta  # the audio ran out: the face it is left with, on our own clock
			w = pose_at(line_time)
		else:
			stop_line()
			playing = false
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


## The current line's curves (face, or directed when it plays) close the eyes themselves.
func _curves_blink() -> bool:
	for c: Dictionary in [face, directed if emotion else {}]:
		if c.is_empty():
			continue
		for n in BLINKS:
			var a: PackedFloat32Array = c.curves.get(n, PackedFloat32Array())
			for v in a:
				if v >= CURVE_BLINK:
					return true
	return false
