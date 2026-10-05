extends GutTest
## LipsyncPlayer: curve loading and sampling, correctives, sync by the audio's playback position,
## the ease to neutral at the end, idle blinks, and no-op on meshes without face shapes.

const LINE := "res://test/fixtures/line"
const FACE_SHAPES: Array[String] = [
	"jawOpen",
	"mouthClose",
	"mouthFunnel",
	"jawOpen_mouthClose",
	"browInnerUp",
	"eyeBlinkLeft",
	"eyeBlinkRight"
]

var character: Node3D
var face_mesh: MeshInstance3D
var lips: LipsyncPlayer
var voice: AudioStreamPlayer


func after_each() -> void:
	if is_instance_valid(character):
		character.free()


## A stand-in character: one mesh (with `shapes` as blend shapes), a voice player and the
## LipsyncPlayer, in the tree.
func _character(shapes: Array[String] = FACE_SHAPES) -> void:
	character = Node3D.new()
	face_mesh = MeshInstance3D.new()
	face_mesh.mesh = _mesh(shapes)
	character.add_child(face_mesh)
	voice = AudioStreamPlayer.new()
	voice.name = "Voice"
	character.add_child(voice)
	lips = LipsyncPlayer.new()
	lips.audio_player = ^"../Voice"
	lips.blinks = false
	character.add_child(lips)
	add_child(character)
	await wait_process_frames(1)
	lips.set_process(false)  # the tests step it


## One triangle with these blend shapes (each moves it up 1 cm).
func _mesh(shapes: Array[String]) -> ArrayMesh:
	var m := ArrayMesh.new()
	var v := PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	var blends := []
	for s in shapes:
		m.add_blend_shape(s)
		var b := []
		b.resize(Mesh.ARRAY_MAX)
		var moved := PackedVector3Array()
		for p in v:
			moved.append(p + Vector3(0, 0.01, 0))
		b[Mesh.ARRAY_VERTEX] = moved
		blends.append(b)
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, blends)
	return m


## Silence, `seconds` long.
func _wav(seconds: float) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = 22050
	var d := PackedByteArray()
	d.resize(int(22050 * seconds) * 2)
	w.data = d
	return w


func _shape(n: String) -> float:
	return face_mesh.get_blend_shape_value(face_mesh.find_blend_shape_by_name(n))


func test_loads_oxidegen_curves() -> void:
	var c := LipsyncPlayer.load_curves(LINE + ".mouth_curves.json")
	assert_eq(c.fps, 30.0)
	assert_eq(c.frames, 90)
	assert_almost_eq(c.duration, 3.0, 0.001)
	assert_true(c.curves[&"jawOpen"] is PackedFloat32Array, "a channel per ARKit name")
	assert_eq((c.curves[&"jawOpen"] as PackedFloat32Array).size(), 90)
	assert_eq(LipsyncPlayer.load_curves("res://test/fixtures/missing.json"), {}, "missing: {}")
	assert_eq(LipsyncPlayer.load_curves("res://test/fixtures/not_curves.json"), {}, "not curves")
	var both := LipsyncPlayer.curves_for(LINE + ".wav")
	assert_false(both[0].is_empty(), "mouth curves next to the clip")
	assert_true(both[1].curves.has(&"browInnerUp"), "face curves next to the clip")


func test_samples_between_frames_and_holds_the_ends() -> void:
	var c := LipsyncPlayer.load_curves(LINE + ".mouth_curves.json")
	var a: PackedFloat32Array = c.curves[&"jawOpen"]
	var w := LipsyncPlayer.sample(c, 10.5 / 30.0)
	assert_almost_eq(w[&"jawOpen"], (a[10] + a[11]) / 2.0, 0.0005, "halfway between frames")
	assert_almost_eq(LipsyncPlayer.sample(c, 99.0)[&"jawOpen"], a[89], 0.0001, "held at the end")
	assert_almost_eq(LipsyncPlayer.sample(c, -1.0)[&"jawOpen"], a[0], 0.0001, "and the start")


