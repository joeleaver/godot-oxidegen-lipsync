# oxidegen lipsync for Godot 4

A small Godot 4 addon that makes a character's face speak a voiced line: it drives the character's
**ARKit-named blend shapes** (`jawOpen`, `mouthFunnel`, `eyeBlinkLeft`, ...) from the per-frame curves
[oxidegen](https://oxidegen.jkbase.app) makes for a line, in sync with the line's audio.

- Samples the curves at the audio player's playback position each frame (interpolating between
  frames), so it stays in sync through hitches, pauses and seeks.
- Fills in **corrective** shapes the way hifipushie's face shapes expect
  (`jawOpen_mouthClose = min(jawOpen, mouthClose)`).
- Eases the face back to neutral when the line ends or its audio stops.
- Adds **idle blinks** every few seconds, except while a line's own face curves blink the eyes.
- Plays a line **as directed**: the face carries the feeling oxidegen read from the take's direction
  (its `directed_curves`), and `set_mood()` can give a line **another mood live** by blending its
  per-emotion `emotion_layers` over the neutral curves.
- Plays a line's **expression beats**: the look the character wears before its first word (a lead-in
  shown before the audio starts), the one it is left with after the last, and an expression on a sigh
  or a laugh.
- Works for any character whose meshes carry ARKit-named blend shapes; on meshes without any it does
  nothing.

GDScript only, no dependencies. Tested on Godot 4.7.

## What oxidegen produces

oxidegen times every `line` take as it's spoken (older takes on request, below). A timed take's library
version holds, next to the audio:

| file | what |
|---|---|
| `<take>_line_lipsync.json` | words and ARPAbet phonemes with times (`oxidegen.lipsync/1`) |
| `<take>_line_mouth_curves.json` | mouth, jaw, `cheekPuff`, `tongueOut` weights per ARKit name, 30 fps (`oxidegen.mouth_curves/1`) |
| `<take>_line_face_curves.json` | the upper face (brows, eyes, nose), same shape (`oxidegen.face_curves/1`) |
| `<take>_line_directed_curves.json` | every channel, played WITH the line's emotion, same shape (`oxidegen.directed_curves/1`; absent for a neutral line) |
| `<take>_line_emotion_layers.json` | per emotion, the change from neutral with it at full strength (`oxidegen.emotion_layers/1`) |
| `<take>_line_expression_curves.json` | the expression beats, ADDED on top: weights over `[-lead_in, duration + tail]`, frame 0 at `offset` seconds from the audio's start (`oxidegen.expression_curves/1`; absent for a neutral line with no events) |
| `<take>_line_emotion.json` | the emotion track itself: the starting mix and the words it changes on (`oxidegen.emotion/1`; not needed to play) |

`mouth_curves` + `face_curves` are the **neutral** performance. The emotion files come with takes timed by
oxidegen prod v100 or later (2026-10-03); re-time an older take with `lipsync_line` to get them. The ten
emotions (Audio2Face-3D's): amazement, anger, cheekiness, disgust, fear, grief, joy, outofbreath, pain,
sadness. A layers file:

```json
{"format": "oxidegen.emotion_layers/1", "fps": 30, "frames": 119, "duration": 3.92,
 "emotions": ["amazement", "anger", "..."],
 "layers": {"anger": {"browDownLeft": [0.0, 0.41, "..."], "noseSneerLeft": ["..."]}, "joy": {"...": []}}}
```

A channel's weight with a mood = clamp(neutral + Σ gain[emotion] × layers[emotion][channel], 0, 1).
Audio2Face's emotion isn't linear, so this approximates what a take *directed* that way would look like;
`directed_curves` is the exact performance for the line's own direction.
The curves come from NVIDIA Audio2Face-3D. Both curve files have the same shape: channel-major arrays,
frame `i` at `i / fps` seconds from the start of the audio, values 0..1; only channels that move are
present.

```json
{"format": "oxidegen.mouth_curves/1", "fps": 30, "frames": 119, "duration": 3.92,
 "names": ["jawOpen", "mouthClose", "..."],
 "curves": {"jawOpen": [0.0, 0.012, 0.08, "..."], "mouthClose": ["..."]}}
```

**Timing an older take:** the MCP tool `lipsync_line`, or REST:

    POST /v1/versions/{take version id}/lipsync     (Authorization: Bearer <token>)

returns a job; when it finishes, the line asset has a NEW version with the same audio (same blob) plus
the files above. Download them with `GET /v1/blobs/{sha256}`. `lipsync_line` also takes an `emotion`
(`"neutral"`, a mix like `{"anger": 0.6}`, or changes on words) to re-time a take with a different feeling.

## The face: what the character's mesh needs

Blend shapes (glTF morph targets) named with the [ARKit blendshape names](https://developer.apple.com/documentation/arkit/arfaceanchor/blendshapelocation),
case exact, neutral = mouth closed and relaxed, each shape its full extent at weight 1.0, additive.
Every mesh that moves with the face (head, teeth, tongue, eyes) carries the shapes it needs with the
same names; parts that don't move omit them. The mouth should open onto an interior (teeth, tongue, a
mouth bag), not a hole.

hifipushie's sculpt exports do this: `export_asset(face_shapes=True)` writes all 52 ARKit shapes plus
the corrective `jawOpen_mouthClose` onto the body/head, teeth, tongue and eyes (names in the glTF's
`mesh.extras.targetNames`; Godot imports them as blend shapes with those names). Shapes the curves
don't name are left alone, so your own animation can drive them.

## Install

Copy `addons/oxidegen_lipsync/` into your project's `addons/` (or add this repository as a git
submodule and point `addons/oxidegen_lipsync` at it). `LipsyncPlayer` is a global class: enabling the
plugin is optional.

