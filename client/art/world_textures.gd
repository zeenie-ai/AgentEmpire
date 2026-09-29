class_name WorldTextures
extends RefCounted
## Textures generated at startup, so the world needs no image assets for them:
## - noise(): a tileable 256 px RGBA noise shared by the terrain, the grass, the kit shader and
##   the cloud shadows (global shader parameter "world_noise"). R: soft FBM for large patches,
##   G: cellular edges, B: fine grain, A: billowy FBM for clouds.
## - soft_dot(): a round sprite with a smooth falloff (dust, pollen, glow).
## - puff(): a lumpy smoke puff sprite.
## - ring(): a thin ring with soft edges (selection decals).

const NOISE_SIZE := 256

static var _noise: ImageTexture
static var _soft: ImageTexture
static var _puff: ImageTexture
static var _ring: ImageTexture
static var _ring_glow: ImageTexture


static func noise() -> Texture2D:
	if _noise == null:
		var chans: Array[PackedByteArray] = []
		chans.append(_channel(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 3, 11, FastNoiseLite.FRACTAL_FBM))
		chans.append(_channel(FastNoiseLite.TYPE_CELLULAR, 10, 23, FastNoiseLite.FRACTAL_NONE))
		chans.append(_channel(FastNoiseLite.TYPE_VALUE_CUBIC, 40, 37, FastNoiseLite.FRACTAL_FBM))
		chans.append(_channel(FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 4, 53, FastNoiseLite.FRACTAL_FBM))
		var data := PackedByteArray()
		data.resize(NOISE_SIZE * NOISE_SIZE * 4)
		var n := NOISE_SIZE * NOISE_SIZE
		for i in n:
			data[i * 4] = chans[0][i]
			data[i * 4 + 1] = chans[1][i]
			data[i * 4 + 2] = chans[2][i]
			data[i * 4 + 3] = chans[3][i]
		var img := Image.create_from_data(NOISE_SIZE, NOISE_SIZE, false, Image.FORMAT_RGBA8, data)
		img.generate_mipmaps()
		_noise = ImageTexture.create_from_image(img)
	return _noise


## One tileable noise channel with `cells` features across the texture.
static func _channel(type: int, cells: int, seed_value: int, fractal: int) -> PackedByteArray:
	var fn := FastNoiseLite.new()
	fn.noise_type = type
	fn.seed = seed_value
	fn.frequency = float(cells) / float(NOISE_SIZE)
	fn.fractal_type = fractal
	fn.fractal_octaves = 4
	fn.fractal_gain = 0.5
	if type == FastNoiseLite.TYPE_CELLULAR:
		fn.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
		fn.cellular_jitter = 0.9
	var img := fn.get_seamless_image(NOISE_SIZE, NOISE_SIZE, false, false, 0.1, true)
	if img.get_format() != Image.FORMAT_L8:
		img.convert(Image.FORMAT_L8)
	return img.get_data()


## A white disc whose alpha falls off smoothly from the centre.
static func soft_dot() -> Texture2D:
	if _soft == null:
		var s := 64
		var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
		var c := Vector2(s, s) * 0.5
		for y in s:
			for x in s:
				var d := Vector2(x + 0.5, y + 0.5).distance_to(c) / (s * 0.5)
				var a := clampf(1.0 - d, 0.0, 1.0)
				a = a * a * (3.0 - 2.0 * a)
				img.set_pixel(x, y, Color(1, 1, 1, a))
		img.generate_mipmaps()
		_soft = ImageTexture.create_from_image(img)
	return _soft


## A lumpy puff for smoke and dust: a few overlapping soft blobs with a little shading.
static func puff() -> Texture2D:
	if _puff == null:
		var s := 96
		var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
		var blobs := [Vector3(0.5, 0.55, 0.34), Vector3(0.36, 0.45, 0.24), Vector3(0.64, 0.42, 0.26),
			Vector3(0.5, 0.33, 0.22), Vector3(0.42, 0.62, 0.2), Vector3(0.62, 0.62, 0.2)]
		for y in s:
			for x in s:
				var p := Vector2((x + 0.5) / s, (y + 0.5) / s)
				var a := 0.0
				var shade := 0.0
				for b: Vector3 in blobs:
					var d := p.distance_to(Vector2(b.x, b.y)) / b.z
					var k := clampf(1.0 - d, 0.0, 1.0)
					k = k * k * (3.0 - 2.0 * k)
					a = maxf(a, k)
					# Light from the top-left: blobs are brighter on that side.
					var lit := clampf(0.5 + (Vector2(b.x, b.y) - p).dot(Vector2(0.7, 0.7)) / b.z, 0.0, 1.0)
					shade = maxf(shade, k * lit)
				var v := 0.78 + 0.22 * shade
				img.set_pixel(x, y, Color(v, v, v, a))
		img.generate_mipmaps()
		_puff = ImageTexture.create_from_image(img)
	return _puff


## A soft-edged ring, white, for selection decals (thickness relative to the radius).
static func ring() -> Texture2D:
	if _ring == null:
		_ring = _ring_texture(false)
	return _ring


## The ring with its colour premultiplied by alpha (decal emission ignores alpha).
static func ring_glow() -> Texture2D:
	if _ring_glow == null:
		_ring_glow = _ring_texture(true)
	return _ring_glow


static func _ring_texture(premultiplied: bool) -> ImageTexture:
	var s := 128
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var c := Vector2(s, s) * 0.5
	for y in s:
		for x in s:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c) / (s * 0.5)
			var ring_a := clampf(1.0 - absf(d - 0.86) / 0.1, 0.0, 1.0)
			ring_a = ring_a * ring_a * (3.0 - 2.0 * ring_a)
			# A faint fill inside the ring (not in the glow).
			var a := maxf(ring_a, clampf((0.84 - d) * 4.0, 0.0, 1.0) * 0.12)
			if premultiplied:
				img.set_pixel(x, y, Color(ring_a, ring_a, ring_a, ring_a))
			else:
				img.set_pixel(x, y, Color(1, 1, 1, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