func test_correctives() -> void:
	var w := LipsyncPlayer.with_correctives({&"jawOpen": 0.8, &"mouthClose": 0.5})
	assert_almost_eq(w[&"jawOpen_mouthClose"], 0.5, 0.0001, "min(jawOpen, mouthClose)")
	w = LipsyncPlayer.with_correctives({&"mouthClose": 1.0})
	assert_almost_eq(w[&"jawOpen_mouthClose"], 0.0, 0.0001, "jaw shut: no closing")


func test_follows_the_audio_position() -> void:
	await _character()
	var c := LipsyncPlayer.curves_for(LINE + ".wav")
	voice.stream = _wav(3.0)
	voice.play(1.0)
	lips.play_line(voice, c[0], c[1])
	lips.step(0.0)
	var t := lips.audio_time()
	assert_almost_eq(t, 1.0, 0.15, "timed by the player's position")
	assert_almost_eq(lips.line_time, t, 0.001)
	var want := lips.pose_at(lips.line_time)
	assert_almost_eq(_shape("jawOpen"), want[&"jawOpen"], 0.0001, "the mouth at that time")
	assert_almost_eq(_shape("jawOpen_mouthClose"), minf(want[&"jawOpen"], 0.5), 0.0001)
	assert_almost_eq(_shape("browInnerUp"), 0.3, 0.0001, "face curves too")
	voice.seek(2.0)
	lips.step(0.0)
	assert_almost_eq(lips.line_time, 2.0, 0.15, "a seek moves the face with it")
	assert_almost_eq(_shape("jawOpen"), lips.pose_at(lips.line_time)[&"jawOpen"], 0.0001)
	assert_gt(_shape("jawOpen"), 0.6, "later in the line: more open (the ramp)")


func test_eases_to_neutral_when_the_line_ends() -> void:
	await _character()
	watch_signals(lips)
	assert_true(lips.say(_wav(3.0), LINE), "say() plays on the audio player")
	assert_true(voice.playing)
	voice.seek(2.5)
	lips.step(0.0)
	var open := _shape("jawOpen")
	assert_gt(open, 0.5)
	voice.stop()
	lips.step(0.05)
	assert_signal_emitted(lips, "line_finished")
	assert_between(_shape("jawOpen"), 0.01, open, "easing, not snapping")
	for i in 10:
		lips.step(0.05)
	for n in ["jawOpen", "mouthClose", "jawOpen_mouthClose", "browInnerUp", "eyeBlinkLeft"]:
		assert_almost_eq(_shape(n), 0.0, 0.0001, "%s back to neutral" % n)


func test_idle_blinks_between_lines() -> void:
	await _character()
	lips.blinks = true
	lips.blink_interval = Vector2(0.2, 0.2)
	lips._blink_in = 0.2
	var most := 0.0
	var steps := 0
	while steps < 30:
		lips.step(1.0 / 60.0)
		most = maxf(most, _shape("eyeBlinkLeft"))
		steps += 1
	assert_gt(most, 0.95, "the eyes close")
	assert_almost_eq(_shape("eyeBlinkRight"), _shape("eyeBlinkLeft"), 0.0001, "both eyes")
	assert_lt(_shape("eyeBlinkLeft"), 0.05, "and open again")


func test_curves_that_blink_take_over_from_idle_blinks() -> void:
	await _character()
	lips.blinks = true
	lips._blink_in = 0.0
	var c := LipsyncPlayer.curves_for(LINE + ".wav")
	(c[1].curves[&"eyeBlinkLeft"] as PackedFloat32Array).set(80, 1.0)
	voice.stream = _wav(3.0)
	voice.play(0.5)
	lips.play_line(voice, c[0], c[1])
	for i in 10:
		lips.step(1.0 / 60.0)
	assert_almost_eq(_shape("eyeBlinkLeft"), 0.1, 0.0001, "the curve's eyes, no idle blink")


func test_no_op_without_face_shapes() -> void:
	await _character([])
	assert_false(lips.has_face())
	var c := LipsyncPlayer.curves_for(LINE + ".wav")
	voice.stream = _wav(3.0)
	voice.play()
	lips.play_line(voice, c[0], c[1])
	lips.blinks = true
	for i in 5:
		lips.step(0.1)
	assert_eq(face_mesh.mesh.get_blend_shape_count(), 0)
	assert_eq(lips.weight(&"jawOpen"), 0.0, "nothing set")
	var bare := LipsyncPlayer.new()  # no face_root at all
	add_child_autofree(bare)
	bare.face_root = ^"nowhere"
	bare.find_shapes()
	bare.step(0.1)
	assert_false(bare.has_face())
	assert_false(bare.say(_wav(1.0)), "no audio player: nothing to play")