## Use

Put the curves files next to the clip, named after it:

    res://voice/hello.wav
    res://voice/hello.mouth_curves.json
    res://voice/hello.face_curves.json
    res://voice/hello.directed_curves.json     (optional: the line's emotion)
    res://voice/hello.emotion_layers.json      (optional: moods at runtime)
    res://voice/hello.expression_curves.json   (optional: the face around the speech)

Add a `LipsyncPlayer` node to the character: `face_root` = the node holding its meshes (default: the
parent; searched recursively), `audio_player` = the AudioStreamPlayer (2D/3D) it speaks through.

```gdscript
# Plays the clip on audio_player and its curves (found next to the clip):
$LipsyncPlayer.say(preload("res://voice/hello.wav"))

# Or, when something else already plays the audio (a dialogue system):
var c := LipsyncPlayer.curves_for("res://voice/hello.wav")  # [mouth, face]
var e := LipsyncPlayer.emotion_for("res://voice/hello.wav")  # [directed, layers], {} when absent
$LipsyncPlayer.play_line($Voice, c[0], c[1], e[0], e[1])

# A mood the line wasn't directed with (eases in over mood_time; gains 0..1 per emotion, they add):
$LipsyncPlayer.set_mood({&"anger": 0.8, &"fear": 0.2})
# Back to the line as directed:
$LipsyncPlayer.set_mood({})

# Stop early (eases to neutral); `line_finished` fires either way.
$LipsyncPlayer.stop_line()
```

Settings: `release` (seconds to ease to neutral, 0.25), `blinks`, `blink_interval` (2-6 s), `blink_time`
(0.18 s), `emotion` (play a line's directed curves when it has them; default on), `mood_time` (seconds a
`set_mood()` eases over, 0.4), `expression` (how strongly a line's expression beats show, 0-1, default 1),
`lead_in` (`say()` shows the face before the line's first sound, then starts the audio; default on: turn
it off for lines that follow each other closely). With beats, `line_finished` comes after the line's tail,
not when the audio stops; `play_line()` takes them as a sixth argument (`expression_for(clip)`) and plays
no lead-in, since your audio is already running. A mood stays set across lines until changed; a take without emotion
layers ignores it and plays neutral (or directed). Helpers: `load_curves(path)`, `load_layers(path)`,
`curves_for(clip)`, `emotion_for(clip)`, `sample(curves, t)`, `sample_layers(layers, t)`,
`with_correctives(weights)`, `neutral_at(t)`, `pose_at(t)`, `mood()`.

**Exporting a game:** the `.json` curve files aren't Godot resources; add `*.json` to the export
preset's "Filters to export non-resource files".

## Tests

    tools/run_tests.sh

runs the GUT suite headless (fetches GUT 9.7.1 into `addons/gut` on the first run; `GODOT=` picks the
binary).

## Licence

MIT, see `LICENSE`.
