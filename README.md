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
the three files above. Download them with `GET /v1/blobs/{sha256}`.

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

Add a `LipsyncPlayer` node to the character: `face_root` = the node holding its meshes (default: the
parent; searched recursively), `audio_player` = the AudioStreamPlayer (2D/3D) it speaks through.

```gdscript
# Plays the clip on audio_player and its curves (found next to the clip):
$LipsyncPlayer.say(preload("res://voice/hello.wav"))

# Or, when something else already plays the audio (a dialogue system):
var c := LipsyncPlayer.curves_for("res://voice/hello.wav")  # [mouth, face]
$LipsyncPlayer.play_line($Voice, c[0], c[1])

# Stop early (eases to neutral); `line_finished` fires either way.
$LipsyncPlayer.stop_line()
```

Settings: `release` (seconds to ease to neutral, 0.25), `blinks`, `blink_interval` (2-6 s), `blink_time`
(0.18 s). Helpers: `load_curves(path)`, `sample(curves, t)`, `with_correctives(weights)`,
`pose_at(t)`.

**Exporting a game:** the `.json` curve files aren't Godot resources; add `*.json` to the export
preset's "Filters to export non-resource files".

## Tests

    tools/run_tests.sh

runs the GUT suite headless (fetches GUT 9.7.1 into `addons/gut` on the first run; `GODOT=` picks the
binary).

## Licence

MIT, see `LICENSE`.