func test_loads_a_takes_emotion_files() -> void:
	var e := LipsyncPlayer.emotion_for(LINE + ".wav")
	assert_almost_eq(LipsyncPlayer.sample(e[0], 1.0)[&"browInnerUp"], 0.7, 0.0001, "directed curves next to the clip")
	assert_eq(e[1].layers.size(), 10, "a layer per emotion")
	assert_true(e[1].layers[&"anger"][&"mouthFunnel"] is PackedFloat32Array)
	var d := LipsyncPlayer.sample_layers(e[1], 1.0)
	assert_almost_eq(d[&"anger"][&"browInnerUp"], -0.3, 0.0001, "deltas from neutral, signed")
	assert_eq(d[&"fear"], {}, "an emotion that moves nothing")
	assert_eq(LipsyncPlayer.emotion_for("res://test/fixtures/old_take.wav"), [{}, {}] as Array[Dictionary],
		"a take timed before emotion: none")


## Plays the fixture line from `at` seconds with its emotion files, stepped once.
func _say_at(at: float) -> void:
	assert_true(lips.say(_wav(3.0), LINE))
	voice.seek(at)
	lips.step(0.0)


func test_plays_the_line_as_directed() -> void:
	await _character()
	_say_at(1.0)
	assert_almost_eq(_shape("browInnerUp"), 0.7, 0.0001, "the directed curves, not neutral's 0.3")
	lips.emotion = false
	lips.step(0.0)
	assert_almost_eq(_shape("browInnerUp"), 0.3, 0.0001, "emotion off: the neutral curves")


func test_a_mood_blends_the_layers_over_neutral() -> void:
	await _character()
	_say_at(1.0)
	var funnel := float(lips.neutral_at(lips.line_time)[&"mouthFunnel"])
	lips.set_mood({&"anger": 1.0}, 0.0)
	lips.step(0.0)
	assert_almost_eq(_shape("browInnerUp"), 0.0, 0.0001, "neutral 0.3 + anger's -0.3")
	assert_almost_eq(_shape("mouthFunnel"), minf(funnel + 0.4, 1.0), 0.0001, "neutral + anger's +0.4")
	lips.set_mood({"anger": 0.5, "joy": 1.0, "bogus": 1.0}, 0.0)
	lips.step(0.0)
	assert_almost_eq(_shape("mouthFunnel"), minf(funnel + 0.2 + 0.2, 1.0), 0.0001, "gains add; unknown emotions ignored")
	assert_eq(lips.mood(), {&"anger": 0.5, &"joy": 1.0})
	lips.set_mood({}, 0.0)
	lips.step(0.0)
	assert_almost_eq(_shape("browInnerUp"), 0.7, 0.0001, "no mood: back to the line as directed")


func test_a_mood_eases_in() -> void:
	await _character()
	lips.mood_time = 0.4
	_say_at(1.0)
	lips.set_mood({&"anger": 1.0})
	voice.seek(1.0)
	lips.step(0.2)
	assert_almost_eq(_shape("browInnerUp"), 0.35, 0.02, "halfway from directed 0.7 to angry 0.0")
	lips.step(0.3)
	assert_almost_eq(_shape("browInnerUp"), 0.0, 0.0001, "then all the way")


func test_a_take_without_emotion_plays_neutral_whatever_the_mood() -> void:
	await _character()
	var c := LipsyncPlayer.curves_for(LINE + ".wav")
	voice.stream = _wav(3.0)
	voice.play(1.0)
	lips.play_line(voice, c[0], c[1])
	lips.set_mood({&"anger": 1.0}, 0.0)
	lips.step(0.0)
	assert_almost_eq(_shape("browInnerUp"), 0.3, 0.0001, "no layers: the mood has nothing to blend")


const BEATS := "res://test/fixtures/beats"


func test_loads_a_lines_expression_beats() -> void:
	var x := LipsyncPlayer.expression_for(BEATS + ".wav")
	assert_almost_eq(float(x.offset), -0.5, 0.0001, "frame 0 is before the audio")
	assert_almost_eq(float(x.lead_in), 0.5, 0.0001)
	assert_almost_eq(float(x.tail), 0.5, 0.0001)
	assert_eq(LipsyncPlayer.expression_for(LINE + ".wav"), {}, "a take without beats: none")


func test_the_lead_in_shows_before_the_audio_starts() -> void:
	await _character()
	assert_true(lips.say(_wav(3.0), BEATS))
	assert_false(voice.playing, "the audio waits for the lead-in")
	lips.step(0.2)
	assert_false(voice.playing)
	assert_almost_eq(lips.line_time, -0.3, 0.0001, "counting down to the audio")
	lips.emotion = false
	lips.step(0.0)
	assert_almost_eq(_shape("browInnerUp"), 0.7, 0.0001, "the beat's 0.4 over the line's first face (0.3)")
	lips.emotion = true
	lips.step(0.0)
	assert_almost_eq(_shape("browInnerUp"), 1.0, 0.0001, "over the directed face (0.7): clamped")
	lips.step(0.4)
	assert_true(voice.playing, "then the audio starts")
	lips.step(0.0)
	assert_almost_eq(lips.line_time, lips.audio_time(), 0.001, "and times the face from there")


func test_no_lead_in_when_asked_or_when_beats_are_off() -> void:
	await _character()
	lips.lead_in = false
	assert_true(lips.say(_wav(3.0), BEATS))
	assert_true(voice.playing, "lead_in off: the audio starts at once")
	voice.stop()
	lips.step(0.0)
	lips.expression = 0.0
	assert_true(lips.say(_wav(3.0), BEATS))
	assert_true(voice.playing, "expression 0: no beats, so no lead-in")
	voice.seek(1.0)
	lips.step(0.0)
	assert_almost_eq(_shape("mouthFunnel"), lips.pose_at(1.0)[&"mouthFunnel"], 0.0001)


func test_beats_add_to_the_line_by_the_expression_gain() -> void:
	await _character()
	var c := LipsyncPlayer.curves_for(BEATS + ".wav")
	var x := LipsyncPlayer.expression_for(BEATS + ".wav")
	voice.stream = _wav(3.0)
	voice.play(1.0)
	lips.play_line(voice, c[0], c[1], {}, {}, x)
	lips.step(0.0)
	var plain := float(LipsyncPlayer.sample(c[0], lips.line_time).get(&"mouthFunnel", 0.0))
	assert_almost_eq(_shape("mouthFunnel"), clampf(plain + 0.2, 0.0, 1.0), 0.0001, "the beat on top of the line")
	lips.expression = 0.5
	lips.step(0.0)
	plain = float(LipsyncPlayer.sample(c[0], lips.line_time).get(&"mouthFunnel", 0.0))
	assert_almost_eq(_shape("mouthFunnel"), clampf(plain + 0.1, 0.0, 1.0), 0.0001, "scaled by `expression`")


func test_the_tail_plays_after_the_audio_ends() -> void:
	await _character()
	watch_signals(lips)
	lips.lead_in = false
	assert_true(lips.say(_wav(3.0), BEATS))
	voice.seek(2.9)
	lips.step(0.0)
	voice.stop()  # the audio ran out
	lips.step(0.2)
	assert_signal_not_emitted(lips, "line_finished", "the line isn't over: its tail plays")
	assert_gt(lips.line_time, 3.0, "on its own clock, past the audio")
	var held := float(LipsyncPlayer.sample(lips.directed, lips.line_time).get(&"eyeBlinkLeft", 0.0))
	assert_almost_eq(_shape("eyeBlinkLeft"), clampf(held + 0.6, 0.0, 1.0), 0.0001, "the face it is left with")
	lips.step(0.2)
	assert_signal_not_emitted(lips, "line_finished")
	lips.step(0.2)
	assert_signal_emitted(lips, "line_finished", "after the tail")


func test_a_line_cut_short_has_no_tail() -> void:
	await _character()
	watch_signals(lips)
	lips.lead_in = false
	assert_true(lips.say(_wav(3.0), BEATS))
	voice.seek(1.0)
	lips.step(0.0)
	voice.stop()
	lips.step(0.05)
	assert_signal_emitted(lips, "line_finished", "stopped mid-line: it ends there")
